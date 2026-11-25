import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const _releaseRepo = 'jhuebert/MeshCore';

/// One installable asset from a fork release (the repeater's app-slot
/// `firmware.bin`). `-merged.bin` images are excluded — they contain the
/// bootloader and must never land in the inactive app slot.
class FirmwareAsset {
  const FirmwareAsset({
    required this.name,
    required this.env,
    required this.version,
    required this.size,
    required this.downloadUrl,
    this.sha256,
  });

  final String name;

  /// The platformio environment the image was built for (parsed from the
  /// asset name, e.g. `Xiao_S3_WIO_repeater`).
  final String env;

  /// Version stamp as it appears in the asset name, e.g. `v1.18.0-r4`.
  /// The fork's releases no longer append a build stamp, so this is also the
  /// version shown in the UI and reported by `ota status`.
  final String version;

  final int size;
  final String downloadUrl;

  /// Lowercase hex from the release's `SHA256SUMS.txt`, when published.
  final String? sha256;

  bool get hasSha256 => sha256 != null && sha256!.length == 64;

  static final _versionRe = RegExp(r'-v[0-9]');
  // OTA targets ESP32 dual-app boards: only the raw app-slot .bin is
  // installable. UF2/zip are for USB flashing; -merged.bin carries the
  // bootloader and would never land correctly in the inactive slot.
  static const _extension = '.bin';

  /// Parse an asset name of the form `<env>-v<version>.bin`.
  /// Returns null when it is not a firmware asset at all, is a `-merged.bin`
  /// (bootloader included) image, or carries the retired `-filter-<sha>` name.
  static FirmwareAsset? parse({
    required String name,
    required int size,
    required String downloadUrl,
    String? sha256,
  }) {
    if (!name.endsWith(_extension)) return null;
    if (name.contains('-merged.')) return null; // never for OTA
    if (name.toLowerCase().contains('filter')) return null; // retired naming
    final base = name.substring(0, name.length - _extension.length);
    final match = _versionRe.firstMatch(base);
    if (match == null) return null;
    final env = base.substring(0, match.start);
    if (env.isEmpty) return null;
    var version = base.substring(match.start + 1);
    return FirmwareAsset(
      name: name,
      env: env,
      version: version,
      size: size,
      downloadUrl: downloadUrl,
      sha256: sha256,
    );
  }
}

class FirmwareRelease {
  const FirmwareRelease({
    required this.tag,
    required this.name,
    required this.prerelease,
    required this.publishedAt,
    required this.appImages,
  });

  /// Release tag, e.g. `v1.18.0-r4` (stable) or `v1.18.0-dev.7`.
  final String tag;
  final String name;
  final bool prerelease;
  final String publishedAt;
  final List<FirmwareAsset> appImages;

  bool get isDevTrack => tag.contains('-dev.');
}

/// The catalog: fork releases + their installable assets.
class Catalog {
  const Catalog({
    required this.releases,
    required this.fetchedAt,
    required this.sumsAvailable,
    required this.fromCache,
  });

  final List<FirmwareRelease> releases;
  final DateTime fetchedAt;

  /// Whether the release assets carry `SHA256SUMS.txt` to verify downloads
  /// against. When false the app downloads anyway and relies on the
  /// device-side SHA-256 gate (the hard backstop by design).
  final bool sumsAvailable;

  final bool fromCache;
}

class GitHubSourceException implements Exception {
  GitHubSourceException(this.message);

  final String message;

  @override
  String toString() => 'GitHubSourceException: $message';
}

/// Reads the fork's GitHub releases for repeater firmware.
///
/// [fetchJson] and [fetchBytes] are injectable for hermetic tests. The
/// default implementations use package:http. The catalog is cached on disk
/// for [cacheTtl] (default 7 days) so offline re-launches still see it; a
/// stale cache is served when the network fetch fails, flagged via
/// [Catalog.fromCache].
class GitHubSource {
  GitHubSource({
    required this.fetchJson,
    required this.fetchBytes,
    this.cacheFile,
    this.cacheTtl = const Duration(days: 7),
  });

