import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/firmware_library.dart';
import '../services/github_source.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'radio_settings_screen.dart';

/// Step 4: pick what to install — or the standalone library manager.
///
/// The same screen serves both contexts. Inside an update
/// ([updateMode] true) it is wizard step 4 and tapping a version selects its
/// image for this node's board. From the main screen ([updateMode] false) it
/// is a file manager for the library: download GitHub release versions,
/// import `.bin` files, delete what is no longer needed — taps never select
/// an update.
///
/// Versions are treated as a unit everywhere: the GitHub listing shows one
/// row per version (cloud icons show whether it is saved for offline use),
/// saving a version stores every board's image, and tapping a version in an
/// update downloads only this node's image. In update mode the list holds
/// only versions with an image for the board the node reported; in offline
/// mode it holds only versions saved on this device. Imported `.bin` files
/// are the separate Imported tab — one row per file.
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key, this.updateMode = true});

  /// true: wizard step 4 (tapping picks the image). false: the standalone
  /// library manager reached from the main screen (taps download/inspect).
  final bool updateMode;

  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      if (!app.offlineMode && app.catalog == null && !app.catalogLoading) {
        app.loadCatalog();
      }
      app.refreshLibrary();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  static final _mobile = Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final update = widget.updateMode;
    final detected = app.detectedBoard;

    return Scaffold(
      appBar: AppBar(
        title: Text(update ? 'Choose firmware' : 'Firmware library'),
        actions: [
          IconButton(
            tooltip:
                app.offlineMode ? 'Offline. Tap to go online.' : 'Go offline',
            onPressed: () => app.setOfflineMode(!app.offlineMode),
            icon: Icon(
              app.offlineMode ? Icons.cloud_off : Icons.cloud_queue,
              color: app.offlineMode ? OtaTheme.warn : OtaTheme.textMuted,
            ),
          ),
          const SizedBox(width: 4),
        ],
        bottom: update
            ? WizardTabBar(
                step: 4,
                label: 'Choose the image',
                controller: _tabs,
                tabs: const [
                  Tab(text: 'GitHub'),
                  Tab(text: 'Imported'),
                ],
              )
            : TabBar(
                controller: _tabs,
                indicatorColor: OtaTheme.accent,
                tabs: const [
                  Tab(text: 'GitHub'),
                  Tab(text: 'Imported'),
                ],
              ),
      ),
      body: Column(
        children: [
          if (update && detected == null && app.nodeInfo == null)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                'This repeater did not answer its capability check, so the '
                'app cannot tell which board it is. Tap a version to choose '
                'the image yourself.',
                style: TextStyle(
                    color: OtaTheme.textMuted, fontSize: 12, height: 1.35),
              ),
            ),
          if (app.offlineMode)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: OtaTheme.warn.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: OtaTheme.warn.withValues(alpha: 0.35)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.cloud_off, color: OtaTheme.warn, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Offline. No GitHub requests. This tab shows only '
                      'the versions saved on this device.',
                      style: TextStyle(
                          color: OtaTheme.warn, fontSize: 12, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildGitHubTab(app),
                _buildImportedTab(app),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: update ? _buildSelectionBar(context, app) : null,
    );
  }

  // ---------------------------------------------------------------- GitHub

  Widget _buildGitHubTab(AppState app) {
    final update = widget.updateMode;
    final detected = app.detectedBoard;

    if (update && detected == null && app.nodeInfo != null) {
      // The node answered, but the app cannot name its build environment, so
      // no release can be matched to it.
      return _offlineEmpty(
        icon: Icons.help_outline,
        title: 'This node\'s board is not recognized',
        body: 'This build is not in the app\'s catalog or library, so no '
            'release can be matched to it. Import the image in the Imported '
            'tab instead.',
      );
    }

    if (app.offlineMode) {
      return _buildDownloadedVersions(app, detected);
    }

    final releases = app.visibleReleasesFor(update ? detected : null);
    final track = app.releaseTrack == ReleaseTrack.dev ? 'dev ' : '';

    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          heightFactor: 1.0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: IconButton(
              tooltip: 'Refresh releases',
              onPressed: app.catalogLoading
                  ? null
                  : () => app.loadCatalog(forceRefresh: true),
              icon: const Icon(Icons.refresh),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
          child: SegmentedButton<ReleaseTrack>(
            segments: const [
              ButtonSegment(value: ReleaseTrack.stable, label: Text('Stable')),
              ButtonSegment(value: ReleaseTrack.dev, label: Text('Dev')),
            ],
            selected: {app.releaseTrack},
            onSelectionChanged: (s) => app.setReleaseTrack(s.first),
          ),
        ),
        if (app.catalogError != null) ErrorBanner(app.catalogError!),
        if (app.catalogLoading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Expanded(
            child: releases.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No ${track}releases${update ? ' with an image for '
                            '$detected' : ''}.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: OtaTheme.textMuted),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 12),
                    children: [
                      for (final release in releases)
                        _releaseCard(context, app, release, detected),
                    ],
                  ),
          ),
      ],
    );
  }

  /// Offline mode: the GitHub view holds only what this device has saved.
  Widget _buildDownloadedVersions(AppState app, String? detected) {
    final update = widget.updateMode;
    final versions = app.offlineVersions;
    // In update mode the list holds only what this node can run. The one
    // exception is a node that did not answer the handshake at all: there is
    // no board to scope against, so keep every saved version and let the row
    // pick its image explicitly.
    final canScope = detected != null || app.nodeInfo != null;
    final shown = update && canScope
        ? versions
            .where((v) => v.entries.any((e) => e.env == detected))
            .toList()
        : versions;

    if (shown.isEmpty) {
      if (update && versions.isNotEmpty) {
        return _offlineEmpty(
          icon: Icons.help_outline,
          title: 'Nothing saved for your board',
          body: 'The versions on this device do not have an image for '
              '$detected. Go online to save one, or import a .bin in the '
              'Imported tab.',
          action: FilledButton.icon(
            onPressed: () => app.setOfflineMode(false),
            icon: const Icon(Icons.cloud_queue),
            label: const Text('Go online'),
          ),
        );
      }
      return _offlineEmpty(
        icon: Icons.cloud_download_outlined,
        title: 'No versions saved for offline use yet',
        body: 'On a connection, open this tab and save a version with the '
            'cloud button. Every board\'s image for that version is stored '
            'on this device, so you can update in the field with no signal.',
        action: FilledButton.icon(
          onPressed: () => app.setOfflineMode(false),
          icon: const Icon(Icons.cloud_queue),
          label: const Text('Go online'),
        ),
      );
    }

    final totalBytes = shown.fold<int>(
        0, (sum, v) => sum + v.entries.fold<int>(0, (s, e) => s + e.size));
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${shown.length} version(s) on this device · '
            '${formatBytes(totalBytes)} · offline',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        for (final version in shown)
          _offlineVersionCard(context, app, version, detected),
      ],
    );
  }

  // -------------------------------------------------------------- Imported

  Widget _buildImportedTab(AppState app) {
    final entries = app.importedEntries;
    final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.size);
    final update = widget.updateMode;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  entries.isEmpty
                      ? 'No imported .bin files yet'
                      : '${entries.length} files · '
                          '${formatBytes(totalBytes)}',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: () => _importBin(app),
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: const Text('Import a .bin'),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'Imported .bin files are custom or local builds. The '
                      'app recognizes an imported image by its content, so '
                      'the same bytes are used the same way whatever the '
                      'file name says.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.5),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    for (final entry in entries)
                      Card(
                        color:
                            update && identical(entry, app.selectedLibraryEntry)
                                ? OtaTheme.surfaceHigh
                                : null,
                        child: ListTile(
                          dense: true,
                          leading:
                              const Icon(Icons.memory, color: OtaTheme.accent),
                          title: Text(entry.fileName,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12)),
                          subtitle: Text(
                            '${entry.env} · ${entry.version} · '
                            '${formatBytes(entry.size)}',
                            style: const TextStyle(
                                color: OtaTheme.textMuted, fontSize: 11),
                          ),
                          trailing: app.imageLoading &&
                                  identical(entry, app.selectedLibraryEntry)
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert,
                                      color: OtaTheme.textMuted),
                                  onSelected: (value) =>
                                      _importedMenuAction(app, entry, value),
                                  itemBuilder: (_) => update
                                      ? const [
                                          PopupMenuItem(
                                              value: 'install',
                                              child:
                                                  Text('Use for the update')),
                                          PopupMenuItem(
                                              value: 'details',
                                              child: Text('Details')),
                                          PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete')),
                                        ]
                                      : const [
                                          PopupMenuItem(
                                              value: 'details',
                                              child: Text('Details')),
                                          PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete')),
                                        ],
                                ),
                          onTap: app.imageLoading
                              ? null
                              : () => update
                                  ? app.selectLibraryEntryForUpdate(entry)
                                  : _inspectEntry(entry),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _importedMenuAction(
      AppState app, LibraryEntry entry, String value) async {
    switch (value) {
      case 'install':
        await app.selectLibraryEntryForUpdate(entry);
      case 'details':
        _inspectEntry(entry);
      case 'delete':
        await _deleteEntries(
          app,
          [entry],
          title: 'Delete image?',
          body: '${entry.fileName}\n\nThis cannot be undone.',
        );
    }
  }

  /// The node did not answer the capability handshake, so there is no board to
  /// pick its image automatically. Let the operator choose from this version's
  /// images instead of leaving the row inert; [choices] are sorted by label
  /// before the dialog is shown.
  Future<void> _pickImageForUnknownBoard(
    BuildContext context,
    List<(String label, Future<void> Function() select)> choices,
  ) async {
    final sorted = [...choices]..sort((a, b) => a.$1.compareTo(b.$1));
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pick the image for your repeater'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Your repeater did not answer the capability check, so the '
                'app cannot tell which board it is. Choose the image built '
                'for your board. A mismatched image will be refused.',
                style: TextStyle(
                    color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < sorted.length; i++)
                ListTile(
                  dense: true,
                  title: Text(sorted[i].$1,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  onTap: () => Navigator.of(context).pop(i),
                ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (picked != null) await sorted[picked].$2();
  }

  /// The selected `.bin` has no board in its name and the node never answered
  /// OP_INFO. Ask for the build environment so the app can derive the target
  /// id the repeater checks in the OTA start op.
  Future<void> _pickBoardForImage(AppState app) async {
    final envs = app.knownEnvironments.toList()..sort();
    if (envs.isEmpty) {
      _showSnack('No known boards. Refresh the release list first');
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Which board is this image for?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'The repeater did not answer the capability check, so the app '
                'cannot read its target id. Pick the build environment this '
                'image came from. A wrong choice is refused at staging.',
                style: TextStyle(
                    color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 10),
              for (final env in envs)
                ListTile(
                  dense: true,
                  title: Text(env,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  onTap: () => Navigator.of(context).pop(env),
                ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (picked != null) await app.setSelectedBoard(picked);
  }

  /// The row for a catalog release, wired to the update or manager context.
  Widget _releaseCard(BuildContext context, AppState app,
      FirmwareRelease release, String? detected) {
    final update = widget.updateMode;
    final entries = release.appImages
        .map(app.libraryEntryForAsset)
        .whereType<LibraryEntry>()
        .toList();
    final asset = update ? app.assetForEnvironment(release, detected) : null;
    final selected = asset != null &&
        (app.selectedAsset?.name == asset.name ||
            (app.selectedLibraryEntry?.env == asset.env &&
                app.selectedLibraryEntry?.version == asset.version));

    return _VersionCard(
      version: release.tag,
      dateLabel: _VersionCard._date(release.publishedAt),
      isDev: release.isDevTrack,
      savedCount: entries.length,
      totalCount: release.appImages.length,
      selected: selected,
      offline: false,
      onTap: update
          ? (asset != null
              ? () => app.selectAsset(asset)
              : app.nodeInfo == null && release.appImages.isNotEmpty
                  ? () => _pickImageForUnknownBoard(
                        context,
                        [
                          for (final a in release.appImages)
                            (a.env, () => app.selectAsset(a)),
                        ],
                      )
                  : null)
          : () => _saveRelease(context, app, release),
      onSave: () => _saveRelease(context, app, release),
      onDelete: entries.isEmpty
          ? null
          : () => _deleteEntries(
                app,
                entries,
                title: 'Delete ${release.tag}?',
                body: 'This removes all ${entries.length} saved image(s) of '
                    '${release.tag} from this device.\n\n'
                    'This cannot be undone.',
              ),
    );
  }

  /// The row for a version saved on this device (offline mode).
  Widget _offlineVersionCard(BuildContext context, AppState app,
      OfflineVersion version, String? detected) {
    final update = widget.updateMode;
    final entries = version.entries;
    final entry = entryForBoard(entries, detected);
    final selected =
        update && entry != null && app.selectedLibraryEntry?.id == entry.id;
    final savedAt =
        entries.map((e) => e.added).reduce((a, b) => a.isAfter(b) ? a : b);

    return _VersionCard(
      version: version.tag ?? version.version,
      dateLabel: _VersionCard._date(savedAt.toIso8601String()),
      isDev: version.isDev,
      savedCount: entries.length,
      totalCount: version.totalAssets,
      selected: selected,
      offline: true,
      onTap: update
          ? (entry != null
              ? () => app.selectLibraryEntryForUpdate(entry)
              : app.nodeInfo == null && entries.isNotEmpty
                  ? () => _pickImageForUnknownBoard(
                        context,
                        [
                          for (final e in entries)
                            (e.env, () => app.selectLibraryEntryForUpdate(e)),
                        ],
                      )
                  : null)
          : () => _showSnack('Offline. Nothing new to download for this '
              'version'),
      onSave: null,
      onDelete: () => _deleteEntries(
        app,
        entries,
        title: 'Delete ${version.tag ?? version.version}?',
        body: 'This removes all ${entries.length} saved image(s) of '
            '${version.tag ?? version.version} from this device.\n\n'
            'This cannot be undone.',
      ),
    );
  }

  /// Save every missing image of the release; used by the row tap in the
  /// library manager and by the cloud button everywhere online.
  Future<void> _saveRelease(
      BuildContext context, AppState app, FirmwareRelease release) async {
    final saved = await app.downloadReleaseToLibrary(release);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(saved == 0
            ? '${release.tag} is already saved'
            : 'Saved ${release.tag}. $saved images ready offline'),
      ),
    );
  }

  // -------------------------------------------------------------- actions

  Future<void> _importBin(AppState app) async {
    try {
      final path = await _pickBinFile();
      if (path == null) return;
      final bytes = await File(path).readAsBytes();
      final fileName = path.split(RegExp(r'[/\\]')).last;
      final parsed = FirmwareAsset.parse(
        name: fileName,
        size: bytes.length,
        downloadUrl: '',
      );
      await app.importLocalImage(
        bytes,
        fileName: fileName,
        env: parsed?.env,
        version: parsed?.version,
      );
      _showSnack(parsed == null
          ? 'Imported $fileName as a custom image'
          : 'Imported ${parsed.env} ${parsed.version}');
    } catch (e) {
      _showSnack('Import failed: $e');
    }
  }

  /// The platform's file picker. `flutter_file_dialog` is the Android/iOS
  /// document picker; desktop (Linux/Windows/macOS) uses `file_selector`.
  Future<String?> _pickBinFile() async {
    if (_mobile) {
      return FlutterFileDialog.pickFile(
        params: OpenFileDialogParams(
          dialogType: OpenFileDialogType.document,
          fileExtensionsFilter: const ['bin'],
        ),
      );
    }
    final file = await openFile(acceptedTypeGroups: [
      XTypeGroup(label: 'BIN', extensions: const ['bin']),
    ]);
    return file?.path;
  }

  /// Confirm, delete, and report. Any selected image is repaired inside
  /// [AppState.deleteLibraryEntries].
  Future<void> _deleteEntries(
    AppState app,
    Iterable<LibraryEntry> entries, {
    required String title,
    required String body,
  }) async {
    final list = entries.toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await app.deleteLibraryEntries(list);
    _showSnack(list.length == 1
        ? 'Deleted ${list.single.fileName}'
        : 'Deleted ${list.length} images');
  }

  void _inspectEntry(LibraryEntry entry) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.fileName,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 13, height: 1.4)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _inspectRow('Board', entry.env),
            _inspectRow('Version', entry.version),
            _inspectRow('Origin', entry.origin),
            _inspectRow('Size', formatBytes(entry.size)),
            _inspectRow('Added', _shortDate(entry.added)),
            const SizedBox(height: 8),
            const Text('SHA-256',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 11)),
            const SizedBox(height: 2),
            SelectableText(entry.sha256,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11, height: 1.4)),
          ],
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static String _shortDate(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  Widget _inspectRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(label,
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 11)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _offlineEmpty({
    required IconData icon,
    required String title,
    required String body,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: OtaTheme.textMuted),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: OtaTheme.textMuted, fontSize: 12, height: 1.45),
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              action,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBar(BuildContext context, AppState app) {
    final package = app.selectedLibraryEntry ?? app.selectedAsset;
    final env = app.selectedEnvironment;
    final canTarget =
        (env != null && env != customEnvironment) || app.nodeInfo != null;
    final ready = app.selectedImage != null &&
        !app.imageLoading &&
        app.imageError == null &&
        canTarget;
    final detected = app.detectedBoard;
    final mismatch = env != null &&
        env != customEnvironment &&
        detected != null &&
        env != detected;

    return Material(
      color: OtaTheme.surface,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (package != null && app.selectedImage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Selected: ${env ?? '?'} · '
                  '${app.selectedVersion ?? '?'} · '
                  '${formatBytes(app.selectedImage!.length)}',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
              ),
            if (mismatch)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'This image is for $env, but the node reported $detected. '
                  'The node will refuse it at staging.',
                  style: const TextStyle(color: OtaTheme.warn, fontSize: 11),
                ),
              ),
            if (app.imageError != null)
              Text(
                app.imageError!,
                style: const TextStyle(color: OtaTheme.bad, fontSize: 12),
              ),
            if (app.needsBoardForImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      child: Text(
                        'The file name has no board and the repeater did not '
                        'answer the capability check. Choose the board this '
                        'image was built for.',
                        style: TextStyle(color: OtaTheme.warn, fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _pickBoardForImage(app),
                      child: const Text('Choose board'),
                    ),
                  ],
                ),
              ),
            FilledButton.icon(
              onPressed: ready
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const RadioSettingsScreen()),
                      )
                  : null,
              icon: app.imageLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF1A1203),
                      ),
                    )
                  : const Icon(nextIcon),
              label: Text(app.imageLoading ? 'Downloading…' : 'Radio settings'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The entry built for [env] within [entries], or null.
LibraryEntry? entryForBoard(List<LibraryEntry> entries, String? env) {
  if (env == null) return null;
  for (final entry in entries) {
    if (entry.env == env) return entry;
  }
  return null;
}

/// One row per version — the unit the user asked for. The trailing cloud
/// icon carries the save state (not saved / partial / saved); the trash icon
/// deletes the whole version. Tapping does what fits the context: in an
/// update it selects the image built for this node's board; in the library
/// manager it downloads every missing board's image.
class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.version,
    required this.dateLabel,
    required this.isDev,
    required this.savedCount,
    required this.totalCount,
    required this.selected,
    required this.offline,
    required this.onTap,
    required this.onSave,
    required this.onDelete,
  });

  final String version;
  final String dateLabel;
  final bool isDev;
  final int savedCount;
  final int totalCount;
  final bool selected;
  final bool offline;
  final VoidCallback? onTap;
  final VoidCallback? onSave;
  final VoidCallback? onDelete;

  static String _date(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  bool get _complete => totalCount > 0 && savedCount >= totalCount;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final state = _complete || savedCount == 0
        ? null
        : '$savedCount of $totalCount images saved';

    return Card(
      color: selected ? OtaTheme.surfaceHigh : null,
      child: ListTile(
        dense: true,
        title: Row(
          children: [
            Flexible(
              child: Text(
                version,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            StatusPill(
              isDev ? 'DEV' : 'STABLE',
              color: isDev ? OtaTheme.warn : OtaTheme.ok,
            ),
          ],
        ),
        subtitle: Text(
          state == null ? dateLabel : '$dateLabel · $state',
          style: const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const Icon(Icons.check, color: OtaTheme.accent),
              const SizedBox(width: 8),
            ],
            IconButton(
              tooltip: offline
                  ? (_complete
                      ? 'Saved for offline use'
                      : 'Missing images can only be downloaded on a connection')
                  : _complete
                      ? 'Saved for offline use'
                      : 'Save every image of this version for offline use',
              // A complete version has nothing to download; a partial one
              // can always fetch the rest on a connection.
              onPressed: offline || _complete ? null : onSave,
              icon: Icon(
                _complete
                    ? Icons.cloud_done
                    : savedCount == 0
                        ? Icons.cloud_download_outlined
                        : Icons.cloud_download,
                color: _complete
                    ? OtaTheme.ok
                    : savedCount == 0
                        ? OtaTheme.accent
                        : OtaTheme.warn,
                size: 20,
              ),
            ),
            if (onDelete != null)
              IconButton(
                tooltip: 'Delete this version ($savedCount image(s))',
                icon: const Icon(Icons.delete_outline,
                    color: OtaTheme.textMuted, size: 20),
                onPressed: onDelete,
              ),
          ],
        ),
        onTap: app.imageLoading ? null : onTap,
      ),
    );
  }
}
