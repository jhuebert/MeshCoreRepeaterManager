import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wifi_ota_core/wifi_ota_core.dart';

import 'services/ble_device_link.dart';
import 'services/firmware_library.dart';
import 'services/github_source.dart';
import 'services/literal_compression.dart';
import 'services/radio_plan.dart';
import 'services/resume_controller.dart';
import 'services/board_family.dart';
import 'services/wifi_connector.dart';
import 'services/wifi_ota_service.dart';
import 'services/wifi_status.dart';

export 'services/resume_controller.dart' show ResumeCheck;
import 'services/resume_store.dart';
import 'services/temp_radio_renewal.dart';
import 'services/update_flow.dart';

enum ConnectionPhase { disconnected, connecting, connected }

/// Which release channel the firmware picker is showing. Both are sorted
/// newest-first; dev builds are their own tab rather than a switch buried
/// under the stable list.
enum ReleaseTrack { stable, dev }

/// A saved op stream resumed from the node's current watermark.
/// Signals that the operator paused a transfer. The node kept its staged
/// bytes and the app kept the plan, so this is not a failure.
class UpdatePausedException implements Exception {
  const UpdatePausedException();

  @override
  String toString() => 'Update paused';
}

/// The operator stopped the comparison before anything was staged.
class UpdateComparisonCancelledException implements Exception {
  const UpdateComparisonCancelledException();

  @override
  String toString() => 'Comparison stopped';
}

class ResumeRun {
  const ResumeRun(this.plan, this.nextExpected);

  final ResumePlan plan;
  final int nextExpected;
}

enum UpdatePhase {
  idle,
  probing,
  comparing,
  upToDate,
  staging,
  transferring,
  readyToApply,
  applying,
  verifying,
  done,
  failed,
}

/// How the selected image reaches the repeater.
enum OtaMethod { lora, wifi, onlineFetch }

/// Which WiFi path the repeater offers. A repeater can only use one at a time,
/// so the app chooses from read-only facts before any command is sent.
enum WifiUploadMode { hotspot, lan }

/// How strongly an update was proved. Stock firmware cannot report an image
/// hash, so its WiFi update is only a version match.
enum VerificationLevel { hash, versionOnly }

/// True for the fork's retired `filter-v*` / `-filter-<sha>` naming. Used once
/// at startup to drop library entries that can no longer identify a release.
bool _hasRetiredNaming(String value) => value.toLowerCase().contains('filter');

/// Delete only the library entries whose version or file name still uses the
/// retired `filter` naming, leaving imports and other saved versions alone.
/// Idempotent, so no schema marker is needed.
Future<List<LibraryEntry>> cleanRetiredLibraryEntries(
    FirmwareLibrary library) async {
  final stale = (await library.list())
      .where(
          (e) => _hasRetiredNaming(e.version) || _hasRetiredNaming(e.fileName))
      .toList();
  for (final entry in stale) {
    await library.delete(entry);
  }
  return stale;
}

/// A saved update cannot continue when its image was just deleted, or when its
/// version label came from the retired naming scheme.
bool resumeNeedsClearing(ResumePlan plan, List<LibraryEntry> stale) =>
    _hasRetiredNaming(plan.version) ||
    stale.any((e) => e.sha256.toLowerCase() == plan.imageSha256.toLowerCase());

/// Everything the UI binds to. The app has exactly one job — take a
/// repeater to a chosen firmware — so one state object with explicit steps
/// is the right shape. Navigation is a step flow (connect → target →
/// firmware → review → transfer → verify).
class AppState extends ChangeNotifier {
  AppState();

  /// Injectable for hermetic tests; defaults to the platform support dir.
  Future<Directory> Function()? applicationSupportDirectory;

  // ---------------- transport ----------------

  /// 'ble' or 'tcp': the bench-validation path is TCP to 127.0.0.1.
  String transportKind = 'ble';
  String tcpHost = '127.0.0.1';
  int tcpPort = defaultCompanionPort;

  ConnectionPhase connectionPhase = ConnectionPhase.disconnected;
  String? connectError;
  String companionName = '';
  String? _bleDeviceId;
  BluetoothDevice? _bleDevice;

  /// Test seam: overrides the TCP link built by [connectTcp] (the screen
  /// cannot inject one). Null in production, where a real TcpDeviceLink is
  /// built.
  RadioLink Function(String host, int port)? tcpLinkFactory;

  /// Test seam for the companion client; production builds a real one.
  CompanionClient Function(RadioLink link)? clientFactory;

  /// Test seam for the node-side comparison; production hashes the repeater.
  Future<RemoteDiffResult> Function(Uint8List image)? comparisonFactory;

  /// Test seam for the recovery probe; production builds a real controller.
  ResumeController Function(ResumePlan plan)? resumeControllerFactory;

  /// Test seam for joining the repeater's hotspot; widget tests never run OS
  /// network tooling.
  WifiConnector? wifiConnectorFactory;

  /// Test seam for the update page HTTP client.
  WifiOtaClient? wifiClientFactory;

  RadioLink? _link;
  CompanionClient? _client;
  UpdateFlow? _flow;

  RadioLink? get link => _link;
  CompanionClient? get client => _client;
  UpdateFlow? get flow => _flow;

  // ---------------- target ----------------

  List<Contact> contacts = const [];
  Contact? target;

  /// Admin password for the current session only — never persisted. May be
  /// empty when the companion's key already holds admin rights on the node
  /// (the repeater's ACL grants admin without a password).
  String adminPassword = '';

  OtaStatus? nodeStatus;

  /// What the node said in the `OP_INFO` handshake: capabilities, target id,
  /// and the running image's full SHA-256. That hash invalidates a saved
  /// resume when the node changes; it is not needed to build a diff. Null on
  /// firmware without the handshake.
  OtaNodeInfo? nodeInfo;

  /// The node's primary radio preset, read with `get radio` while checking
  /// it. Used to suggest and validate the off-mesh transfer settings.
  LoRaPreset? nodePreset;

  /// Whether radio2 is enabled on the node, and its status line, read with
  /// `radio2 status`. `null` means the question was not answered.
  bool? radio2Enabled;
  String? radio2Status;

  bool probing = false;
  String? probeError;

  bool get otaSupported => nodeStatus != null;

  // ---------------- update method ----------------

  /// The operator's choice on the Radio step. LoRa is the default so an
  /// existing wizard run is unchanged.
  OtaMethod otaMethod = OtaMethod.lora;

  /// True after Sign in falls back from a non-OTA (stock) repeater.
  bool wifiOnlyMode = false;

  /// `board` reply and its matched ESP32 environment, read on stock firmware.
  String? boardReply;
  String? stockBoardEnvironment;

  /// Observer WiFi facts, read only. The SSID is a network name, never a key.
  WifiLinkState wifiLink = WifiLinkState.unknown;
  String? wifiSsid;

  /// Which of the two mutually exclusive WiFi paths applies. Derived, never
  /// stored, so a changed probe result cannot leave a stale choice behind.
  WifiUploadMode get wifiMode =>
      wifiLanAvailable ? WifiUploadMode.lan : WifiUploadMode.hotspot;

  /// State for the WiFi upload and the observer's direct download.
  Uri? wifiOtaUrl;
  double wifiProgress = 0;
  String? wifiProblem;
  bool wifiPreflight = false;
  WifiNetStatus? onlineNetStatus;
  VerificationLevel verificationLevel = VerificationLevel.hash;

  /// The observer reports online fetch with a feature bit; a stock repeater
  /// never does.
  bool get onlineFetchSupported => nodeInfo?.supportsOnlineFetch ?? false;

  /// A fork ESP32 has the dual-slot OTA engine. A stock repeater qualifies
  /// only when its `board` reply matches a known app-slot environment.
  bool get wifiUploadSupported => wifiOnlyMode
      ? stockBoardEnvironment != null
      : (nodeInfo != null && nodeInfo!.slotSize > 0);

  /// Stored credentials or a live station mean `start ota` serves on the LAN.
  /// Otherwise it opens the `MeshCore-OTA` hotspot.
  bool get wifiLanAvailable =>
      !wifiOnlyMode &&
      onlineFetchSupported &&
      (wifiLink == WifiLinkState.connected || wifiSsid != null);

  void setOtaMethod(OtaMethod method) {
    if (otaMethod == method) return;
    otaMethod = method;
    clearWifiRun();
    notifyListeners();
  }

  /// Drop the page address so the next attempt re-arms it. A failed preflight
  /// keeps it, so Transfer's Retry does not start a second web server.
  void clearWifiRun() {
    wifiOtaUrl = null;
    wifiProgress = 0;
    wifiProblem = null;
    wifiPreflight = false;
    onlineNetStatus = null;
  }

  // ---------------- firmware selection ----------------

  GitHubSource? _source;
  Catalog? catalog;
  bool catalogLoading = false;
  ReleaseTrack releaseTrack = ReleaseTrack.stable;
  String? catalogError;

  /// When on, the app never reaches GitHub: the picker shows only versions
  /// already saved on this device. Persisted, because the field is exactly
  /// where the setting matters (no signal, app restarted).
  bool offlineMode = false;
  File? _settingsFile;

  /// The release currently being saved for offline use (a second save waits).
  String? downloadingReleaseTag;

  /// The board (build environment) the firmware picker is scoped to. It is
  /// pre-filled from the node's `OP_INFO` target id as soon as the catalog or
  /// library knows that environment's name.

  FirmwareLibrary? library;
  List<LibraryEntry> libraryEntries = const [];

  /// A GitHub asset chosen for install.
  FirmwareAsset? selectedAsset;

  /// A library entry chosen for install (offline mode, or a custom `.bin`).
  LibraryEntry? selectedLibraryEntry;

  /// Board the operator assigned to an image whose file name has none. The
  /// node needs its build id in the OTA start op; this is how we get one when
  /// the handshake did not answer. Never persisted — it belongs to this
  /// selection only.
  String? selectedBoardOverride;

  /// True when an image is selected but neither the file name nor the node
  /// gave us a board, so the operator still has to choose one.
  bool needsBoardForImage = false;

  Uint8List? _selectedImage;
  Uint8List? get selectedImage => _selectedImage;
  bool imageLoading = false;
  String? imageError;

