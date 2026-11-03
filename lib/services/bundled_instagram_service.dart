import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

/// アプリ内に予め埋め込んだ東京都・神奈川県の Instagram アカウント付きスポットデータ。
/// 通信前やオフライン時でも、東京・神奈川エリアでは Instagram アカウントが即座に表示される。
class BundledInstagramService {
  BundledInstagramService({String assetPath = defaultAssetPath, AssetBundle? bundle})
      : _assetPath = assetPath,
        _bundle = bundle;

  /// テスト用（アセット読み込みなしで直接タイルデータを渡す）。
  BundledInstagramService.fromTiles(Map<String, List<Map<String, dynamic>>> tiles, {double tileDeg = 0.1})
      : _assetPath = defaultAssetPath,
        _bundle = null,
        _tiles = tiles,
        _tileDeg = tileDeg,
        _loaded = true;

  static const defaultAssetPath = 'assets/data/tokyo_kanagawa_instagram.bin';

  final String _assetPath;
  final AssetBundle? _bundle;

  Map<String, List<Map<String, dynamic>>> _tiles = const {};
  double _tileDeg = 0.1;
  bool _loaded = false;
  Future<void>? _loading;

  int get totalSpots => _tiles.values.fold(0, (sum, list) => sum + list.length);

  /// 起動時に裏で展開しておくことで、初回検索を 0ms で返せるようにする。
  Future<void> warmUp() => _ensureLoaded();

  /// [center] から [radiusMeters] の範囲にかかる東京・神奈川の埋め込み Instagram スポットを返す。
  Future<List<Map<String, dynamic>>> elementsAround(LatLng center, int radiusMeters) async {
    await _ensureLoaded();
    if (_tiles.isEmpty) return const [];
    final keys = tileKeysAround(center, radiusMeters);
    if (keys.isEmpty) return const [];
    return [
      for (final k in keys) ...?_tiles[k],
    ];
  }

  /// メモリ展開済みのデータから同期的に取り出す（[warmUp] 完了後に即座に使う用）。
  List<Map<String, dynamic>> cachedElementsAround(LatLng center, int radiusMeters) {
    if (!_loaded || _tiles.isEmpty) return const [];
    final keys = tileKeysAround(center, radiusMeters);
    if (keys.isEmpty) return const [];
    return [
      for (final k in keys) ...?_tiles[k],
    ];
  }

  List<String> tileKeysAround(LatLng center, int radiusMeters) {
    if (_tiles.isEmpty) return const [];
    final dLat = radiusMeters / 111320;
    final dLon = radiusMeters / (111320 * math.cos(center.latitude * math.pi / 180));
    int idx(double v) => (v / _tileDeg).floor();
    final keys = <(String, double)>[];
    for (var y = idx(center.latitude - dLat); y <= idx(center.latitude + dLat); y++) {
      for (var x = idx(center.longitude - dLon); x <= idx(center.longitude + dLon); x++) {
        final key = '${y}_$x';
        if (!_tiles.containsKey(key)) continue;
        final cy = (y + 0.5) * _tileDeg - center.latitude;
        final cx = ((x + 0.5) * _tileDeg - center.longitude) * math.cos(center.latitude * math.pi / 180);
        keys.add((key, cy * cy + cx * cx));
      }
    }
    keys.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final k in keys) k.$1];
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final data = await (_bundle ?? rootBundle).load(_assetPath);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final decoded = await Isolate.run(() => _parseGzipJson(bytes));
      _tileDeg = decoded.tileDeg;
      _tiles = decoded.tiles;
    } catch (_) {
      _tiles = const {};
    } finally {
      _loaded = true;
    }
  }

  static ({double tileDeg, Map<String, List<Map<String, dynamic>>> tiles}) _parseGzipJson(Uint8List bytes) {
    final rawBytes = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b ? gzip.decode(bytes) : bytes;
    final root = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
    final tileDeg = (root['tileDeg'] as num?)?.toDouble() ?? 0.1;
    final rawTiles = root['tiles'] as Map<String, dynamic>? ?? const {};
    final tiles = <String, List<Map<String, dynamic>>>{
      for (final MapEntry(:key, :value) in rawTiles.entries)
        key: (value as List).cast<Map<String, dynamic>>(),
    };
    return (tileDeg: tileDeg, tiles: tiles);
  }
}
