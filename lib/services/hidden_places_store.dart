import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 地図・一覧でチェックを付けて非表示にした場所（ID と表示名）を端末内の JSON ファイルに保存する。
class HiddenPlacesStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}hidden_places.json');
  }

  Future<Map<String, String>> load() async {
    final file = await _file();
    if (!await file.exists()) return {};
    final json = jsonDecode(await file.readAsString());
    if (json is Map) {
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is String) key: value,
      };
    }
    if (json is List) {
      return {for (final id in json.whereType<String>()) id: id};
    }
    return {};
  }

  Future<void> save(Map<String, String> items) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(items));
  }
}
