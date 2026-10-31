import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../models/place.dart';
import 'overpass_service.dart';
import 'spot_data_service.dart';

/// 場所のデータを集める。日本国内は配信データ（[SpotDataService]）をタイル単位で読むのですぐに表示できる。
/// 配信データの範囲外や配信サーバーに繋がらないときは Overpass API から取得し、
/// 約 2km 四方のタイルに分けて端末に保存して次回以降は通信せずに再利用する。
class PlaceRepository {
  PlaceRepository({OverpassService? overpass, SpotDataService? spots})
      : _overpass = overpass ?? OverpassService(),
        _spots = spots ?? SpotDataService();

  final OverpassService _overpass;
  final SpotDataService _spots;

  static const tileDeg = 0.02;

  /// 一度に問い合わせる区画の大きさ（タイル数）。約 25km 四方。
  static const chunkTiles = 12;
  static const maxAge = Duration(days: 7);

  final _memory = <String, _Tile>{};
  Directory? _dir;

  /// [center] から [radiusMeters] の範囲の要素を集める。
  /// 保存済みのタイルを先に、取得したタイルを区画ごとに [onElements] へ（それまでの全件で）渡す。
  /// [refresh] が true なら保存済みのタイルも取り直す。
  Future<void> load(
    LatLng center,
    int radiusMeters, {
    bool refresh = false,
    required void Function(List<Map<String, dynamic>> elements, {required bool complete}) onElements,
    void Function(String)? onStatus,
  }) async {
    final meta = await _spots.meta(refresh: refresh);
    if (meta != null && meta.covers(center)) {
      final loaded = <String, List<Map<String, dynamic>>>{};
      List<Map<String, dynamic>> all() => [for (final e in loaded.values) ...e];
      final keys = meta.tilesAround(center, radiusMeters);
      try {
        await _spots.tiles(
          meta,
          keys,
          refresh: refresh,
          onCached: (tiles) {
            loaded.addAll(tiles);
            final complete = tiles.length == keys.length;
            if (tiles.isNotEmpty || complete) onElements(all(), complete: complete);
            if (!complete) onStatus?.call('スポットデータを取得中…');
          },
          onFetched: (key, elements) {
            loaded[key] = elements;
            onElements(all(), complete: loaded.length == keys.length);
          },
        );
        return;
      } catch (e) {
        // 1 枚も読めなければ Overpass API から取得する
        if (loaded.isNotEmpty) rethrow;
        onStatus?.call('配信データに繋がらないため、OpenStreetMap から直接取得します…');
      }
    }
    await _loadFromOverpass(center, radiusMeters, refresh: refresh, onElements: onElements, onStatus: onStatus);
  }

  Future<void> _loadFromOverpass(
    LatLng center,
    int radiusMeters, {
    required bool refresh,
    required void Function(List<Map<String, dynamic>> elements, {required bool complete}) onElements,
    void Function(String)? onStatus,
  }) async {
    final keys = tilesAround(center, radiusMeters);
    final found = <String, List<Map<String, dynamic>>>{};
    final missing = <(int, int)>[];
    for (final key in keys) {
      final tile = refresh ? null : await _read(key);
      if (tile != null) {
        found[_name(key)] = tile.elements;
      } else {
        missing.add(key);
      }
    }
    List<Map<String, dynamic>> all() => [for (final e in found.values) ...e];

    if (missing.isEmpty) {
      onElements(all(), complete: true);
      return;
    }
    if (found.isNotEmpty) onElements(all(), complete: false);

    final chunks = _chunks(missing, center);
    var done = 0;
    for (final chunk in chunks) {
      onStatus?.call(chunks.length == 1
          ? '地図データを取得中…'
          : '地図データを取得中… (${done + 1}/${chunks.length} 区画)');
      final elements = await _overpass.fetch(_boundsOf(chunk), onStatus: onStatus);
      final byTile = {for (final k in chunk) _name(k): <Map<String, dynamic>>[]};
      for (final el in elements) {
        final pos = Place.positionOf(el);
        if (pos == null) continue;
        byTile[_name(_tileOf(pos))]?.add(el);
      }
      for (final MapEntry(:key, :value) in byTile.entries) {
        found[key] = value;
        await _write(key, value);
      }
      done++;
      onElements(all(), complete: done == chunks.length);
    }
  }

