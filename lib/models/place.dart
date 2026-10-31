import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'listing.dart';
import 'social.dart';

export 'social.dart';

/// 地図に表示する場所の種類。並び順がマーカーの色を決めるときの優先順位になる。
/// 飲食店・美容室は SNS より後にして、アカウントのあるお店は SNS のアイコンで表示する。
enum PlaceCategory {
  volunteer('ボランティア', Icons.volunteer_activism_outlined, Color(0xFF2E7D32), institution: true),
  experience('有償体験', Icons.palette_outlined, Color(0xFFEF6C00), institution: true),
  highSchool('高校', Icons.school_outlined, Color(0xFF1E88E5), institution: true),
  vocational('専門学校', Icons.design_services_outlined, Color(0xFF00897B), institution: true),
  university('大学', Icons.account_balance_outlined, Color(0xFF5E35B1), institution: true),
  correspondence('通信制', Icons.cast_for_education_outlined, Color(0xFF546E7A), institution: true),
  sns('SNS', Icons.alternate_email, Color(0xFFDD2A7B)),
  restaurant('飲食店', Icons.restaurant_outlined, Color(0xFFE53935)),
  beauty('美容室', Icons.content_cut_outlined, Color(0xFF00ACC1)),
  historic('史跡・名所', Icons.castle_outlined, Color(0xFF8D6E63)),
  company('本社・企業', Icons.business_outlined, Color(0xFF3949AB));

  const PlaceCategory(this.label, this.icon, this.color, {this.institution = false});

  final String label;
  final IconData icon;
  final Color color;

  /// 学校などの施設。全国データの範囲外では、アプリが公式サイトから SNS を探す。
  final bool institution;
}

/// お店や学校が誰向けか。OSM の male / female / unisex などのタグと名前（メンズ・レディース・女子大学など）で
/// 判定する。アカウントの持ち主の性別ではない。
enum Audience {
  women('女性向け', Icons.female, Color(0xFFD81B60)),
  unisex('男女兼用', Icons.wc, Color(0xFF7B1FA2)),
  men('男性向け', Icons.male, Color(0xFF1E88E5)),
  none('指定なし', Icons.remove_circle_outline, Color(0xFF757575));

  const Audience(this.label, this.icon, this.color);

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
    this.audience = Audience.none,
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

  /// 誰向けのお店・学校か。
  final Audience audience;

  double distanceMeters = 0;

  Set<PlaceCategory> get categories => links.isEmpty ? _baseCategories : {..._baseCategories, PlaceCategory.sns};

  /// SNS 以外のカテゴリ。
  Set<PlaceCategory> get baseCategories => _baseCategories;

  bool get isListing => listing != null;

  String? get osmUrl => isListing ? null : 'https://www.openstreetmap.org/$id';

  /// 学校などの施設か。全国データの範囲外では公式サイトを調べる対象になる。
  bool get isInstitution => _baseCategories.any((c) => c.institution);

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
    final baseName = (tags['name:ja'] ?? tags['name'] ?? tags['brand'] ?? links.firstOrNull?.username) as String?;

    final categories = classify(tags, baseName ?? '');
    if ((categories.isEmpty && links.isEmpty) || baseName == null) return null;