  /// The diff computed by hashing the node's running image. No local copy of
  /// the old firmware is needed: the node is the oracle for its bytes.
  RemoteDiffResult? remoteDiff;
  RemoteDiffProgress? compareProgress;
  bool comparing = false;
  String? compareError;

  /// Set by the Transfer screen's Stop button while a comparison is running.
  /// Deliberately separate from `cancelRequested`, which belongs to the
  /// transfer and is reset when it starts.
  bool _compareCancelled = false;

  /// Stop an in-flight comparison without staging anything.
  void stopComparison() => _compareCancelled = true;

  /// The connected node must implement OP_BLOCK_HASH for a remote diff. The
  /// app does not carry a legacy local-delta path.
  bool get blockHashSupported =>
      nodeInfo != null && (nodeInfo!.features & otaFeatBlockHash) != 0;

  /// Drop a comparison that belongs to another node or another image.
  void clearComparison() {
    remoteDiff = null;
    compareProgress = null;
    compareError = null;
    comparing = false;
  }

  // ---------------- radio ----------------

  /// How the transfer reaches the node: the live mesh, a temporary private
  /// preset shared by both ends, or the repeater's second preset.
  RadioPlan radioPlan = const RadioPlan();

  /// The companion's live preset (read when a connection is adopted).
  LoRaPreset? companionPreset;

  /// The preset the companion was on before an off-mesh plan moved it, so it
  /// can be put back afterwards.
  LoRaPreset? _restorePreset;

  /// Whether this update enabled radio2 on the node (and must turn it off
  /// again). False when the node already had radio2 enabled.
  bool _enabledRadio2ForUpdate = false;

  /// The repeater's configured radio2 preset, when it reported one. Used as
  /// the source of truth instead of asking the operator to guess it.
  LoRaPreset? radio2Preset;

  /// Whether the suggested preset may still follow the node/image; an
  /// operator edit pins it.
  bool _radioPresetAuto = true;

  /// Whether the radio has been moved off the live preset for this transfer.
  bool _radioMoved = false;

  /// Timing and failure count for the automatic `tempradio` renewal. Two
  /// consecutive failures pause the transfer so a resume can arm a fresh
  /// window rather than continue on a reverted channel.
  final TempRadioRenewal tempRadioRenewal = TempRadioRenewal();

  String? radioPlanError;

  // ---------------- update ----------------

  UpdatePhase updatePhase = UpdatePhase.idle;
  TransferProgress? progress;
  final List<String> log = [];
  bool cancelRequested = false;

  /// Whether the node answered with the newly sent image's hash (the only
  /// proof an update worked — see AGENTS.md).
  bool verifyMatched = false;

  /// Why the last apply attempt ended, so the verify screen can offer a retry
  /// when the node is still holding a verified staged image.
  ApplyOutcome? applyOutcome;

  /// Whether the last completed action was a rollback. The verify screen must
  /// never present a rollback as a verified update.
  bool rolledBack = false;

  // ---------------- interrupted update ----------------

  /// A saved op stream from an update that did not finish. Null once the
  /// update is applied, discarded, or the file fails to parse.
  ResumePlan? resumePlan;
  ResumeStore? resumeStore;

  /// What the last reconnect check found; drives the recovery screen's one
  /// main action. Never claims success: that still needs the node's hash.
  ResumeCheck resumeCheck = ResumeCheck.idle;
  String? resumeProblem;
  int? resumeNextExpected;
  OtaStatus? resumeStatus;
  bool resumeBusy = false;

  // ---------------- lifecycle ----------------

  Future<Directory> _supportDirectory() async {
    final override = applicationSupportDirectory;
    return override == null ? getApplicationSupportDirectory() : override();
  }

  Future<FirmwareLibrary> _openLibrary() async {
    final existing = library;
    if (existing != null) return existing;
    final support = await _supportDirectory();
    final opened = await FirmwareLibrary.open(support);
    library = opened;
    return opened;
  }

  Future<GitHubSource> _openSource() async {
    final existing = _source;
    if (existing != null) return existing;
    final dir = await getTemporaryDirectory();
    _source = GitHubSource(
      fetchJson: httpFetchJson,
      fetchBytes: httpFetchBytes,
      cacheFile: File('${dir.path}/meshcore_repeater_manager_catalog.json'),
    );
    return _source!;
  }

  Future<void> initServices() async {
    try {
      final support = await _supportDirectory();
      _settingsFile = File('${support.path}/ota_settings.json');
      resumeStore = ResumeStore(File('${support.path}/ota_resume.bin'));
      resumePlan = await resumeStore?.load();
      if (await _settingsFile!.exists()) {
        final decoded = jsonDecode(await _settingsFile!.readAsString());
        if (decoded is Map && decoded['offline'] == true) offlineMode = true;
      }
    } catch (_) {
      // Settings are a convenience; a read failure must not stop the app.
    }
    final lib = await _openLibrary();
    // The fork renamed its releases and dropped the build stamp from asset
    // names. Saved entries carrying the old names can no longer match a
    // release, so remove just those, leaving imports and the offline setting
    // alone.
    final stale = await cleanRetiredLibraryEntries(lib);
    if (stale.isNotEmpty) {
      final plan = resumePlan;
      if (plan != null && resumeNeedsClearing(plan, stale)) {
        await resumeStore?.clear();
        resumePlan = null;
      }
    }
    libraryEntries = await lib.list();
    notifyListeners();
  }

  Future<void> setOfflineMode(bool value) async {
    if (offlineMode == value) return;
    offlineMode = value;
    notifyListeners();
    try {
      final file = _settingsFile;
      if (file != null) {
        await file.writeAsString(jsonEncode({'offline': offlineMode}),
            flush: true);
      }
    } catch (_) {
      // Best effort: the switch still works for this session.
    }
    if (!offlineMode && catalog == null) unawaited(loadCatalog());
  }

  // ---------------- connection ----------------

  Future<void> connectBle(BluetoothDevice device) async {
    await _disposeLink();
    connectionPhase = ConnectionPhase.connecting;
    connectError = null;
    transportKind = 'ble';
    _bleDevice = device;
    _bleDeviceId = device.remoteId.str;
    notifyListeners();
    try {
      final ble = BleDeviceLink(device: device);
      await ble.connect();
      await _adoptLink(ble);
    } catch (e) {
      connectionPhase = ConnectionPhase.disconnected;
      connectError = 'BLE connect failed: $e';
      notifyListeners();
    }
  }

  Future<void> connectTcp({
    required String host,
    required int port,
  }) async {
    await _disposeLink();
    connectionPhase = ConnectionPhase.connecting;
    connectError = null;
    transportKind = 'tcp';
    tcpHost = host;
    tcpPort = port;
    notifyListeners();
    try {
      final tcp = tcpLinkFactory?.call(host, port) ??
          TcpDeviceLink(host: host, port: port);
      await tcp.connect();
      await _adoptLink(tcp);
    } catch (e) {
      connectionPhase = ConnectionPhase.disconnected;
      connectError = 'TCP connect failed: $e';
      notifyListeners();
    }
  }

  Future<void> _adoptLink(RadioLink link) async {
    _link = link;
    final factory = clientFactory;
    _client = factory != null
        ? factory(link)
        : CompanionClient(link, onUnexpectedMessage: (m) {
            log_('unrelated msg from ${bytesToHex(m.senderPrefix)}: ${m.text}');
          });
    _flow = UpdateFlow(client: _client!, link: link, onLog: log_);
    try {
      final info = await link.selfInfo();
      companionName = info.nodeName;
      companionPreset = LoRaPreset(
        frequencyHz: info.radioParams.frequencyHz,
        bandwidthHz: info.radioParams.bandwidthHz,
        spreadingFactor: info.radioParams.spreadingFactor,
        codingRate: info.radioParams.codingRate,
      );
    } catch (_) {
      companionName = '';
    }
    await _refreshContacts();
    connectionPhase = ConnectionPhase.connected;
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _disposeLink();
    notifyListeners();
  }

  /// Restore the companion link after a WiFi network switch. Joining the
  /// repeater's hotspot can drop a TCP link; BLE usually survives.
  Future<void> reconnect() async {
    final device = _bleDevice;
    late final RadioLink link;
    if (transportKind == 'ble' && device != null) {
      final ble = BleDeviceLink(device: device);
      await ble.connect();
      link = ble;
    } else {
      link = tcpLinkFactory?.call(tcpHost, tcpPort) ??
          TcpDeviceLink(host: tcpHost, port: tcpPort);
      await link.connect();
    }
    // Adopt without disposing: the target and method must survive a network
    // switch.
    await _adoptLink(link);
  }

  Future<void> _disposeLink() async {
    try {
      await _link?.disconnect();
    } catch (_) {}
    _link = null;
    _client = null;
    _flow = null;
    connectionPhase = ConnectionPhase.disconnected;
    contacts = const [];
    target = null;
    nodeStatus = null;
    nodeInfo = null;
    nodePreset = null;
    radio2Enabled = null;
    radio2Status = null;
    radio2Preset = null;
    companionName = '';
    companionPreset = null;
    manualRoutePath = '';
    _resetWifiFacts();
  }

  void _resetWifiFacts() {
    otaMethod = OtaMethod.lora;
    wifiOnlyMode = false;
    boardReply = null;
    stockBoardEnvironment = null;
    wifiLink = WifiLinkState.unknown;
    wifiSsid = null;
    verificationLevel = VerificationLevel.hash;
    clearWifiRun();
  }

  Future<void> _refreshContacts() async {
    try {
      contacts = await _client?.listContacts() ?? const [];
    } catch (e) {
      contacts = const [];
      log_('contacts list failed: $e');
    }
    notifyListeners();
  }

  Future<void> refreshContacts() => _refreshContacts();

  // ---------------- target selection ----------------

  /// Optional comma-separated DIRECT path hashes entered on the review screen
  /// (e.g. `c0ff, c0c0`). Empty keeps the saved contact path or zero-hop.
  String manualRoutePath = '';

  String? manualRouteError;

  void setManualRoutePath(String value) {
    manualRoutePath = value;
    manualRouteError = null;
    if (value.trim().isNotEmpty) {
      try {
        OtaRoute.parsePathList(value);
      } catch (e) {
        manualRouteError = '$e';
      }
    }
    notifyListeners();
  }

