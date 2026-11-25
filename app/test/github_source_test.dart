import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/github_source.dart';

Map<String, dynamic> _releaseJson({
  required String tag,
  required bool prerelease,
  required String publishedAt,
  required List<Map<String, dynamic>> assets,
}) =>
    {
      'tag_name': tag,
      'name': 'Firmware $tag',
      'prerelease': prerelease,
      'published_at': publishedAt,
      'assets': assets,
    };

Map<String, dynamic> _asset(String name, int size, String tag) => {
      'name': name,
      'size': size,
      'browser_download_url':
          'https://github.com/jhuebert/MeshCore/releases/download/$tag/$name',
    };

Uint8List _imageBytes() =>
    Uint8List.fromList(List<int>.generate(1000, (i) => (i * 7 + 3) & 0xFF));

void main() {
  group('FirmwareAsset.parse', () {
    test('parses repeater app images with hyphenated envs', () {
      final asset = FirmwareAsset.parse(
        name: 'Ebyte_EoRa-S3_Repeater-v1.18.0-r4.bin',
        size: 123,
        downloadUrl: 'https://example/x',
      );
      expect(asset, isNotNull);
      expect(asset!.env, 'Ebyte_EoRa-S3_Repeater');
      expect(asset.version, 'v1.18.0-r4');
    });

    test('parses dotted dev versions', () {
      final asset = FirmwareAsset.parse(
        name: 'Xiao_S3_WIO_repeater-v1.18.0-dev.7.bin',
        size: 1,
        downloadUrl: '',
      );
      expect(asset!.env, 'Xiao_S3_WIO_repeater');
      expect(asset.version, 'v1.18.0-dev.7');
    });

    test('rejects merged images and non-firmware assets', () {
      for (final name in [
        'Xiao_S3_WIO_repeater-v1.18.0-r4-merged.bin',
        'Xiao_S3_WIO_repeater-v1.18.0-r4.uf2',
        'Xiao_S3_WIO_repeater-v1.18.0-r4.zip',
        'Xiao_S3_WIO_repeater-v1.18.0-r4-filter-d1ebd2f.bin',
        'SHA256SUMS.txt',
        'random.bin',
      ]) {
        expect(
          FirmwareAsset.parse(name: name, size: 1, downloadUrl: ''),
          isNull,
          reason: name,
        );
      }
    });
  });

  group('GitHubSource.catalog', () {
    test('parses releases, filters installable images, sorts newest first',
        () async {
      final image = _imageBytes();
      final imageSha = sha256.convert(image).toString();
      final releasesJson = jsonEncode([
        _releaseJson(
          tag: 'v1.18.0-r4',
          prerelease: false,
          publishedAt: '2026-11-12T20:17:54Z',
          assets: [
            _asset('Xiao_S3_WIO_repeater-v1.18.0-r4.bin',
                image.length, 'v1.18.0-r4'),
            _asset('Xiao_S3_WIO_repeater-v1.18.0-r4-merged.bin',
                9000000, 'v1.18.0-r4'),
            _asset('SHA256SUMS.txt', 10, 'v1.18.0-r4'),
          ],
        ),
        _releaseJson(
          tag: 'v1.18.0-dev.7',
          prerelease: true,
          publishedAt: '2026-11-10T19:16:00Z',
          assets: [
            _asset('RAK_4631_repeater-v1.18.0-dev.7.bin',
                image.length, 'v1.18.0-dev.7'),
          ],
        ),
      ]);
      final sums =
          '$imageSha  Xiao_S3_WIO_repeater-v1.18.0-r4.bin\n';

      final source = GitHubSource(
        fetchJson: (url) async => jsonDecode(releasesJson),
        fetchBytes: (url) async {
          if (url.toString().endsWith('SHA256SUMS.txt')) {
            return Uint8List.fromList(utf8.encode(sums));
          }
          return image;
        },
      );
      final catalog = await source.catalog();
      expect(catalog.fromCache, isFalse);
      expect(catalog.sumsAvailable, isTrue);
      expect(catalog.releases, hasLength(2));

      final stable =
          catalog.releases.firstWhere((r) => r.tag == 'v1.18.0-r4');
      expect(stable.appImages, hasLength(1)); // merged image excluded
      expect(stable.appImages.single.sha256, imageSha);
      expect(stable.isDevTrack, isFalse);

      final dev =
          catalog.releases.firstWhere((r) => r.tag == 'v1.18.0-dev.7');
      expect(dev.isDevTrack, isTrue);
      expect(dev.appImages.single.env, 'RAK_4631_repeater');
    });

    test('ignores retired filter-v releases and their assets', () async {
      final releasesJson = jsonEncode([
        _releaseJson(
          tag: 'filter-v1.18.0-r4',
          prerelease: false,
          publishedAt: '2026-11-12T20:17:54Z',
          assets: [
            _asset('Xiao_S3_WIO_repeater-v1.18.0-r4-filter-d1ebd2f.bin', 1,
                'filter-v1.18.0-r4'),
          ],
        ),
        _releaseJson(
          tag: 'v1.18.0-r4',
          prerelease: false,
          publishedAt: '2026-11-13T20:17:54Z',
          assets: [
            _asset('Xiao_S3_WIO_repeater-v1.18.0-r4.bin', 1, 'v1.18.0-r4'),
          ],
        ),
      ]);
      final source = GitHubSource(
        fetchJson: (_) async => jsonDecode(releasesJson),
        fetchBytes: (_) async => Uint8List(0),
      );
      final catalog = await source.catalog();
      expect(catalog.releases.map((r) => r.tag), ['v1.18.0-r4']);
      expect(catalog.releases.single.appImages.single.name,
          'Xiao_S3_WIO_repeater-v1.18.0-r4.bin');
    });

    test('ignores a cache written with the old naming format', () async {
      final dir = await Directory.systemTemp.createTemp('catalog_old_test');
      final cacheFile = File('${dir.path}/catalog.json');
      await cacheFile.writeAsString(jsonEncode({
        'fetchedAt': DateTime.now().toIso8601String(),
        'sumsAvailable': false,
        'releases': [
          {
            'tag': 'filter-v1.18.0-r4',
            'name': 'Filter Firmware v1.18.0-r4',
            'prerelease': false,
            'publishedAt': '2026-11-12T20:17:54Z',
            'appImages': [],
          },
        ],
      }));
      final source = GitHubSource(
        fetchJson: (_) => throw const SocketException('offline'),
        fetchBytes: (_) async => Uint8List(0),
        cacheFile: cacheFile,
      );
      await expectLater(source.catalog(), throwsA(isA<SocketException>()));
      await dir.delete(recursive: true);
    });

    test('downloadAsset verifies sha256 when known and rejects mismatches',
        () async {
      final image = _imageBytes();
      final goodSha = sha256.convert(image).toString();
      final asset = FirmwareAsset.parse(
        name: 'Xiao_S3_WIO_repeater-v1.18.0-r4.bin',
        size: image.length,
        downloadUrl: 'https://example/image.bin',
        sha256: goodSha,
      )!;
      var payload = image;
      final source = GitHubSource(
        fetchJson: (_) async => const [],
        fetchBytes: (_) async => payload,
      );
      expect(await source.downloadAsset(asset), image);

      payload =
          Uint8List.fromList([...image.sublist(0, image.length - 1), 0x00]);
      expect(() => source.downloadAsset(asset),
          throwsA(isA<GitHubSourceException>()));
    });

    test('serves the cache when the network fails', () async {
      final dir = await Directory.systemTemp.createTemp('catalog_test');
      final cacheFile = File('${dir.path}/catalog.json');
      final image = _imageBytes();
      final releasesJson = jsonEncode([
        _releaseJson(
          tag: 'v1.18.0-r4',
          prerelease: false,
          publishedAt: '2026-11-12T20:17:54Z',
          assets: [
            _asset('Xiao_S3_WIO_repeater-v1.18.0-r4.bin',
                image.length, 'v1.18.0-r4'),
          ],
        ),
      ]);
      final online = GitHubSource(
        fetchJson: (_) async => jsonDecode(releasesJson),
        fetchBytes: (_) async => Uint8List(0),
        cacheFile: cacheFile,
      );
      final fresh = await online.catalog();
      expect(fresh.fromCache, isFalse);

      final offline = GitHubSource(
        fetchJson: (_) => throw const SocketException('offline'),
        fetchBytes: (_) => throw const SocketException('offline'),
        cacheFile: cacheFile,
        cacheTtl: const Duration(days: 7),
      );
      final cached = await offline.catalog();
      expect(cached.fromCache, isTrue);
      expect(cached.releases.single.tag, 'v1.18.0-r4');
      await dir.delete(recursive: true);
    });

    test('cacheOnly uses the cache and never the network', () async {
      final dir = await Directory.systemTemp.createTemp('catalog_only_test');
      final cacheFile = File('${dir.path}/catalog.json');
      final releasesJson = jsonEncode([
        _releaseJson(
          tag: 'v1.18.0-r4',
          prerelease: false,
          publishedAt: '2026-11-12T20:17:54Z',
          assets: [
            _asset('Xiao_S3_WIO_repeater-v1.18.0-r4.bin', 1,
                'v1.18.0-r4'),
          ],
        ),
      ]);
      final online = GitHubSource(
        fetchJson: (_) async => jsonDecode(releasesJson),
        fetchBytes: (_) async => Uint8List(0),
        cacheFile: cacheFile,
      );
      await online.catalog();

      var fetched = false;
      final offline = GitHubSource(
        fetchJson: (_) async {
          fetched = true;
          return const [];
        },
        fetchBytes: (_) async {
          fetched = true;
          return Uint8List(0);
        },
        cacheFile: cacheFile,
        // Even a stale cache is served: the user explicitly went offline.
        cacheTtl: Duration.zero,
      );
      final cached = await offline.catalog(cacheOnly: true);
      expect(fetched, isFalse);
      expect(cached.fromCache, isTrue);
      expect(cached.releases.single.tag, 'v1.18.0-r4');

      final empty = GitHubSource(
        fetchJson: (_) async {
          fetched = true;
          return const [];
        },
        fetchBytes: (_) async => Uint8List(0),
      );
      await expectLater(
        empty.catalog(cacheOnly: true),
        throwsA(isA<GitHubSourceException>()),
      );
      expect(fetched, isFalse);
      await dir.delete(recursive: true);
    });
  });
}