    return Place(
      id: '${element['type']}/${element['id']}',
      name: displayName(baseName, branch: tags['branch'] as String?, area: element['area'] as String?),
      position: pos,
      categories: categories,
      links: links,
      kind: _kindOf(tags, categories),
      address: _addressOf(tags),
      website: (tags['contact:website'] ?? tags['website']) as String?,
      wikidata: tags['wikidata'] as String?,
      precomputed: precomputed,
      audience: audienceOf(tags, baseName),
    );
  }

  /// チェーン店などの名前に支店名（OSM の branch）を付ける。支店名がなければ、配信データで付けた
  /// 近くの地名を括弧書きで付ける（例: スシロー 金沢八景店、スシロー（六浦））。
  static String displayName(String name, {String? branch, String? area}) {
    if (branch != null && branch.isNotEmpty && !name.contains(branch)) return '$name $branch';
    if (area != null && area.isNotEmpty && !name.contains(area)) return '$name（$area）';
    return name;
  }

  /// SNS で検索するときの言葉（括弧を空白にする）。
  String get searchQuery => name.replaceAll(RegExp(r'[（）()]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Overpass の要素の座標（way / relation は中心点）。
  static LatLng? positionOf(Map<String, dynamic> element) {
    final double? lat = (element['lat'] ?? element['center']?['lat'])?.toDouble();
    final double? lon = (element['lon'] ?? element['center']?['lon'])?.toDouble();
    return lat == null || lon == null ? null : LatLng(lat, lon);
  }
}

/// 要素の一覧を場所の一覧にする。建物とノードの両方に登録された同じ施設は 1 件にまとめる。
/// お店などは同じ名前の別の店舗があるので、約 200m 以内のものだけを同じ施設とみなす。
/// タイルが届くたびに全件で呼ばれるので、同じ要素（Map）から作った場所は使い回す。
List<Place> placesFromOsm(List<Map<String, dynamic>> elements) {
  final seen = <String>{};
  return [
    for (final el in elements)
      if (_placeOf(el) case final Place place)
        if (seen.add(_sameKey(place))) place,
  ];
}

String _sameKey(Place place) {
  final key = '${place.name}|${place.primaryLink()?.url ?? ''}'.toLowerCase();
  if (place.isInstitution) return key;
  final p = place.position;
  return '$key|${(p.latitude * 500).round()}|${(p.longitude * 500).round()}';
}

final _converted = Expando<Object>('place');

/// 要素から作った場所。どのカテゴリにも当てはまらない要素は false を覚えておく。
Object _placeOf(Map<String, dynamic> element) => _converted[element] ??= Place.fromOsm(element) ?? false;

// カテゴリの判定（tool/build_data.py の classify と同じ規則）
final _highSchoolName = RegExp(r'高等学校|高校|中等教育学校|high school', caseSensitive: false);
final _vocationalName = RegExp(r'専門学校|専修学校|職業能力開発|ポリテクセンター|ポリテクカレッジ|職業訓練');
final _correspondenceName = RegExp(
    r'通信制|通信教育|放送大学|(?<!電気)通信大学|サイバー大学|八洲学園大学|星槎大学|サポート校|^(?!.*大学).*高等学院|'
    r'クラーク記念国際|第一学院|ルネサンス(?:大阪|豊田)?高等学校|鹿島学園|鹿島朝日|鹿島山北|ヒューマンキャンパス|'
    r'飛鳥未来|おおぞら高|トライ式|ID学園|星槎国際|明蓬館|NHK学園|ＮＨＫ学園|精華学園高等学校|勇志国際|'
    r'さくら国際|代々木高等学校|あずさ第一|科学技術学園|ワオ高等学校|つくば開成|わせがく|翔洋学園|'
    r'日本ウェルネス高等学校|向陽台高等学校|望星高等学校|(?<![A-Za-z])[NSR]高(?:等学校)?(?![A-Za-z0-9])');
final _notSchool = RegExp(r'警察学校|消防学校|研修所|特別支援|教習所|自動車学校|協会');
// amenity=college が付いていることがある学習塾・習い事
final _cram = RegExp(r'塾|ゼミナール|教室|個別指導|予備校|進学|学習支援|英会話|ピアノ|書道|そろばん');
// 校舎・設備など、学校そのものではない建物
final _schoolPart = RegExp(r'号館|棟|グラウンド|グランド|運動場|駐車場|駐輪場|寮|図書|体育館|AED|交番|センター前');
const _eduAmenities = {'school', 'college', 'university', 'training', 'prep_school', 'language_school', 'music_school'};
final _volunteerName = RegExp(r'ボランティア|社会福祉協議会|市民活動|NPOセンター|volunteer', caseSensitive: false);
final _experienceName = RegExp(r'体験|ワークショップ|workshop|陶芸', caseSensitive: false);
const _experienceCrafts = {'pottery', 'glassblower'};
// 史跡・名所: 城跡・遺跡・古墳・歴史的建造物など（記念碑・祠・道標などは Wikidata にあるものだけ）、文化財、
// Wikidata にある寺社・観光地
const _historicValues = {
  'castle', 'ruins', 'archaeological_site', 'fort', 'monument', 'manor', 'building', 'battlefield', 'city_gate', //
  'tomb', 'heritage', 'house', 'temple', 'church', 'place_of_worship', 'shrine', 'palace', 'castle_wall',
  'citywalls', 'aqueduct', 'bridge', 'district',
};
// 会社: 本社・本店の名前の事務所や建物と、支店・営業所などではない会社の事務所
final _headOffice = RegExp(r'本社|本店');
final _branch = RegExp(r'営業所|支店|支社|出張所|事業所|配送センター|物流センター|倉庫|工場');
const _foodAmenities = {'restaurant', 'cafe', 'fast_food', 'bar', 'pub', 'food_court', 'ice_cream', 'biergarten'};
const _foodShops = {'bakery', 'pastry', 'confectionery'};
const _beautyShops = {'hairdresser', 'beauty'};

Set<PlaceCategory> classify(Map<String, dynamic> tags, String name) {
  final amenity = tags['amenity'];
  final shop = tags['shop'];
  final isced = (tags['isced:level'] as String? ?? '').split(RegExp('[;,]')).map((s) => s.trim());
  // 学校の施設か、施設の種類が付いていない学校名の建物
  final schoolLike = (_eduAmenities.contains(amenity) ||
          tags['office'] == 'educational_institution' ||
          (tags.containsKey('building') &&
              !const ['amenity', 'shop', 'office', 'leisure', 'tourism'].any(tags.containsKey) &&
              !_schoolPart.hasMatch(name))) &&
      !_notSchool.hasMatch(name);
  final correspondence = schoolLike && _correspondenceName.hasMatch(name);
  return {
    if (amenity == 'school' && (_highSchoolName.hasMatch(name) || isced.contains('3')))
      PlaceCategory.highSchool,
    if (schoolLike &&
        !correspondence &&
        !_cram.hasMatch(name) &&
        (_vocationalName.hasMatch(name) ||
            (amenity == 'college' && !name.contains('大学') && !_highSchoolName.hasMatch(name))))
      PlaceCategory.vocational,
    if (amenity == 'university' || (amenity == 'college' && name.contains('大学')))
      PlaceCategory.university,
    if (correspondence) PlaceCategory.correspondence,
    if (_volunteerName.hasMatch(name)) PlaceCategory.volunteer,
    if (_experienceName.hasMatch(name) || _experienceCrafts.contains(tags['craft']))
      PlaceCategory.experience,
    if (_foodAmenities.contains(amenity) || _foodShops.contains(shop)) PlaceCategory.restaurant,
    if (_beautyShops.contains(shop) && !name.contains('メンズエステ')) PlaceCategory.beauty,
    if (_isHistoric(tags)) PlaceCategory.historic,
    if ((tags['office'] == 'company' && !_branch.hasMatch(name)) ||
        (_headOffice.hasMatch(name) &&
            (tags.containsKey('office') || (tags.containsKey('building') && amenity == null && shop == null))))
      PlaceCategory.company,
  };
}

bool _isHistoric(Map<String, dynamic> tags) {
  final historic = tags['historic'];
  final wikidata = tags.containsKey('wikidata');
  return _historicValues.contains(historic) ||
      (historic != null && wikidata) ||
      tags.containsKey('heritage') ||
      (wikidata && (tags['amenity'] == 'place_of_worship' || tags['tourism'] == 'attraction'));
}

final _menName = RegExp(r"(?<!wo)men'?s|(?<!ウィ)メンズ|男性専用|男性限定|バーバー|barber|理容|床屋", caseSensitive: false);
final _womenName = RegExp(r"レディース|レディス|ladies|lady's|ウィメンズ|women'?s|女性専用|女性限定|女子", caseSensitive: false);

/// 誰向けのお店・学校か（[Audience]）。
Audience audienceOf(Map<String, dynamic> tags, String name) {
  bool yes(String key) => tags[key] == 'yes' || tags[key] == 'only';
  final clothes = (tags['clothes'] as String? ?? '').split(';');
  final men = yes('male') || tags['hairdresser'] == 'barber' || clothes.contains('men') || _menName.hasMatch(name);
  final women = yes('female') || clothes.contains('women') || _womenName.hasMatch(name);
  if (tags['unisex'] == 'yes' || (men && women)) return Audience.unisex;
  if (women) return Audience.women;
  if (men) return Audience.men;
  return Audience.none;
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
  'pastry': 'ケーキ屋',
  'food_court': 'フードコート',
  'biergarten': 'ビアガーデン',
  'training': '研修・訓練施設',
  'prep_school': '予備校',
  'language_school': '語学学校',
  'music_school': '音楽教室',
  'company': '会社',
};

const _historicLabels = {
  'castle': '城・城跡',
  'ruins': '史跡',
  'archaeological_site': '遺跡・古墳',
  'fort': '砦・台場',
  'monument': '記念碑',
  'memorial': '記念碑',
  'manor': '屋敷',
  'building': '歴史的建造物',
  'house': '歴史的建造物',
  'battlefield': '古戦場',
  'city_gate': '門',
  'tomb': '墓所・古墳',
  'wayside_shrine': '祠・地蔵',
  'heritage': '文化財',
  'castle_wall': '城壁',
  'bridge': '歴史的な橋',
};

const _religionLabels = {'shinto': '神社', 'buddhist': '寺院', 'christian': '教会'};

/// 飲食店の `cuisine` の表示名。
const _cuisineLabels = {
  'japanese': '和食',
  'ramen': 'ラーメン',
  'sushi': '寿司',
  'udon': 'うどん',
  'soba': 'そば',
  'noodle': '麺類',
  'curry': 'カレー',
  'chinese': '中華',
  'italian': 'イタリアン',
  'french': 'フレンチ',
  'korean': '韓国料理',
  'indian': 'インド料理',
  'thai': 'タイ料理',
  'vietnamese': 'ベトナム料理',
  'yakiniku': '焼肉',
  'yakitori': '焼き鳥',
  'izakaya': '居酒屋',
  'burger': 'ハンバーガー',
  'pizza': 'ピザ',
  'coffee_shop': 'カフェ',
  'cake': 'ケーキ',
  'donut': 'ドーナツ',
  'crepe': 'クレープ',
  'okonomiyaki': 'お好み焼き',
  'takoyaki': 'たこ焼き',
  'tonkatsu': 'とんかつ',
  'tempura': '天ぷら',
  'beef_bowl': '牛丼',
  'gyudon': '牛丼',
  'seafood': '海鮮',
  'steak_house': 'ステーキ',
  'western': '洋食',
  'sandwich': 'サンドイッチ',
  'chicken': 'チキン',
  'fried_chicken': 'からあげ',
  'bento': '弁当',
  'tea': 'お茶',
  'ice_cream': 'アイスクリーム',
  'kebab': 'ケバブ',
  'american': 'アメリカ料理',
  'spanish': 'スペイン料理',
  'regional': '郷土料理',
  'asian': 'アジア料理',
};

String? _kindOf(Map<String, dynamic> tags, Set<PlaceCategory> categories) {
  if (categories.contains(PlaceCategory.correspondence)) {
    if (categories.contains(PlaceCategory.highSchool)) return '通信制高校';
    if (categories.contains(PlaceCategory.university)) return '通信制大学';
    return '通信制の学校';
  }
  if (categories.contains(PlaceCategory.highSchool)) return '高等学校';
  if (categories.contains(PlaceCategory.vocational)) {
    return (tags['name'] as String? ?? '').contains('高等専門学校') ? '高等専門学校' : '専門学校';
  }
  if (categories.contains(PlaceCategory.restaurant)) {
    final cuisine = (tags['cuisine'] as String? ?? '').split(';').first.trim();
    if (_cuisineLabels[cuisine] case final label?) return label;
  }
  if (categories.contains(PlaceCategory.historic)) {
    if (_historicLabels[tags['historic']] case final label?) return label;
    if (tags['amenity'] == 'place_of_worship') return _religionLabels[tags['religion']] ?? '寺社・教会';
    if (tags.containsKey('heritage') && !tags.containsKey('amenity') && !tags.containsKey('tourism')) return '文化財';
  }
  if (tags['shop'] == 'hairdresser' &&
      (tags['hairdresser'] == 'barber' || RegExp('理容|床屋|バーバー').hasMatch(tags['name'] as String? ?? ''))) {
    return '理容室';
  }
  if (categories.contains(PlaceCategory.company) && _headOffice.hasMatch(tags['name'] as String? ?? '')) {
    return '本社';
  }
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