  /// Add a manual target by hex public key (for nodes not in contacts).
  /// [pubkeyHex] must be 64 hex chars. The pseudo-contact has no saved
  /// path; routing falls back to whatever DIRECT route the companion
  /// decides, which for zero-hop neighbours is direct.
  Contact? addManualTarget(String pubkeyHex, {String name = 'manual target'}) {
    final hex = pubkeyHex.trim().toLowerCase().replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return null;
    final contact = Contact(
        publicKey: hexToBytes(hex), name: name, advType: advTypeRepeater);
    target = contact;
    _resetNodeFacts();
    notifyListeners();
    return contact;
  }

  /// Everything that described the previously checked node. Changing target
  /// must drop it: a diff against another node's running image is worse than
  /// none.
  void _resetNodeFacts() {
    nodeStatus = null;
    nodeInfo = null;
    nodePreset = null;
    radio2Enabled = null;
    radio2Status = null;
    radio2Preset = null;
    clearComparison();
    _radioPresetAuto = true;
    manualRoutePath = '';
    manualRouteError = null;
    probeError = null;
    _resetWifiFacts();
  }

  void selectTarget(Contact contact) {
    target = contact;
    _resetNodeFacts();
    notifyListeners();
  }

  /// Admin login + `ota status` + the capability handshake and radio facts.
  /// Populates [nodeStatus] on success; [probeError] carries the device/app
  /// error on failure.
  ///
  /// [password] may be empty: the repeater treats a blank login as "is this
  /// key already in my ACL?", so a companion whose key is an admin needs no
  /// password at all.
  Future<void> probe({String? password}) async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) return;
    final secret = password ?? adminPassword;
    probing = true;
    probeError = null;
    notifyListeners();
    try {
      final status = await flow.probe(t, secret);
      nodeStatus = status;
      // The handshake confirms the node's board and capabilities, but a node
      // without it can still take a WiFi update.
      nodeInfo = status == null ? null : await flow.tryNodeInfo(t);
      wifiOnlyMode = status == null;
      if (status == null) {
        final board = (await _cliQuiet(t, 'board'))?.trim();
        boardReply = board == null || board.isEmpty ? null : board;
        stockBoardEnvironment = boardReply == null
            ? null
            : esp32EnvironmentForBoard(boardReply!, knownEnvironments);
        probeError = 'This firmware does not speak the ota CLI. '
            'A WiFi update may still be available for ESP32 boards.';
      } else {
        // The radio facts are only needed for the off-mesh transfer options;
        // old firmware answers neither, and neither query makes the probe fail.
        final radio = await _cliQuiet(t, 'get radio');
        nodePreset = radio == null ? null : LoRaPreset.parse(radio);
        radio2Status = await _cliQuiet(t, 'radio2 status');
        // The fork reports `preset=f,bw,sf,cr` on every status line, including
        // `off; paused`. Older firmware omits it — then the operator enters it.
        final presetField =
            RegExp(r'(?:^|;)\s*preset=([^;]+)').firstMatch(radio2Status ?? '');
        radio2Preset = presetField == null
            ? null
            : LoRaPreset.parse(presetField.group(1)!);
        final radio2 = radio2Status?.trim().toLowerCase();
        radio2Enabled = radio2 == null
            ? null
            : (radio2.startsWith('on')
                ? true
                : radio2.startsWith('off')
                    ? false
                    : null);
        _prefillRadioPlan();
        // Observer builds answer these read-only questions. Nothing here
        // starts WiFi or opens the update page.
        if (nodeInfo?.supportsOnlineFetch == true) {
          wifiLink = parseWifiStatus(await _cliQuiet(t, 'get wifi.status'));
          if (wifiLink != WifiLinkState.connected) {
            wifiSsid = parseWifiSsid(await _cliQuiet(t, 'get wifi.ssid'));
          }
        }
        // A new node needs a fresh comparison against its own running image.
        if (_selectedImage != null) clearComparison();
      }
    } catch (e) {
      nodeStatus = null;
      nodeInfo = null;
      nodePreset = null;
      radio2Enabled = null;
      radio2Status = null;
      radio2Preset = null;
      _resetWifiFacts();
      probeError = '$e';
    } finally {
      probing = false;
      notifyListeners();
    }
  }

  /// A CLI read on the checked node that is allowed to fail (old firmware,
  /// a command the role does not expose). Returns null on any error.
  Future<String?> _cliQuiet(Contact t, String command) async {
    try {
      return await _flow!.client.remoteCli(t, command);
    } catch (_) {
      return null;
    }
  }

  // ---------------- firmware selection ----------------

  Future<void> loadCatalog({bool forceRefresh = false}) async {
    catalogLoading = true;
    catalogError = null;
    notifyListeners();
    try {
      final source = await _openSource();
      catalog = await source.catalog(
        forceRefresh: forceRefresh && !offlineMode,
        cacheOnly: offlineMode,
      );
    } catch (e) {
      // Offline with no cache is not an error: the GitHub tab shows what
      // this device holds.
      if (!offlineMode) catalog = null;
      catalogError = offlineMode
          ? 'Offline: no cached release list. Downloaded versions are '
              'shown in the GitHub tab.'
          : '$e';
    } finally {
      catalogLoading = false;
      notifyListeners();
    }
  }

  void setReleaseTrack(ReleaseTrack track) {
    releaseTrack = track;
    notifyListeners();
  }

  /// Every build environment the app can name (from the catalog and the
  /// library). Board detection maps the node's target id back into this set.
  Set<String> get knownEnvironments {
    final out = <String>{};
    for (final release in catalog?.releases ?? const <FirmwareRelease>[]) {
      for (final asset in release.appImages) {
        out.add(asset.env);
      }
    }
    for (final entry in libraryEntries) {
      if (entry.env != customEnvironment && entry.env != 'unknown') {
        out.add(entry.env);
      }
    }
    return out;
  }

  /// The environment whose build id is [targetId], if the app knows that
  /// environment's name. The node reports the id only (`sha256(env)[0..3]`),
  /// so this is the inverse lookup the picker needs.
  String? environmentForTargetId(int targetId) {
    final envs = knownEnvironments.toList()..sort();
    for (final env in envs) {
      if (targetIdForEnvironment(env) == targetId) return env;
    }
    return null;
  }

  /// The board the checked node runs, as far as the app can tell. Null when
  /// the node did not answer the handshake or its build is not in the catalog
  /// or library (a custom build).
  String? get detectedBoard {
    final info = nodeInfo;
    if (info == null) return null;
    return environmentForTargetId(info.targetId);
  }

  Future<void> refreshLibrary() async {
    final lib = await _openLibrary();
    libraryEntries = await lib.list();
    notifyListeners();
  }

  /// The releases for the selected track with an image built for [env], newest
  /// first. Null [env] shows everything — used when there is no node to scope
  /// against (the standalone library). A release with no image for the node's
  /// board is hidden rather than shown and refused later.
  List<FirmwareRelease> visibleReleasesFor(String? env) {
    final dev = releaseTrack == ReleaseTrack.dev;
    final out = (catalog?.releases ?? const <FirmwareRelease>[])
        .where((r) => r.isDevTrack == dev)
        .where((r) => env == null || r.appImages.any((a) => a.env == env))
        .toList()
      ..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    return out;
  }

  /// The image of [release] built for [env], or null when it has none.
  FirmwareAsset? assetForEnvironment(FirmwareRelease release, String? env) {
    if (env == null) return null;
    for (final asset in release.appImages) {
      if (asset.env == env) return asset;
    }
    return null;
  }

  /// Select a GitHub asset and load (download) its bytes.
  Future<void> selectAsset(FirmwareAsset asset) async {
    selectedAsset = asset;
    selectedLibraryEntry = null;
    selectedBoardOverride = null;
    needsBoardForImage = false;
    _selectedImage = null;
    clearComparison();
    imageLoading = true;
    imageError = null;
    notifyListeners();
    try {
      // A version saved for offline use is already on disk; selecting it must
      // never reach GitHub (the field has no signal).
      final cached = libraryEntryForAsset(asset);
      if (cached != null) {
        final lib = await _openLibrary();
        _selectedImage = await lib.read(cached);
        selectedLibraryEntry = cached;
        return;
      }
      if (offlineMode) {
        throw StateError(
            'offline: save this version for offline use before selecting it');
      }
      final bytes = await (await _openSource()).downloadAsset(asset);
      _selectedImage = bytes;
      final entry = await _importImage(
        bytes,
        env: asset.env,
        version: asset.version,
        origin: 'github',
        fileName: asset.name,
      );
      selectedLibraryEntry = entry;
    } catch (e) {
      imageError = '$e';
      _selectedImage = null;
    } finally {
      imageLoading = false;
      notifyListeners();
    }
  }

  /// The library image for [asset], matched by its file name or (when the
  /// release publishes sums) its SHA-256.
  LibraryEntry? libraryEntryForAsset(FirmwareAsset asset) {
    for (final entry in libraryEntries) {
      if (entry.fileName == asset.name) return entry;
      if (asset.sha256 != null && entry.sha256 == asset.sha256) return entry;
    }
    return null;
  }

  /// Save every image of [release] for offline use — all boards, so the
  /// device carries a complete version rather than a per-device guess.
  /// Returns how many images were newly saved.
  Future<int> downloadReleaseToLibrary(FirmwareRelease release) async {
    if (offlineMode) {
      log_('offline mode: go online to download a version');
      return 0;
    }
    if (downloadingReleaseTag != null) return 0;
    final total = release.appImages.length;
    if (total == 0) return 0;
    final missing = release.appImages
        .where((a) => libraryEntryForAsset(a) == null)
        .toList();
    if (missing.isEmpty) {
      log_('${release.tag} was already saved for offline use');
      return 0;
    }
    downloadingReleaseTag = release.tag;
    notifyListeners();
    var saved = 0;
    try {
      final source = await _openSource();
      for (final asset in missing) {
        final bytes = await source.downloadAsset(asset);
        await _importImage(
          bytes,
          env: asset.env,
          version: asset.version,
          origin: 'github',
          fileName: asset.name,
        );
        saved++;
        notifyListeners();
      }
      log_(saved == 0
          ? '${release.tag} was already saved for offline use'
          : 'saved ${release.tag} for offline use ($saved image(s))');
    } catch (e) {
      log_('saving ${release.tag} failed after $saved image(s): $e');
    } finally {
      downloadingReleaseTag = null;
      notifyListeners();
    }
    return saved;
  }

  /// Downloaded GitHub versions, newest first: the offline view. Imported
  /// `.bin` files are deliberately not grouped here — they are their own
  /// list ([importedEntries]); only images fetched from releases appear.
  /// A version is "complete" when the catalog says every asset of that
  /// release is here.
  List<OfflineVersion> get offlineVersions {
    final byVersion = <String, List<LibraryEntry>>{};
    for (final entry in libraryEntries) {
      if (entry.origin != 'github') continue;
      byVersion.putIfAbsent(entry.version, () => []).add(entry);
    }
    final releasesByVersion = <String, FirmwareRelease>{};
    for (final release in catalog?.releases ?? const <FirmwareRelease>[]) {
      for (final asset in release.appImages) {
        releasesByVersion.putIfAbsent(asset.version, () => release);
      }
    }
    final out = <OfflineVersion>[];
    for (final group in byVersion.entries) {
      final release = releasesByVersion[group.key];
      final entries = group.value..sort((a, b) => a.env.compareTo(b.env));
      final complete = release != null &&
          release.appImages.every((a) => libraryEntryForAsset(a) != null);
      out.add(OfflineVersion(
        version: group.key,
        tag: release?.tag,
        entries: entries,
        complete: complete,
        known: release != null,
        isDev: release?.isDevTrack ?? group.key.contains('-dev.'),
        totalAssets: release?.appImages.length ?? entries.length,
      ));
    }
    out.sort((a, b) => b.entries.first.added.compareTo(a.entries.first.added));
    return out;
  }

  /// Imported `.bin` files, newest first — the custom/local half of the
  /// library. Identity is the SHA-256, so an imported image is an update
  /// candidate exactly like a downloaded one. It is never used as a local
  /// diff base: the repeater hashes its own running image.
  List<LibraryEntry> get importedEntries =>
      libraryEntries.where((e) => e.origin != 'github').toList()
        ..sort((a, b) => b.added.compareTo(a.added));

  /// Save just [asset] to the library (the standalone library manager's
  /// download). Returns 1 when newly saved, 0 when already present,
  /// refused (offline) or failed.
  Future<int> downloadAssetToLibrary(FirmwareAsset asset) async {
    if (offlineMode) return 0;
    if (downloadingReleaseTag != null) return 0;
    if (libraryEntryForAsset(asset) != null) return 0;
    try {
      final source = await _openSource();
      final bytes = await source.downloadAsset(asset);
      await _importImage(
        bytes,
        env: asset.env,
        version: asset.version,
        origin: 'github',
        fileName: asset.name,
      );
      return 1;
    } catch (e) {
      log_('saving ${asset.name} failed: $e');
      return 0;
    }
  }

  /// Delete [entries] from the library and repair any selection that pointed
  /// at them: the selected image is dropped rather than left dangling.
  Future<void> deleteLibraryEntries(Iterable<LibraryEntry> entries) async {
    final list = entries.toList();
    if (list.isEmpty) return;
    final removed = list.map((e) => e.id).toSet();
    final lib = await _openLibrary();
    for (final entry in list) {
      await lib.delete(entry);
    }
    if (selectedLibraryEntry != null &&
        removed.contains(selectedLibraryEntry!.id)) {
      selectedLibraryEntry = null;
      selectedAsset = null;
      selectedBoardOverride = null;
      needsBoardForImage = false;
      _selectedImage = null;
      clearComparison();
      imageError = null;
    }
    await refreshLibrary();
    notifyListeners();
  }

  Future<LibraryEntry> _importImage(
    Uint8List bytes, {
    required String env,
    required String version,
    required String origin,
    String? fileName,
  }) async {
    final lib = await _openLibrary();
    final entry = await lib.importBytes(
      bytes,
      env: env,
      version: version,
      origin: origin,
      fileName: fileName,
    );
    libraryEntries = await lib.list();
    notifyListeners();
    return entry;
  }

  /// Import a `.bin` as a library entry. Used for custom builds and for the
  /// "the file this node already has" base: the name is only metadata, the
  /// SHA-256 is the identity.
  Future<LibraryEntry> importLocalImage(
    Uint8List bytes, {
    required String fileName,
    String? env,
    String? version,
  }) =>
      _importImage(
        bytes,
        env: env ?? customEnvironment,
        version: version ?? _versionFromFileName(fileName),
        origin: 'import',
        fileName: fileName,
      );

  /// Select a library entry for install (offline mode, or a custom `.bin`).
  Future<void> selectLibraryEntryForUpdate(LibraryEntry entry) async {
    selectedLibraryEntry = entry;
    selectedAsset = null;
    selectedBoardOverride = null;
    needsBoardForImage = false;
    _selectedImage = null;
    clearComparison();
    imageLoading = true;
    imageError = null;
    notifyListeners();
    try {
      final lib = await _openLibrary();
      _selectedImage = await lib.read(entry);
      // A renamed `.bin` has no board in its name. The node's own handshake is
      // the only authority; retry it with a longer timeout, then ask the
      // operator rather than guessing from a file name or a hash.
      if (nodeInfo == null &&
          (entry.env == customEnvironment || entry.env == 'unknown')) {
        if (!await retryNodeInfo()) needsBoardForImage = true;
        notifyListeners();
      }
    } catch (e) {
      imageError = '$e';
      _selectedImage = null;
    } finally {
      imageLoading = false;
      notifyListeners();
    }
  }

  /// Ask the node to hash ranges of its running image and derive the op
  /// stream. Called from [runUpdate] *after* the radio plan is armed, so the
  /// comparison's REQ/RESPONSE traffic uses the channel the operator chose.
  /// Nothing is staged here; a stop leaves the radios to be restored by
  /// runUpdate's finally block.
  Future<RemoteDiffResult> _compareWhileArmed(
      Contact t, Uint8List image) async {
    final link = _link;
    if (link == null) throw StateError('no link for the comparison');
    final factory = comparisonFactory;
    if (factory != null) {
      clearComparison();
      comparing = true;
      notifyListeners();
      try {
        final result = await factory(image);
        remoteDiff = result;
        return result;
      } finally {
        comparing = false;
        _compareCancelled = false;
        notifyListeners();
      }
    }
    if (!blockHashSupported) {
      throw UpdateFlowException(
          'This repeater does not support comparing its running image. '
          'Update its firmware over USB first.');
    }
    clearComparison();
    comparing = true;
    notifyListeners();
    final client = BlockHashClient(
        link: link, contact: t, timeout: const Duration(seconds: 10));
    try {
      final result = await computeRemoteDiff(
        client: client,
        image: image,
        onProgress: (p) {
          compareProgress = p;
          notifyListeners();
        },
        shouldCancel: () => _compareCancelled,
        onBoundary: () => _renewTempRadioIfNeeded(t),
      );
      remoteDiff = result;
      return result;
    } on RemoteDiffException catch (e) {
      if (_compareCancelled) {
        throw const UpdateComparisonCancelledException();
      }
      compareError = e.message;
      throw UpdateFlowException('compare failed: ${e.message}');
    } catch (e) {
      compareError = '$e';
      throw UpdateFlowException('compare failed: $e');
    } finally {
      comparing = false;
      _compareCancelled = false;
      notifyListeners();
    }
  }

  /// Environment of the current selection (asset env or library env, with a
  /// board chosen by the operator as the fallback for a custom `.bin`).
  String? get selectedEnvironment {
    final asset = selectedAsset;
    if (asset != null) return asset.env;
    final entry = selectedLibraryEntry;
    if (entry == null) return null;
    return selectedBoardOverride ?? entry.env;
  }

  /// Give the handshake another, longer chance before asking the operator to
  /// name the board. Sign-in's 2 s probe is often too short over a mesh, and
  /// the node's own target id is better than any guess from a file name.
  Future<bool> retryNodeInfo() async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) return false;
    final info = await flow.tryNodeInfo(t, timeout: const Duration(seconds: 8));
    if (info == null) return false;
    nodeInfo = info;
    notifyListeners();
    return true;
  }

  /// Use [env] as the board of the selected image for this session.
  Future<void> setSelectedBoard(String env) async {
    selectedBoardOverride = env;
    needsBoardForImage = false;
    notifyListeners();
  }

  /// Version of the current selection. Release versions are already the
  /// sha-free `v<version>` token, so this is also what the UI shows.
  String? get selectedVersion =>
      selectedAsset?.version ?? selectedLibraryEntry?.version;

  /// Version token accepted by `ota fetch ver`. The firmware strips a leading
  /// `v` itself, but sending the bare token keeps the CLI reply readable.
  String? get selectedVersionToken {
    final version = selectedVersion;
    if (version == null) return null;
    return version.replaceFirst(RegExp(r'^[vV]'), '');
  }

  /// SHA-256 to hand to `ota fetch sha`. Release metadata wins; a SHA computed
  /// from the just-downloaded image is the fallback when no sums were
  /// published.
  String? get selectedSha256 {
    final published = selectedAsset?.sha256;
    if (published != null) {
      final hex = published.replaceFirst(RegExp(r'^sha256:'), '').toLowerCase();
      if (hex.length == 64) return hex;
    }
    if (_selectedImage != null) return bytesToHex(sha256List(_selectedImage!));
    final stored = selectedLibraryEntry?.sha256.toLowerCase();
    if (stored != null && stored.length == 64) return stored;
    return null;
  }

  int? get selectedImageSize =>
      selectedAsset?.size ??
      selectedLibraryEntry?.size ??
      _selectedImage?.length;

  /// Online fetch builds its download URL from the repeater's own environment,
  /// so the selected image must be for that exact build.
  bool get onlineFetchBoardMatches {
    final env = selectedEnvironment;
    final info = nodeInfo;
    if (env == null || env == customEnvironment || info == null) return false;
    return targetIdForEnvironment(env) == info.targetId;
  }

  bool get onlineFetchReady =>
      onlineFetchSupported &&
      onlineFetchBoardMatches &&
      selectedVersionToken != null &&
      selectedSha256 != null;

  /// The preset the node's live mesh runs on (falls back to the companion's —
  /// the same mesh when the update path works at all).
  LoRaPreset? get livePreset => nodePreset ?? companionPreset;

  // ---------------- radio plan ----------------

  void setRadioMode(RadioMode mode) {
    if (radioPlan.mode == mode) return;
    radioPlan = radioPlan.copyWith(mode: mode);
    radioPlanError = null;
    if (radioPlan.usesRadio && radioPlan.preset == null) {
      _radioPresetAuto = true;
      _prefillRadioPreset();
    }
    notifyListeners();
  }

  void setRadioPreset(LoRaPreset preset) {
    radioPlan = radioPlan.copyWith(preset: preset);
    _radioPresetAuto = false;
    radioPlanError = null;
    notifyListeners();
  }

  /// The reason the plan cannot start, or null. Recomputed on demand so the
  /// UI always reflects the live preset.
  String? get radioPlanProblem => radioPlan.error(primary: livePreset);

  /// A suggested preset for the current mode, or null for live-mesh mode.
  LoRaPreset? suggestedRadioPreset() {
    final live = livePreset;
    if (live == null || radioPlan.mode == RadioMode.liveMesh) return null;
    return radioPlan.mode == RadioMode.radio2
        ? RadioPlan.suggestRadio2(live)
        : RadioPlan.suggestTempRadio(live);
  }

  /// Reuse the node's own radio2 preset when it reported one; otherwise
  /// suggest a preset clear of the live band.
  void _prefillRadioPreset() {
    final live = livePreset;
    if (live == null) return;
    final reuse = radioPlan.mode == RadioMode.radio2 &&
        radio2Enabled == true &&
        radio2Preset != null;
    radioPlan = radioPlan.copyWith(
        preset: reuse
            ? radio2Preset
            : radioPlan.mode == RadioMode.radio2
                ? RadioPlan.suggestRadio2(live)
                : RadioPlan.suggestTempRadio(live));
  }

  /// Called after a successful probe: the node's preset is what the plan
  /// must clear.
  void _prefillRadioPlan() {
    if (!radioPlan.usesRadio) return;
    if (_radioPresetAuto || radioPlan.preset == null) _prefillRadioPreset();
  }

  /// The whole-image hash from the comparison, not a library match, decides
  /// equality.
  bool get selectedImageIsRunning => remoteDiff?.upToDate ?? false;

  /// Size of the chosen image. The amount to send is only known after the
  /// comparison on the Transfer screen.
  int? get estimatedTransferBytes => _selectedImage?.length;

  /// A compact label for the chosen image's size.
  String estimateLabel() {
    final bytes = estimatedTransferBytes;
    if (bytes == null) return 'size unknown';
    return bytes >= 1024 * 1024
        ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
        : '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  /// Wall time per op on a stock companion, in seconds.
  ///
  /// The node is deaf while each literal op is committed to flash, so the rate
  /// limiter is the node's flash write latency, not airtime: an airtime model
  /// is ~15x optimistic on real hardware (measured ~1.4–1.5 s per literal op:
  /// a 426 KB delta took ~1 hour on an expected ~4 minutes). Synchronous so a
  /// settings screen can compare modes while the user types.
  static const double estimateOpSeconds = 1.5;

  /// Transfer estimate in seconds for the selected image. [factor] scales for
  /// radio2 (it shares the radio, so ops cost roughly twice as long).
  int? estimateSecondsForPreset(LoRaPreset? preset, {double factor = 1.0}) {
    final bytes = estimatedTransferBytes;
    if (preset == null || bytes == null || bytes <= 0) return null;
    // The literal size the transfer actually sends: the stock companion's
    // frame limit, not the on-air maximum (see wireOpsFor).
    final ops = (bytes / otaLiteralChunkForBinaryReq()).ceil() + 16;
    return (ops * estimateOpSeconds * factor).ceil();
  }

  /// Transfer estimate in seconds for [mode] at the current selection. The
  /// preset is the plan's (for off-mesh modes) or the live one.
  int? estimateSecondsForMode(RadioMode mode, {LoRaPreset? preset}) {
    final chosen = mode == RadioMode.liveMesh
        ? livePreset
        : (preset ?? radioPlan.preset ?? livePreset);
    final factor = mode == RadioMode.radio2 ? RadioPlan.radio2DutyFactor : 1.0;
    return estimateSecondsForPreset(chosen, factor: factor);
  }

  /// Transfer estimate in seconds at the preset the transfer will use, or
  /// null when the radio parameters are unavailable.
  Future<int?> estimateTransferSeconds() async {
    final image = _selectedImage;
    final link = _link;
    if (image == null || link == null) return null;
    try {
      final preset = radioPlan.usesRadio && radioPlan.preset != null
          ? radioPlan.preset
          : await _liveParams(link);
      return estimateSecondsForPreset(preset, factor: radioPlan.estimateFactor);
    } catch (_) {
      return null;
    }
  }

  Future<LoRaPreset> _liveParams(RadioLink link) async {
    final params = await link.radioParams();
    return LoRaPreset(
      frequencyHz: params.frequencyHz,
      bandwidthHz: params.bandwidthHz,
      spreadingFactor: params.spreadingFactor,
      codingRate: params.codingRate,
    );
  }

  RadioParams _paramsFor(LoRaPreset preset) => RadioParams(
        frequencyHz: preset.frequencyHz,
        bandwidthHz: preset.bandwidthHz,
        spreadingFactor: preset.spreadingFactor,
        codingRate: preset.codingRate,
      );

  // ---------------- update execution ----------------

  void requestCancel() {
    cancelRequested = true;
    notifyListeners();
  }

  /// Upload the selected image through the repeater's built-in update page.
  /// The WiFi path was chosen on the Radio step, so `start ota` is the first
  /// command sent here and is never used for detection.
  Future<void> runWifiUpload({required String version}) async {
    final t = target;
    final flow = _flow;
    final image = _selectedImage;
    if (t == null || flow == null || image == null) {
      throw StateError('update not ready');
    }
    if (!wifiUploadSupported) {
      throw UpdateFlowException(
          'WiFi update is not available on this repeater');
    }
    cancelRequested = false;
    wifiProblem = null;
    wifiProgress = 0;
    updatePhase = UpdatePhase.staging;
    log_('opening the update page over WiFi');
    notifyListeners();

    final service = WifiOtaService(
      (command) => flow.client.remoteCli(t, command),
      client: wifiClientFactory ?? WifiOtaClient(),
    );
    late final Uri url;
    late final WifiIdentity identity;
    try {
      // A failed preflight keeps the URL: Retry must not open a second server.
      url = wifiOtaUrl ?? await service.startOta();
      wifiOtaUrl = url;
      identity = await service.identity(url);
      if (!identity.isEsp32) {
        throw const WifiOtaException(
            'This board does not report ESP32. WiFi update is for ESP32 only.');
      }
    } on WifiIdentityUnreachable {
      // The chosen path is not reachable from this device. Ask the operator
      // to join it; never switch to the other path behind their back.
      wifiPreflight = true;
      String? instruction;
      if (wifiMode == WifiUploadMode.hotspot) {
        final connector = wifiConnectorFactory ??
            (Platform.isAndroid || Platform.isIOS
                ? const ManualWifiConnector()
                : PlatformWifiConnector());
        final joined = await connector.join('MeshCore-OTA');
        if (joined == WifiJoinResult.joined) {
          await reconnect();
          try {
            identity = await service.identity(url);
          } on WifiOtaException catch (e) {
            instruction = '${e.friendly} Join the hotspot, then retry.';
          }
        } else {
          instruction = joined == WifiJoinResult.denied
              ? 'The system refused the join. Join MeshCore-OTA in your device '
                  'settings, then retry.'
              : 'Join MeshCore-OTA in your device settings, then retry.';
        }
      } else {
        instruction = 'Join the repeater\'s WiFi network on this device, then '
            'retry. The update page is only on that network.';
      }
      if (instruction != null) {
        wifiProblem = instruction;
        updatePhase = UpdatePhase.failed;
        notifyListeners();
        throw UpdateFlowException(instruction);
      }
    } catch (e) {
      final message = e is WifiOtaException
          ? e.friendly
          : 'WiFi update could not start: $e';
      wifiProblem = message;
      updatePhase = UpdatePhase.failed;
      notifyListeners();
      throw UpdateFlowException(message);
    }

    wifiPreflight = false;
    updatePhase = UpdatePhase.transferring;
    notifyListeners();
    try {
      await service.upload(
        base: url,
        image: image,
        md5Hex: imageMd5(image),
        filename: '${version.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.bin',
        onProgress: (sent, total) {
          wifiProgress = total == 0 ? 0 : sent / total;
          notifyListeners();
        },
        shouldCancel: () => cancelRequested,
      );
    } on WifiUploadCancelled {
      const message = 'The upload was stopped.';
      wifiProblem = message;
      updatePhase = UpdatePhase.failed;
      notifyListeners();
      throw UpdateFlowException(message);
    } on WifiOtaException catch (e) {
      wifiProblem = e.friendly;
      updatePhase = UpdatePhase.failed;
      notifyListeners();
      throw UpdateFlowException(e.friendly);
    }

    // ElegantOTA reboots the node itself. There is no verified spare slot and
    // no `ota apply`; prove the result with a version read and, on fork
    // firmware, the running image hash.
    updatePhase = UpdatePhase.verifying;
    notifyListeners();
    final matched = await flow.awaitVersion(
      t,
      adminPassword,
      version,
      expectedImageSha256: sha256List(image),
    );
    verificationLevel =
        wifiOnlyMode ? VerificationLevel.versionOnly : VerificationLevel.hash;
    verifyMatched = matched;
    rolledBack = false;
    updatePhase = matched ? UpdatePhase.done : UpdatePhase.failed;
    if (!matched) {
      wifiProblem = 'The repeater did not come back on the new firmware. '
          'Check it before trying again.';
    }
    notifyListeners();
  }

  /// Observer-only download: the repeater fetches the release itself, verifies
  /// it into its spare slot, and waits for the same commit step as LoRa.
  Future<void> runOnlineFetch({required String version}) async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) throw StateError('update not ready');
    if (!onlineFetchReady) {
      throw UpdateFlowException(
          'Choose a release with a known SHA-256 for this repeater first');
    }
    final token = selectedVersionToken!;
    final sha = selectedSha256!;
    cancelRequested = false;
    onlineNetStatus = null;
    updatePhase = UpdatePhase.staging;
    log_('arming the download of $token on the repeater');
    notifyListeners();

    await flow.clearStaleStaging(t);
    await flow.startOnlineFetch(t, token, sha);
    updatePhase = UpdatePhase.transferring;
    notifyListeners();

    final deadline = DateTime.now().add(const Duration(minutes: 10));
    try {
      while (DateTime.now().isBefore(deadline) && !cancelRequested) {
        final net = await flow.netStatus(t);
        if (net != null) {
          onlineNetStatus = net;
          notifyListeners();
          if (net.phase == WifiNetPhase.error) {
            final status = await flow.status(t);
            final detail =
                status == null ? 'error ${net.err}' : otaErrLabel(status.err);
            throw UpdateFlowException('the download failed: $detail');
          }
        }
        final status = await flow.status(t);
        if (status?.state == OtaPhase.error) {
          throw UpdateFlowException(
              'the download failed: ${otaErrLabel(status!.err)}');
        }
        if (status?.state == OtaPhase.ready) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (cancelRequested) {
        await flow.abortQuietly(t);
        throw UpdateFlowException('the download was stopped');
      }
      await flow.awaitReady(t);
      updatePhase = UpdatePhase.readyToApply;
      log_('the repeater downloaded and verified the image');
      notifyListeners();
    } catch (e) {
      updatePhase = UpdatePhase.failed;
      notifyListeners();
      if (e is UpdateFlowException) rethrow;
      throw UpdateFlowException('the download failed: $e');
    }
  }

  /// Full pipeline: move the radio if asked, stage → transfer → report ready,
  /// then put the radio back. Throws on any failure and leaves [updatePhase]
  /// at `failed` (or `idle` after a cancel) so the screen can show the way
  /// back; the transfer screen maps the exception to UI.
  Future<void> runUpdate({required String version, ResumeRun? resume}) async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) {
      throw StateError('update not ready');
    }
    // WiFi paths do not touch the radio, compare hashes, or arm an op stream.
    if (otaMethod == OtaMethod.wifi) return runWifiUpload(version: version);
    if (otaMethod == OtaMethod.onlineFetch) {
      return runOnlineFetch(version: version);
    }
    final image = _selectedImage;
    if (image == null) throw StateError('update not ready');
    final planProblem = radioPlanProblem;
    if (planProblem != null) {
      throw UpdateFlowException('radio settings: $planProblem');
    }
    // The node's own target id is the authority when the handshake answered;
    // a custom build has no catalog environment to derive one from. A resumed
    // session carries the id it was armed with.
    final env = selectedEnvironment;
    final expected = (env != null && env != customEnvironment)
        ? targetIdForEnvironment(env)
        : nodeInfo?.targetId;
    final targetId = resume?.plan.targetId ?? nodeInfo?.targetId ?? expected;
    if (targetId == null) {
      throw UpdateFlowException('choose the firmware board before starting');
    }
    // Resolve the route before arming so a bad manual path leaves no armed
    // staging session behind. Off-mesh modes are zero-hop by definition.
    final route = radioPlan.requiresZeroHop ? OtaRoute.zeroHop() : _routeFor(t);
    updatePhase =
        resume == null ? UpdatePhase.comparing : UpdatePhase.transferring;
    log_(resume == null
        ? 'preparing the update on the selected channel, version $version'
        : 'resuming update at op ${resume.nextExpected}/${resume.plan.frames.length}');
    notifyListeners();

    RemoteDiffResult? diff;
    _radioMoved = false;
    _compareCancelled = false;
    tempRadioRenewal.clear();
    try {
      if (radioPlan.requiresZeroHop) {
        await _applyRadioPlan(t);
        if (radioPlan.mode == RadioMode.tempRadio) {
          tempRadioRenewal.arm();
        }
      }
      // Compare *after* arming: the many hash queries then travel on the
      // channel the operator chose, not on the live mesh. A stop or a failed
      // comparison is unwound by this method's finally block.
      if (resume == null) {
        diff = await _compareWhileArmed(t, image);
        if (diff.upToDate) {
          updatePhase = UpdatePhase.upToDate;
          log_('this node already runs exactly this image');
          notifyListeners();
          return;
        }
        updatePhase = UpdatePhase.staging;
        notifyListeners();
      }
      // Prove the REQ/RESPONSE route is live on the chosen path before arming:
      // a dead path would otherwise leave an armed session nobody can feed.
      if (resume == null && nodeInfo?.supportsPing == true) {
        final started = DateTime.now();
        final echo = await flow.ping(t);
        // Advisory only: the arm below is itself a round trip, so a lost
        // ping must never block an update that would otherwise work.
        log_(echo == null
            ? 'link check had no answer: continuing'
            : 'link check ok '
                '(${DateTime.now().difference(started).inMilliseconds} ms)');
      }
      // Capabilities are available before arming; the session id is not —
      // it is minted by OP_START, which the transfer sends later.
      OtaNodeStatus? caps;
      if (resume == null && nodeInfo?.supportsStatus == true) {
        caps = await flow.nodeStatus(t);
      }
      var token = 0;
      if (resume == null) {
        final stage = await flow.stage(t, image,
            version: version, expectedTargetId: expected);
        token = stage.token;
        log_(
            'armed: size=${stage.size} token=${stage.token.toRadixString(16).padLeft(8, '0')}');
      }

      // The op stream comes from the comparison against this node's
      // running image. Nothing from a local library can be stale here. A
      // resume replays the exact frames saved at arm time instead.
      // The codec mask says what the node can actually inflate. Nodes that
      // do not advertise DEFLATE get raw literals instead of a stream they
      // would refuse at staging.
      final canCompress = caps == null || caps.supportsCodec(otaCodecDeflate);
      final ops = resume == null
          ? (canCompress ? compressLiteralRuns(diff!.ops) : diff!.ops)
          : const <DeltaOp>[];
      final wireOps = resume != null
          ? WireOps(resume.plan.frames)
          : wireOpsFor(ops, literalChunk: otaLiteralChunkForBinaryReq());
      if (resume == null) {
        final rawOps = diff!.ops;
        final rawLiteral = rawOps
            .whereType<LiteralOp>()
            .fold<int>(0, (sum, op) => sum + op.data.length);
        final compressedLiteral = ops
            .whereType<CompressedLiteralOp>()
            .fold<int>(0, (sum, op) => sum + op.compressed.length);
        log_('comparison: ${diff.copyBytes} bytes reused, '
            '${diff.literalBytes} to send (${diff.queries} queries)');
        if (compressedLiteral > 0) {
          log_('compressed $rawLiteral literal bytes to $compressedLiteral');
        }
        // The node keeps staged bytes only while it stays powered. Save the
        // frames now so a dead app can resume without rebuilding the diff.
        await saveResumePlan(
            t: t,
            image: image,
            targetId: targetId,
            frames: wireOps.frames,
            version: version,
            sessionId: 0); // no OP_START yet: no session id to record
      }

      final sha = sha256List(image);
      cancelRequested = false;
      progress = null;
      notifyListeners();

      try {
        await flow.transfer(
          target: t,
          contract: OtaStartContract(
            imageSize: image.length,
            imageSha256: sha,
            targetId: targetId,
            token: token,
          ),
          ops: ops,
          wireOps: wireOps,
          resumeFrom: resume?.nextExpected ?? 1,
          route: route,
          windowSize: 16,
          onProgress: (p) {
            progress = p;
            notifyListeners();
          },
          onWindowBoundary: () => _renewTempRadioIfNeeded(t),
          shouldCancel: () => cancelRequested || tempRadioRenewal.abandoned,
        );
      } on OtaTransferException catch (e) {
        if (tempRadioRenewal.abandoned) {
          // The temporary window could not be renewed. Pause rather than
          // abort: the node keeps its staged bytes and resuming arms a fresh
          // chunk from the current watermark.
          log_('temporary channel renewal failed: pausing the transfer');
          await pauseTransfer(
            t: t,
            image: image,
            targetId: targetId,
            frames: wireOps.frames,
            version: version,
            nextExpected: (progress?.opsApplied ?? 0) + 1,
          );
          throw const UpdatePausedException();
        }
        if (cancelRequested) {
          // Pausing keeps both halves of the upload: the node's staged bytes
          // and the app's saved op stream. Nothing is aborted or discarded.
          await pauseTransfer(
            t: t,
            image: image,
            targetId: targetId,
            frames: wireOps.frames,
            version: version,
            nextExpected: (progress?.opsApplied ?? 0) + 1,
          );
          throw const UpdatePausedException();
        }
        // A genuine transfer failure still ends the staged session on a fresh
        // attempt. A resume keeps it: the node has everything below
        // next_expected, so the operator can reconnect and try again.
        if (resume == null) await flow.abortQuietly(t);
        updatePhase = UpdatePhase.failed;
        throw UpdateFlowException('transfer failed: ${e.message}');
      }
      // A transport-layer failure (e.g. the companion's binary-request
      // timeout) throws something that is not an OtaTransferException; it must
      // still end the staged session and leave the UI in the failed state,
      // never stuck with a dead cancel button.
      catch (e) {
        if (resume == null) await flow.abortQuietly(t);
        updatePhase = UpdatePhase.failed;
        log_('transfer failed: $e');
        throw UpdateFlowException('transfer failed: $e');
      }

      // OP_START has run by now, so the node has a session id. Record it on
      // the saved plan: on reconnect an id mismatch proves the repeater
      // restarted and its staged bytes are gone.
      if (resume == null && nodeInfo?.supportsStatus == true) {
        final live = await flow.nodeStatus(t);
        if (live != null && live.sessionId != 0) {
          await saveResumePlan(
              t: t,
              image: image,
              targetId: targetId,
              frames: wireOps.frames,
              version: version,
              nextExpected: (progress?.opsApplied ?? 0) + 1,
              sessionId: live.sessionId);
        }
      }

      // Confirm the staged image passed the node's SHA gate.
      await flow.awaitReady(t);
      updatePhase = UpdatePhase.readyToApply;
      log_('staged and verified: ready to apply');
      notifyListeners();
    } on UpdateComparisonCancelledException catch (_) {
      // Nothing was staged, so there is no resumable upload to keep.
      updatePhase = UpdatePhase.idle;
      log_('comparison stopped: nothing was staged');
      notifyListeners();
      rethrow;
    } catch (e) {
      // Stage/arm/verification failures land here. The transfer path already
      // sets failed (or idle on cancel) before rethrowing — keep those — but
      // anything earlier would otherwise leave the phase stuck at staging or
      // transferring with no way forward.
      if (updatePhase != UpdatePhase.failed &&
          updatePhase != UpdatePhase.idle) {
        updatePhase = UpdatePhase.failed;
        notifyListeners();
      }
      rethrow;
    } finally {
      // Put the radios back before the operator commits: the apply (and its
      // verification) belongs on the live mesh, and the temporary preset was
      // only ever for the transfer.
      if (_radioMoved) await _restoreRadioPlan(t);
    }
  }

  Future<void> saveResumePlan({
    required Contact t,
    required Uint8List image,
    required int targetId,
    required List<Uint8List> frames,
    required String version,
    int nextExpected = 1,
    int? sessionId,
  }) async {
    final store = resumeStore;
    if (store == null) return;
    try {
      final plan = ResumePlan(
        createdAt: DateTime.now().millisecondsSinceEpoch,
        targetPublicKeyHex: t.publicKeyHex,
        targetName: t.name,
        imageSha256: bytesToHex(sha256List(image)),
        imageSize: image.length,
        version: version,
        targetId: targetId,
        runningSha256:
            nodeInfo == null ? '' : bytesToHex(nodeInfo!.runningSha256),
        frames: List<Uint8List>.from(frames),
        radioMode: radioPlan.mode.index,
        radioPreset: radioPlan.preset,
        // Legacy field kept for format compatibility; renewal is automatic.
        radioDurationMinutes: RadioPlan.tempRadioChunkMinutes,
        enabledRadio2ForUpdate: _enabledRadio2ForUpdate,
        manualRoutePath: manualRoutePath,
        transportKind: transportKind,
        tcpHost: tcpHost,
        tcpPort: tcpPort,
        bleDeviceId: _bleDeviceId,
        nextExpected: nextExpected,
        // A pause or the post-transfer save keeps the id already on the plan;
        // the first save of a fresh update has no OP_START yet, so no id.
        sessionId: sessionId ?? resumePlan?.sessionId ?? 0,
      );
      await store.save(plan);
      resumePlan = plan;
      notifyListeners();
    } catch (e) {
      // A failed save must never hold up the update itself.
      log_('could not save the resume record: $e');
    }
  }

  /// Stop sending without throwing away the work already done. The repeater
  /// keeps its staged bytes and the app keeps the plan, so the operator can
  /// pick the update up later from the Connect screen.
  Future<void> pauseTransfer({
    required Contact t,
    required Uint8List image,
    required int targetId,
    required List<Uint8List> frames,
    required String version,
    required int nextExpected,
  }) async {
    await saveResumePlan(
      t: t,
      image: image,
      targetId: targetId,
      frames: frames,
      version: version,
      nextExpected: nextExpected,
    );
    updatePhase = UpdatePhase.idle;
    log_('paused: staged image kept; continue from the Connect screen');
    notifyListeners();
  }

  Future<void> _discardResumeRecord() async {
    await resumeStore?.clear();
    resumePlan = null;
    resumeCheck = ResumeCheck.idle;
    resumeProblem = null;
    resumeNextExpected = null;
    resumeStatus = null;
    notifyListeners();
  }

  Contact? _contactFor(String publicKeyHex) {
    for (final c in contacts) {
      if (c.publicKeyHex.toLowerCase() == publicKeyHex.toLowerCase()) {
        return c;
      }
    }
    return null;
  }

  /// Hash the bytes the node already staged and compare them with the saved
  /// image's prefix. Called on resume, before any more ops are sent: a match
  /// proves the saved frame stream still lines up with the node's flash.
  Future<String?> verifyStagedPrefix(Contact t, int written) async {
    final image = _selectedImage;
    final link = _link;
    if (image == null || link == null || written > image.length) {
      return 'The saved firmware could not be checked against the repeater.';
    }
    try {
      final client = BlockHashClient(
          link: link,
          contact: t,
          staged: true,
          // Live-mesh replies can be slow; a longer window and one extra
          // retry avoid a false "no answer" on an otherwise good session.
          timeout: const Duration(seconds: 15),
          retries: 4);
      // The node caps one hash range at 32 KB and the offset/length must be
      // 4-byte aligned. A single request for a whole staged image is always
      // rejected, so verify in 32 KB chunks. Two ranges per exchange keeps the
      // report small enough for the companion's 165-byte radio payload even
      // when it prefixes the reply with the sender's public key; four ranges
      // produce a report the companion cannot deliver.
      const rangesPerQuery = 2;
      final end = (written ~/ blockHashAlign) * blockHashAlign;
      var at = 0;
      while (at < end) {
        final ranges = <BlockHashRange>[];
        while (ranges.length < rangesPerQuery && at < end) {
          final len = (end - at).clamp(0, blockHashMaxRange);
          ranges.add(BlockHashRange(at, len));
          at += len;
        }
        final report = await client.query(ranges);
        if (report.results.length != ranges.length) {
          return 'The repeater could not read back its staged bytes.';
        }
        for (var i = 0; i < ranges.length; i++) {
          final result = report.results[i];
          if (!result.ok || result.offset != ranges[i].offset) {
            return 'The repeater could not read back its staged bytes.';
          }
          final expected = sha256List(Uint8List.sublistView(
              image, ranges[i].offset, ranges[i].offset + ranges[i].length));
          if (bytesToHex(result.sha256) != bytesToHex(expected)) {
            return 'The repeater holds different bytes than the saved '
                'firmware. Start a new update.';
          }
        }
      }
      return null;
    } on BlockHashException catch (_) {
      return 'The repeater did not answer the staged-bytes check. '
          'Tap Check again.';
    } catch (_) {
      return 'Could not check the staged bytes. Tap Check again.';
    }
  }

  /// Load the image and radio choice recorded with an interrupted update.
  /// Returns null on success or a message explaining what is missing.
  Future<String?> restoreResumeSelection(ResumePlan plan) async {
    final sha = plan.imageSha256.toLowerCase();
    LibraryEntry? entry;
    for (final e in libraryEntries) {
      if (e.sha256.toLowerCase() == sha) {
        entry = e;
        break;
      }
    }
    if (entry == null) {
      return 'The firmware image for this update is no longer on this device. '
          'Save it again to continue.';
    }
    await selectLibraryEntryForUpdate(entry);
    if (_selectedImage == null) {
      return 'The saved firmware image could not be read.';
    }
    radioPlan = RadioPlan(
      mode: RadioMode
          .values[plan.radioMode.clamp(0, RadioMode.values.length - 1)],
      preset: plan.radioPreset,
      // plan.radioDurationMinutes is legacy: chunks are automatic now.
    );
    _enabledRadio2ForUpdate = plan.enabledRadio2ForUpdate;
    manualRoutePath = plan.manualRoutePath;
    return null;
  }

  /// Reconnect, sign in and ask the repeater how much of a saved update its
  /// staged session still holds. The node is the authority: anything below
  /// `next_expected` was committed and must not be sent again.
  Future<void> prepareResume({required String password}) async {
    final plan = resumePlan;
    if (plan == null) return;
    resumeBusy = true;
    resumeCheck = ResumeCheck.checking;
    resumeProblem = null;
    notifyListeners();
    try {
      final factory = resumeControllerFactory;
      final controller = factory != null
          ? factory(plan)
          : ResumeController(
              plan: plan,
              connect: () async {
                if (connectionPhase == ConnectionPhase.connected) return null;
                if (plan.transportKind == 'ble' && plan.bleDeviceId != null) {
                  await connectBle(BluetoothDevice.fromId(plan.bleDeviceId!));
                } else {
                  await connectTcp(host: plan.tcpHost, port: plan.tcpPort);
                }
                return connectionPhase == ConnectionPhase.connected
                    ? null
                    : (connectError ?? 'Could not reconnect to the companion.');
              },
              findContact: (pub) => _contactFor(pub),
              login: (t, pw) async {
                final result = await _client!.login(t, pw);
                return (ok: result.ok, admin: result.isAdmin);
              },
              restoreSelection: restoreResumeSelection,
              nodeInfo: (t) async {
                try {
                  final info = await queryNodeInfo(_link!, t,
                      timeout: const Duration(seconds: 5));
                  nodeInfo = info;
                  return info;
                } catch (_) {
                  nodeInfo = null;
                  return null;
                }
              },
              status: (t) async {
                final s = await _flow!.status(t);
                resumeStatus = s;
                nodeStatus = s;
                return s;
              },
              nextExpected: (t) => _flow!.nextExpected(t),
              nodeStatus: (t) => _flow!.nodeStatus(t),
              verifyStaged: verifyStagedPrefix,
            );
      final decision = await controller.check(password);
      adminPassword = password;
      if (decision.target != null) target = decision.target;
      resumeCheck = decision.check;
      resumeProblem = decision.problem;
      resumeNextExpected = decision.nextExpected;
    } catch (e) {
      resumeCheck = ResumeCheck.unavailable;
      resumeProblem = '$e';
    } finally {
      resumeBusy = false;
      notifyListeners();
    }
  }

  /// Continue a saved op stream from the node's watermark.
  Future<void> resumeTransfer() async {
    final plan = resumePlan;
    final next = resumeNextExpected;
    if (plan == null || next == null) {
      throw StateError('resume is not ready');
    }
    verifyMatched = false;
    rolledBack = false;
    await runUpdate(version: plan.version, resume: ResumeRun(plan, next));
  }

  /// The upload finished before the app died; only the apply is left.
  void finishResumeApply() {
    updatePhase = UpdatePhase.readyToApply;
    log_('the repeater already holds the verified image: ready to apply');
    notifyListeners();
  }

  /// Discard a saved update and clear the repeater's staged slot, so the
  /// operator can pick a different firmware.
  Future<void> cancelResume() async {
    final t = target;
    final flow = _flow;
    if (t != null && flow != null) {
      final status = await flow.status(t);
      if (status != null &&
          (status.state == OtaPhase.staging ||
              status.state == OtaPhase.ready)) {
        await flow.abortQuietly(t);
      }
    }
    await _discardResumeRecord();
    updatePhase = UpdatePhase.idle;
    verifyMatched = false;
    rolledBack = false;
    log_('resume cancelled: staged image discarded');
  }

  /// Move the repeater and/or the companion onto the transfer preset. Both
  /// firmware CLIs defer the retune for ~2 s so their reply leaves first.
  Future<void> _applyRadioPlan(Contact t) async {
    final link = _link;
    final flow = _flow;
    final preset = radioPlan.preset;
    if (link == null || flow == null || preset == null) {
      throw UpdateFlowException('no link for the radio settings');
    }
    _radioMoved = false;
    _restorePreset = companionPreset ?? await _liveParams(link);
    if (radioPlan.mode == RadioMode.radio2) {
      if (radio2Enabled == true) {
        // Leave the node's own radio2 configuration alone; the app uses the
        // preset the node reported in `radio2 status`.
        log_('radio2 already enabled: reusing its preset ${preset.label}');
      } else {
        await _nodeCommand(t, radioPlan.radio2Command);
        _radioMoved = true;
        _enabledRadio2ForUpdate = true;
        log_('radio2 enabled on the node: ${preset.label}');
      }
    } else {
      await _nodeCommand(t, radioPlan.tempRadioCommand);
      _radioMoved = true;
      log_('node moved to ${preset.label} for '
          '${RadioPlan.tempRadioChunkMinutes} min');
    }
    // The companion is connected over BLE/TCP, so its preset can simply be
    // written — no tempradio timer, and stock companion firmware has no such
    // CLI command. A refused write throws out of setRadioParams.
    await link.setRadioParams(_paramsFor(preset));
    _radioMoved = true;
    log_('companion tuned to ${preset.label}');
    // The repeater retunes 2 s after queueing its CLI reply.
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  /// Undo [_applyRadioPlan]. Best effort: the transfer already succeeded or
  /// failed, and a radio that stays off-mesh for a few minutes reverts by
  /// itself (the temporary presets are time-boxed on both ends).
  Future<void> _restoreRadioPlan(Contact t) async {
    final link = _link;
    final live = _restorePreset ?? companionPreset;
    try {
      if (_enabledRadio2ForUpdate) {
        // The node must leave radio2 before the companion leaves the shared
        // preset, so the reply has a chance to get out.
        final reply = await _nodeCommandOrNull(t, 'radio2 off');
        _enabledRadio2ForUpdate = false;
        final acknowledged =
            reply != null && reply.trim().toLowerCase().startsWith('ok');
        // Only believe radio2 is off when the node said so; a lost reply leaves
        // the question open rather than recording a false "off".
        radio2Enabled = acknowledged ? false : null;
        log_(acknowledged
            ? 'radio2 turned back off'
            : 'radio2 restore not acknowledged: check the node');
      } else if (radioPlan.mode == RadioMode.tempRadio && live != null) {
        // Send the original preset back, short-lived, so the mesh recovers
        // now instead of when the timer expires. The reply may be lost.
        await _nodeCommandOrNull(t, 'tempradio ${live.cli},1');
      }
    } finally {
      if (link != null && live != null) {
        try {
          await link.setRadioParams(_paramsFor(live));
          log_('companion back on ${live.label}');
        } catch (e) {
          log_('companion radio restore failed: $e');
        }
        // The repeater's revert is deferred ~2 s; don't talk to it on the
        // live preset before that tick has run.
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    _radioMoved = false;
    notifyListeners();
  }

  /// Extend the repeater's temporary radio window at a window boundary.
  /// Called from inside the transfer engine so no op is in flight while the
  /// node retunes (its 2 s defer re-applies the same preset, with no revert
  /// gap when we renew before expiry).
  Future<void> _renewTempRadioIfNeeded(Contact t) async {
    if (radioPlan.mode != RadioMode.tempRadio) return;
    final preset = radioPlan.preset;
    if (preset == null) return;
    await tempRadioRenewal.maybeRenew(renew: () async {
      try {
        await _nodeCommand(
            t,
            RadioPlan(mode: RadioMode.tempRadio, preset: preset)
                .tempRadioCommand);
        log_(
            'temporary channel renewed for ${RadioPlan.tempRadioChunkMinutes} min');
        return true;
      } catch (e) {
        log_('temporary channel renewal failed '
            '(${tempRadioRenewal.failures + 1}/2): $e');
        return false;
      }
    });
  }

  Future<void> _nodeCommand(Contact t, String command) async {
    final reply = await _flow!.client.remoteCli(t, command);
    if (reply.trim().toLowerCase().startsWith('err') ||
        reply.toLowerCase().contains('error')) {
      throw UpdateFlowException('the node refused "$command"',
          deviceReply: reply);
    }
  }

  Future<String?> _nodeCommandOrNull(Contact t, String command) async {
    try {
      return await _flow!.client
          .remoteCli(t, command, timeout: const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  /// Commit: `ota apply` → node reboots into the new image.
  Future<void> applyAndVerify({required String expectedVersion}) async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) throw StateError('no target');
    final image = selectedImage;
    // Online fetch needs no local file, so the selection supplies the digest
    // and size the node verified while downloading.
    final shaHex = selectedSha256;
    final expectedSha = image != null
        ? sha256List(image)
        : (shaHex == null ? null : hexToBytes(shaHex));
    final expectedSize = image?.length ?? selectedImageSize ?? 0;
    verificationLevel = VerificationLevel.hash;
    verifyMatched = false;
    rolledBack = false;
    applyOutcome = null;
    updatePhase = UpdatePhase.applying;
    notifyListeners();

    // The apply reply can be lost when the node reboots before sending it.
    // Only retry when it was NOT acknowledged AND the node still reports the
    // verified staged image: re-applying a node that already flipped the
    // partition would flip it back to the old image.
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      late bool acknowledged;
      try {
        acknowledged = await flow.apply(t);
      } catch (e) {
        updatePhase = UpdatePhase.failed;
        notifyListeners();
        rethrow;
      }
      log_(acknowledged
          ? 'applied: node is rebooting'
          : 'apply not acknowledged (attempt $attempt/$maxAttempts)');
      updatePhase = UpdatePhase.verifying;
      notifyListeners();

      // `ota apply` leaves the state Ready in RAM until the reboot. Give an
      // unacknowledged node time to come back before believing its status.
      if (!acknowledged) {
        await Future<void>.delayed(const Duration(seconds: 8));
      }
      final outcome = await flow.awaitApplyOutcome(
        t,
        adminPassword,
        expectedVersion,
        expectedImageSha256: expectedSha,
        expectedSize: expectedSize,
        timeout: acknowledged
            ? const Duration(seconds: 120)
            : const Duration(seconds: 25),
      );
      applyOutcome = outcome;
      if (outcome == ApplyOutcome.verified) {
        verifyMatched = true;
        updatePhase = UpdatePhase.done;
        await _discardResumeRecord();
        notifyListeners();
        return;
      }
      if (outcome == ApplyOutcome.stagedNotApplied && attempt < maxAttempts) {
        log_('staged image still ready: retrying apply '
            '(${attempt + 1}/$maxAttempts)');
        await Future<void>.delayed(const Duration(seconds: 3));
        continue;
      }
      break;
    }
    verifyMatched = false;
    updatePhase = UpdatePhase.failed;
    // Keep the resume record: for `stagedNotApplied` the recovery screen can
    // still commit this verified image without uploading it again.
    notifyListeners();
  }

  /// Roll back the freshly applied update. We cannot know the previous
  /// version string on this node, so [verifyMatched] after a rollback means
  /// only that the node answered admin CLI again — [rolledBack] is what the UI
  /// reports, never "the sent image is running".
  Future<void> rollback() async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) throw StateError('no target');
    updatePhase = UpdatePhase.applying;
    notifyListeners();
    await flow.rollback(t);
    updatePhase = UpdatePhase.verifying;
    notifyListeners();
    final ok = await flow.awaitVersion(t, adminPassword, '');
    verifyMatched = ok;
    rolledBack = ok;
    updatePhase = ok ? UpdatePhase.done : UpdatePhase.failed;
    notifyListeners();
  }

  void log_(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    log.add('[$ts] $message');
    if (log.length > 300) log.removeRange(0, log.length - 300);
    notifyListeners();
  }

  OtaRoute _routeFor(Contact t) {
    final entered = manualRoutePath.trim();
    if (entered.isNotEmpty) {
      try {
        manualRouteError = null;
        return OtaRoute.parsePathList(entered);
      } catch (e) {
        manualRouteError = '$e';
        rethrow;
      }
    }
    if (t.hasDirectRoute) {
      return OtaRoute.fromContactPath(
        outPathLen: t.outPathLen,
        outPath: t.outPath,
      );
    }
    // No known route: zero-hop DIRECT (works for a node on the same radio;
    // the firmware drops everything not routable). The review screen warns.
    return OtaRoute.zeroHop();
  }

  /// A version-ish label for a hand-picked `.bin`: its file name without the
  /// directory and extension.
  static String _versionFromFileName(String fileName) {
    var name = fileName.split(RegExp(r'[/\\]')).last;
    if (name.toLowerCase().endsWith('.bin')) {
      name = name.substring(0, name.length - 4);
    }
    return name.isEmpty ? 'custom' : name;
  }

  static Uint8List sha256List(List<int> data) =>
      Uint8List.fromList(sha256.convert(data).bytes);
}

/// A firmware version this device has images for: the offline view's unit.
///
/// Versions are downloaded whole (every board's image), so the operator picks
/// a version, not a device. Imported `.bin` files are not versions — they
/// have no release to be complete against — so only GitHub downloads appear
/// here. [complete] is meaningful when the catalog still knows the release
/// ([known]).
class OfflineVersion {
  const OfflineVersion({
    required this.version,
    this.tag,
    required this.entries,
    required this.complete,
    required this.known,
    required this.isDev,
    required this.totalAssets,
  });

  final String version;

  /// The release tag (e.g. `v1.1.0-rc5`) when the catalog knows it; versions
  /// are the unit the user thinks in. Null without a catalog.
  final String? tag;
  final List<LibraryEntry> entries;
  final bool complete;
  final bool known;
  final bool isDev;

  /// How many images the whole version has; equal to [entries.length] when
  /// the catalog is unavailable.
  final int totalAssets;
}
