import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'listing.dart';
import 'social.dart';

export 'social.dart';

/// 地図に表示する場所の種類。並び順がマーカーの色を決めるときの優先順位になる。
enum PlaceCategory {
  volunteer('ボランティア', Icons.volunteer_activism_outlined, Color(0xFF2E7D32)),
  experience('有償体験', Icons.palette_outlined, Color(0xFFEF6C00)),
  highSchool('高校', Icons.school_outlined, Color(0xFF1E88E5)),
  university('大学', Icons.account_balance_outlined, Color(0xFF5E35B1)),
  sns('SNS', Icons.alternate_email, Color(0xFFDD2A7B));

  const PlaceCategory(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

/// OSM 上の場所、またはユーザーが登録した募集情報。
class Place {
  Place({
    required this.id,
    required this.name,
    required this.position,
    required Set<PlaceCategory> categories,
    List<SocialLink>? links,
    this.kind,
    this.address,
    this.website,
    this.wikidata,
    this.listing,
    this.precomputed = false,
  })  : _baseCategories = categories,
        links = links ?? [];

  /// OSM なら `node/123`、登録した募集なら `listing/<id>`。
  final String id;
  final String name;
  final LatLng position;
  final Set<PlaceCategory> _baseCategories;

  /// OSM のタグ・Wikidata・公式サイトから見つかった SNS アカウント。
  final List<SocialLink> links;

  /// 「カフェ」「高等学校」のような細かい種別。
  final String? kind;
  final String? address;
  final String? website;
  final String? wikidata;

  /// ユーザーが登録した募集情報の場合のみ。
  final UserListing? listing;

  /// 配信データで Wikidata・公式サイトの確認まで済んでいるもの（アプリで調べ直さない）。
  final bool precomputed;

  double distanceMeters = 0;

  Set<PlaceCategory> get categories => links.isEmpty ? _baseCategories : {..._baseCategories, PlaceCategory.sns};

  /// SNS 以外のカテゴリ。
  Set<PlaceCategory> get baseCategories => _baseCategories;

  bool get isListing => listing != null;

  String? get osmUrl => isListing ? null : 'https://www.openstreetmap.org/$id';

  /// SNS 以外のカテゴリ（学校など）に当てはまるか。公式サイトを調べる対象になる。
  bool get isInstitution => _baseCategories.isNotEmpty;

  bool hasLinkOn(Set<SnsPlatform> platforms) => links.any((l) => platforms.contains(l.platform));

  /// [platforms] の中で最初に表示するアカウント（SNS の並び順で決める）。
  SocialLink? primaryLink([Set<SnsPlatform>? platforms]) {
    for (final p in SnsPlatform.values) {
      if (platforms != null && !platforms.contains(p)) continue;
      for (final l in links) {
        if (l.platform == p) return l;
      }
    }
    return null;
  }

  /// SNS の並び順に並べたアカウント。
  List<SocialLink> get sortedLinks => [...links]..sort((a, b) => a.platform.index.compareTo(b.platform.index));

  void addLinks(Iterable<SocialLink> found) {
    for (final link in found) {
      if (!links.contains(link)) links.add(link);
    }
  }

  /// 表示中のカテゴリのうち、マーカーの色に使うもの。
  PlaceCategory primaryCategory(Set<PlaceCategory> enabled) {
    final cats = categories;
    for (final c in PlaceCategory.values) {
      if (cats.contains(c) && enabled.contains(c)) return c;
    }
    return cats.first;
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [name, kind, address, ...links.map((l) => l.username), listing?.organizer, listing?.description]
        .whereType<String>()
        .any((s) => s.toLowerCase().contains(q));
  }

  /// Overpass API（または配信データ）の要素 1 件から生成する。どのカテゴリにも当てはまらなければ null。
  /// 配信データの要素には、Wikidata・公式サイトで見つけた分も含めた `sns` が（空でも）付いている。
  static Place? fromOsm(Map<String, dynamic> element) {
    final tags = (element['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
    // 「ボランティア通り」のような道路名や停留所は除く。
    if (tags.containsKey('highway') || tags.containsKey('public_transport')) return null;

    final pos = positionOf(element);
    if (pos == null) return null;

    final precomputed = element['sns'] is List;
    final links = precomputed
        ? [for (final j in element['sns'] as List) ?SocialLink.fromJson(j)]
        : socialFromTags(tags);
    final name = (tags['name:ja'] ?? tags['name'] ?? tags['brand'] ?? links.firstOrNull?.username) as String?;

    final categories = classify(tags, name ?? '');
    if ((categories.isEmpty && links.isEmpty) || name == null) return null;

    return Place(
      id: '${element['type']}/${element['id']}',
      name: name,
      position: pos,
      categories: categories,
      links: links,
      kind: _kindOf(tags, categories),
      address: _addressOf(tags),
      website: (tags['contact:website'] ?? tags['website']) as String?,
      wikidata: tags['wikidata'] as String?,
      precomputed: precomputed,
    );
  }

  /// Overpass の要素の座標（way / relation は中心点）。
  static LatLng? positionOf(Map<String, dynamic> element) {
    final double? lat = (element['lat'] ?? element['center']?['lat'])?.toDouble();
    final double? lon = (element['lon'] ?? element['center']?['lon'])?.toDouble();
    return lat == null || lon == null ? null : LatLng(lat, lon);
  }
}

/// 要素の一覧を場所の一覧にする。建物とノードの両方に登録された同じ施設は 1 件にまとめる。
List<Place> placesFromOsm(List<Map<String, dynamic>> elements) {
  final seen = <String>{};
  return [
    for (final el in elements)
      if (Place.fromOsm(el) case final place?)
        if (seen.add('${place.name}|${place.primaryLink()?.url ?? ''}'.toLowerCase())) place,
  ];
}

final _highSchoolName = RegExp(r'高等学校|高校|中等教育学校|high school', caseSensitive: false);
final _volunteerName = RegExp(r'ボランティア|社会福祉協議会|市民活動|NPOセンター|volunteer', caseSensitive: false);
final _experienceName = RegExp(r'体験|ワークショップ|workshop|陶芸', caseSensitive: false);
const _experienceCrafts = {'pottery', 'glassblower'};

Set<PlaceCategory> classify(Map<String, dynamic> tags, String name) {
  final amenity = tags['amenity'];
  final isced = (tags['isced:level'] as String? ?? '').split(RegExp('[;,]')).map((s) => s.trim());
  return {
    if (amenity == 'school' && (_highSchoolName.hasMatch(name) || isced.contains('3')))
      PlaceCategory.highSchool,
    if (amenity == 'university' || (amenity == 'college' && name.contains('大学')))
      PlaceCategory.university,
    if (_volunteerName.hasMatch(name)) PlaceCategory.volunteer,
    if (_experienceName.hasMatch(name) || _experienceCrafts.contains(tags['craft']))
      PlaceCategory.experience,
  };
}

const _kindLabels = {
  'restaurant': 'レストラン',
  'cafe': 'カフェ',
  'bar': 'バー',
  'pub': 'パブ',
  'fast_food': 'ファストフード',
  'ice_cream': 'アイスクリーム',
  'nightclub': 'クラブ',
  'theatre': '劇場',
  'cinema': '映画館',
  'arts_centre': 'アートセンター',
  'community_centre': 'コミュニティセンター',
  'social_facility': '福祉施設',
  'townhall': '公共施設',
  'place_of_worship': '寺社・教会',
  'library': '図書館',
  'school': '学校',
  'university': '大学',
  'college': '短大・専門学校',
  'clinic': 'クリニック',
  'dentist': '歯科',
  'pharmacy': '薬局',
  'clothes': 'アパレル',
  'shoes': '靴',
  'bakery': 'ベーカリー',
  'confectionery': '菓子店',
  'hairdresser': '美容室',
  'beauty': '美容',
  'books': '書店',
  'florist': '花屋',
  'gift': '雑貨',
  'supermarket': 'スーパー',
  'convenience': 'コンビニ',
  'hotel': 'ホテル',
  'hostel': 'ホステル',
  'museum': '博物館・美術館',
  'gallery': 'ギャラリー',
  'attraction': '観光スポット',
  'theme_park': 'テーマパーク',
  'fitness_centre': 'ジム',
  'sports_centre': 'スポーツ施設',
  'park': '公園',
  'pottery': '陶芸工房',
  'glassblower': 'ガラス工房',
  'ngo': 'NPO・NGO',
};

String? _kindOf(Map<String, dynamic> tags, Set<PlaceCategory> categories) {
  if (categories.contains(PlaceCategory.highSchool)) return '高等学校';
  for (final key in ['amenity', 'shop', 'tourism', 'leisure', 'craft', 'office', 'club']) {
    final value = tags[key] as String?;
    if (value != null && value != 'yes') return _kindLabels[value] ?? value.replaceAll('_', ' ');
  }
  return null;
}

String? _addressOf(Map<String, dynamic> tags) {
  if (tags['addr:full'] is String) return tags['addr:full'] as String;
  final parts = [
    tags['addr:province'],
    tags['addr:city'],
    tags['addr:quarter'],
    tags['addr:neighbourhood'],
    tags['addr:block_number'] ?? tags['addr:street'],
    tags['addr:housenumber'],
  ].whereType<String>().toList();
  return parts.isEmpty ? null : parts.join(' ');
}