  /// `GET <url>` → decoded JSON (a List or Map).
  final Future<dynamic> Function(Uri url) fetchJson;

  /// `GET <url>` → raw bytes.
  final Future<Uint8List> Function(Uri url) fetchBytes;

  /// Where the catalog JSON is cached. Null disables caching.
  final File? cacheFile;

  final Duration cacheTtl;

  static final releasesUrl = Uri.parse(
      'https://api.github.com/repos/$_releaseRepo/releases?per_page=30');

  /// Bumped when the cached naming scheme changes, so an old cache is ignored
  /// instead of showing retired `filter-v*` releases offline.
  static const int cacheFormat = 2;

  /// Default catalog: network first, cache fallback.
  ///
  /// [cacheOnly] never touches the network — the offline switch uses it, so a
  /// device in the field cannot sit in a connect timeout on every launch.
  Future<Catalog> catalog(
      {bool forceRefresh = false, bool cacheOnly = false}) async {
    final cached = await _readCache();
    if (cacheOnly) {
      if (cached != null) return cached;
      throw GitHubSourceException('offline mode: no cached release list');
    }
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < cacheTtl) {
      return cached;
    }
    try {
      final releases = await _fetchReleases();
      final sumsAvailable = releases.any((r) => r.assetsHaveSums);
      final catalog = Catalog(
        releases: releases.map((r) => r.release).toList(),
        fetchedAt: DateTime.now(),
        sumsAvailable: sumsAvailable,
        fromCache: false,
      );
      await _writeCache(catalog);
      return catalog;
    } catch (e) {
      if (cached != null) {
        return Catalog(
          releases: cached.releases,
          fetchedAt: cached.fetchedAt,
          sumsAvailable: cached.sumsAvailable,
          fromCache: true,
        );
      }
      rethrow;
    }
  }

  Future<List<UintedFirmwareRelease>> _fetchReleases() async {
    final json = await fetchJson(releasesUrl);
    if (json is! List) {
      throw GitHubSourceException('unexpected releases response');
    }
    final out = <UintedFirmwareRelease>[];
    for (final entry in json) {
      if (entry is! Map) continue;
      final tag = entry['tag_name'] as String? ?? '?';
      // The fork renamed its releases; retired tags must never reach the UI.
      if (tag.toLowerCase().startsWith('filter-')) continue;
      final assets = (entry['assets'] as List?) ?? const [];
      final sumsAsset = assets.cast<Map?>().firstWhere(
            (a) => a != null && (a['name'] as String?) == 'SHA256SUMS.txt',
            orElse: () => null,
          );
      Map<String, String> sums = const {};
      if (sumsAsset != null) {
        final url = Uri.parse(sumsAsset['browser_download_url'] as String);
        sums = await _fetchSums(url);
      }
      final images = <FirmwareAsset>[];
      for (final a in assets) {
        if (a is! Map) continue;
        final asset = FirmwareAsset.parse(
          name: a['name'] as String? ?? '',
          size: (a['size'] as num?)?.toInt() ?? 0,
          downloadUrl: a['browser_download_url'] as String? ?? '',
          sha256: sums[a['name'] as String? ?? ''],
        );
        if (asset != null) images.add(asset);
      }
      out.add(UintedFirmwareRelease(
        release: FirmwareRelease(
          tag: tag,
          name: entry['name'] as String? ?? '?',
          prerelease: entry['prerelease'] as bool? ?? false,
          publishedAt: entry['published_at'] as String? ?? '',
          appImages: images,
        ),
        assetsHaveSums: sums.isNotEmpty,
      ));
    }
    return out;
  }

  /// Fetch and verify one asset when its SHA-256 is known. When the release
  /// carries no SHA256SUMS.txt the bytes are returned unverified (device
  /// SHA-256 is the gate either way).
  Future<Uint8List> downloadAsset(FirmwareAsset asset) async {
    final bytes = await fetchBytes(Uri.parse(asset.downloadUrl));
    if (asset.hasSha256) {
      final actual = sha256.convert(bytes).toString();
      if (actual != asset.sha256!.toLowerCase()) {
        throw GitHubSourceException(
            'downloaded ${asset.name} failed its SHA-256 check');
      }
    }
    return bytes;
  }

  Future<Map<String, String>> _fetchSums(Uri url) async {
    try {
      final bytes = await fetchBytes(url);
      final text = utf8.decode(bytes);
      final out = <String, String>{};
      for (final line in const LineSplitter().convert(text)) {
        final match =
            RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
        if (match != null) {
          out[match.group(2)!.trim()] = match.group(1)!.toLowerCase();
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  Future<Catalog?> _readCache() async {
    final file = cacheFile;
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['format'] != cacheFormat) return null;
      final releases = (decoded['releases'] as List? ?? const [])
          .whereType<Map>()
          .map(_releaseFromCacheJson)
          .whereType<FirmwareRelease>()
          .toList();
      return Catalog(
        releases: releases,
        fetchedAt: DateTime.tryParse(decoded['fetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        sumsAvailable: decoded['sumsAvailable'] as bool? ?? false,
        fromCache: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(Catalog catalog) async {
    final file = cacheFile;
    if (file == null) return;
    try {
      final json = {
        'format': cacheFormat,
        'fetchedAt': catalog.fetchedAt.toIso8601String(),
        'sumsAvailable': catalog.sumsAvailable,
        'releases': [
          for (final r in catalog.releases)
            {
              'tag': r.tag,
              'name': r.name,
              'prerelease': r.prerelease,
              'publishedAt': r.publishedAt,
              'appImages': [
                for (final a in r.appImages)
                  {
                    'name': a.name,
                    'env': a.env,
                    'version': a.version,
                    'size': a.size,
                    'downloadUrl': a.downloadUrl,
                    if (a.sha256 != null) 'sha256': a.sha256,
                  },
              ],
            },
        ],
      };
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(json), flush: true);
    } catch (_) {
      // A cache write failure must never fail the catalog fetch.
    }
  }

  static FirmwareRelease? _releaseFromCacheJson(Map entry) {
    final images = (entry['appImages'] as List? ?? const [])
        .whereType<Map>()
        .map((a) => FirmwareAsset(
              name: a['name'] as String? ?? '',
              env: a['env'] as String? ?? '',
              version: a['version'] as String? ?? '',
              size: (a['size'] as num?)?.toInt() ?? 0,
              downloadUrl: a['downloadUrl'] as String? ?? '',
              sha256: a['sha256'] as String?,
            ))
        .toList();
    return FirmwareRelease(
      tag: entry['tag'] as String? ?? '?',
      name: entry['name'] as String? ?? '?',
      prerelease: entry['prerelease'] as bool? ?? false,
      publishedAt: entry['publishedAt'] as String? ?? '',
      appImages: images,
    );
  }
}

class UintedFirmwareRelease {
  UintedFirmwareRelease({required this.release, required this.assetsHaveSums});

  final FirmwareRelease release;
  final bool assetsHaveSums;
}

/// Default implementations (package:http) for the app.
Future<dynamic> httpFetchJson(Uri url) async {
  final response =
      await http.get(url, headers: {'accept': 'application/vnd.github+json'});
  if (response.statusCode != 200) {
    throw GitHubSourceException('HTTP ${response.statusCode} for $url');
  }
  return jsonDecode(response.body);
}

Future<Uint8List> httpFetchBytes(Uri url) async {
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw GitHubSourceException('HTTP ${response.statusCode} for $url');
  }
  return response.bodyBytes;
}