  static List<(int, int)> tilesAround(LatLng center, int radiusMeters) {
    final dLat = radiusMeters / 111320;
    final dLon = radiusMeters / (111320 * math.cos(center.latitude * math.pi / 180));
    final (y0, x0) = _tileOf(LatLng(center.latitude - dLat, center.longitude - dLon));
    final (y1, x1) = _tileOf(LatLng(center.latitude + dLat, center.longitude + dLon));
    return [
      for (var y = y0; y <= y1; y++)
        for (var x = x0; x <= x1; x++) (y, x),
    ];
  }

  static (int, int) _tileOf(LatLng p) => ((p.latitude / tileDeg).floor(), (p.longitude / tileDeg).floor());

  static String _name((int, int) key) => '${key.$1}_${key.$2}';

  /// 足りないタイルを区画にまとめ、中心に近い区画から順に並べる。
  static List<List<(int, int)>> _chunks(List<(int, int)> missing, LatLng center) {
    final groups = <(int, int), List<(int, int)>>{};
    for (final key in missing) {
      final chunk = ((key.$1 / chunkTiles).floor(), (key.$2 / chunkTiles).floor());
      groups.putIfAbsent(chunk, () => []).add(key);
    }
    double distance(List<(int, int)> chunk) {
      final b = _boundsOf(chunk);
      final lat = (b.south + b.north) / 2 - center.latitude;
      final lon = (b.west + b.east) / 2 - center.longitude;
      return lat * lat + lon * lon;
    }

    return groups.values.toList()..sort((a, b) => distance(a).compareTo(distance(b)));
  }

  static Bounds _boundsOf(List<(int, int)> tiles) {
    final ys = tiles.map((t) => t.$1);
    final xs = tiles.map((t) => t.$2);
    return Bounds(
      ys.reduce(math.min) * tileDeg,
      xs.reduce(math.min) * tileDeg,
      (ys.reduce(math.max) + 1) * tileDeg,
      (xs.reduce(math.max) + 1) * tileDeg,
    );
  }

  Future<Directory> _cacheDir() async {
    return _dir ??= await Directory(
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}osm_tiles',
    ).create(recursive: true);
  }

  Future<_Tile?> _read((int, int) key) async {
    final name = _name(key);
    var tile = _memory[name];
    if (tile == null) {
      try {
        final file = File('${(await _cacheDir()).path}${Platform.pathSeparator}$name.json');
        if (await file.exists()) {
          final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          tile = _Tile(
            DateTime.parse(json['fetchedAt'] as String),
            (json['elements'] as List).cast<Map<String, dynamic>>(),
          );
          _memory[name] = tile;
        }
      } catch (_) {
        // 壊れたキャッシュは取り直す
      }
    }
    if (tile == null || DateTime.now().difference(tile.fetchedAt) > maxAge) return null;
    return tile;
  }

  Future<void> _write(String name, List<Map<String, dynamic>> elements) async {
    final tile = _Tile(DateTime.now(), elements);
    _memory[name] = tile;
    try {
      final file = File('${(await _cacheDir()).path}${Platform.pathSeparator}$name.json');
      await file.writeAsString(jsonEncode({'fetchedAt': tile.fetchedAt.toIso8601String(), 'elements': elements}));
    } catch (_) {
      // 保存できなくても表示には影響しない
    }
  }
}

class _Tile {
  _Tile(this.fetchedAt, this.elements);
  final DateTime fetchedAt;
  final List<Map<String, dynamic>> elements;
}
