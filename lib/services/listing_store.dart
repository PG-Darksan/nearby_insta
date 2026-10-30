import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/listing.dart';

/// 登録した募集情報を端末内の JSON ファイルに保存する。
class ListingStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}listings.json');
  }

  Future<List<UserListing>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final json = jsonDecode(await file.readAsString()) as List;
    return json.cast<Map<String, dynamic>>().map(UserListing.fromJson).toList();
  }

  Future<void> save(List<UserListing> listings) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final json = const JsonEncoder.withIndent('  ').convert(listings.map((l) => l.toJson()).toList());
    await file.writeAsString(json);
  }
}
