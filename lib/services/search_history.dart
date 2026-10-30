import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

/// 過去に検索した地点。履歴から選ぶと、保存済みの結果ですぐに表示できる。
class SearchPoint {
  const SearchPoint(this.position, this.label, this.radius, this.at);

  final LatLng position;
  final String label;
  final int radius;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'lat': position.latitude,
        'lon': position.longitude,
        'label': label,
        'radius': radius,
        'at': at.toIso8601String(),
      };

  factory SearchPoint.fromJson(Map<String, dynamic> json) => SearchPoint(
        LatLng((json['lat'] as num).toDouble(), (json['lon'] as num).toDouble()),
        json['label'] as String,
        json['radius'] as int,
        DateTime.parse(json['at'] as String),
      );
}

class SearchHistoryStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}search_history.json');
  }

  Future<List<SearchPoint>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final json = jsonDecode(await file.readAsString()) as List;
    return json.cast<Map<String, dynamic>>().map(SearchPoint.fromJson).toList();
  }

  Future<void> save(List<SearchPoint> points) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(points.map((p) => p.toJson()).toList()));
  }
}
