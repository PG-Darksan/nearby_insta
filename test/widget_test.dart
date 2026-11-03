import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:nearby_insta/controllers/nearby_controller.dart';
import 'package:nearby_insta/models/listing.dart';
import 'package:nearby_insta/models/place.dart';
import 'package:nearby_insta/screens/sns_browser.dart';
import 'package:nearby_insta/services/event_service.dart';
import 'package:nearby_insta/services/geocoding_service.dart';
import 'package:nearby_insta/services/hidden_places_store.dart';
import 'package:nearby_insta/services/listing_store.dart';
import 'package:nearby_insta/services/overpass_service.dart';
import 'package:nearby_insta/services/place_repository.dart';
import 'package:nearby_insta/services/search_history.dart';
import 'package:nearby_insta/services/sns_finder.dart';
import 'package:nearby_insta/services/spot_data_service.dart';
import 'package:nearby_insta/widgets/place_widgets.dart';
import 'package:nearby_insta/widgets/search_filters.dart';

Map<String, dynamic> _node(int id, Map<String, String> tags) =>
    {'type': 'node', 'id': id, 'lat': 35.0, 'lon': 139.0, 'tags': tags};

List<String> _ids(Iterable<SocialLink> links) => [for (final l in links) '${l.platform.name}:${l.id}'];

class _FakePlaceRepository extends PlaceRepository {
  _FakePlaceRepository(this.elements);

  final List<Map<String, dynamic>> elements;

  @override
  Future<void> load(
    LatLng center,
    int radiusMeters, {
    bool refresh = false,
    required void Function(List<Map<String, dynamic>> elements, {required bool complete}) onElements,
    void Function(String)? onStatus,
  }) async {
    onElements(elements, complete: true);
  }
}

class _FakeEventService extends EventService {
  _FakeEventService(this.places);

  final List<Place> places;

  @override
  List<Place> cachedAround(LatLng center, int radiusMeters) => const [];

  @override
  Future<List<Place>> load(
    LatLng center,
    int radiusMeters, {
    String? localArea,
    bool refresh = false,
    bool Function()? isCancelled,
  }) async => places;
}

class _FakeHiddenStore extends HiddenPlacesStore {
  Map<String, String> saved = {};

  @override
  Future<Map<String, String>> load() async => {...saved};

  @override
  Future<void> save(Map<String, String> items) async {
    saved = {...items};
  }
}

class _FakeListingStore extends ListingStore {
  List<UserListing> saved = [];

  @override
  Future<List<UserListing>> load() async => [...saved];

  @override
  Future<void> save(List<UserListing> listings) async {
    saved = [...listings];
  }
}

class _FakeHistoryStore extends SearchHistoryStore {
  List<SearchPoint> saved = [];

  @override
  Future<List<SearchPoint>> load() async => [...saved];

  @override
  Future<void> save(List<SearchPoint> points) async {
    saved = [...points];
  }
}

class _NoopGeocoding extends GeocodingService {
  @override
  Future<String?> placeName(LatLng p) async => '六浦';
}

class _NoopSnsFinder extends SnsFinder {
  @override
  Future<void> warmUp() async {}

  @override
  Future<void> find(
    List<Place> places, {
    required void Function(String placeId, List<SocialLink> links) onFound,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {}
}

void main() {
  group('OSM タグの SNS アカウント', () {
    test('ユーザー名・@付き・プロフィール URL', () {
      expect(_ids(parseSnsTag(SnsPlatform.instagram, 'hobgoblinshibuya')), ['instagram:hobgoblinshibuya']);
      expect(_ids(parseSnsTag(SnsPlatform.instagram, '@tasuichi.shibuya')), ['instagram:tasuichi.shibuya']);
      expect(_ids(parseSnsTag(SnsPlatform.instagram, 'https://www.instagram.com/mepicabari/?hl=ja')),
          ['instagram:mepicabari']);
      expect(_ids(parseSnsTag(SnsPlatform.instagram, 'instagram.com/the_bellwood')), ['instagram:the_bellwood']);
    });

    test('複数値と場所ページ', () {
      expect(
        _ids(parseSnsTag(SnsPlatform.instagram, 'bar_trench;https://instagram.com/explore/locations/2432706/bar-trench')),
        ['instagram:bar_trench', 'instagram:https://www.instagram.com/explore/locations/2432706/bar-trench/'],
      );
      final location = parseSnsUrl('https://instagram.com/explore/locations/149995422254132/takenoko')!;
      expect(location.handle, 'Instagram の場所ページ');
      expect(location.username, isNull);
    });

    test('X・Facebook・TikTok・YouTube・LINE・Threads', () {
      final links = socialFromTags({
        'contact:twitter': 'https://twitter.com/#!/oldname',
        'contact:facebook': 'https://www.facebook.com/profile.php?id=1234&ref=x',
        'contact:tiktok': '@cafe.abc',
        'contact:youtube': 'UCabcdefghijklmnopqrstuv',
        'contact:line': '@shop1',
        'contact:threads': 'cafe_abc',
        'website': 'https://www.instagram.com/cafe_web/',
      });
      expect(_ids(links), [
        'x:oldname',
        'facebook:https://www.facebook.com/profile.php?id=1234',
        'tiktok:cafe.abc',
        'youtube:channel/UCabcdefghijklmnopqrstuv',
        'line:@shop1',
        'threads:cafe_abc',
        'instagram:cafe_web',
      ]);
      expect(links.map((l) => l.url), contains('https://line.me/R/ti/p/%40shop1'));
      expect(links.firstWhere((l) => l.platform == SnsPlatform.tiktok).url, 'https://www.tiktok.com/@cafe.abc');
    });

    test('SNS と無関係な値や共有ボタンは無視', () {
      expect(parseSnsTag(SnsPlatform.instagram, 'https://example.com/foo'), isEmpty);
      expect(parseSnsUrl('https://twitter.com/share?url=x'), isNull);
      expect(parseSnsUrl('https://graph.facebook.com/v25.0/x'), isNull);
      expect(parseSnsUrl('https://www.youtube.com/watch?v=1'), isNull);
      expect(parseSnsUrl('https://www.fedex.com/abc'), isNull);
    });
  });

  test('公式サイトの HTML から SNS のプロフィールだけを抜き出す', () {
    const html = r'''
      <a href="https://www.instagram.com/test_school_official/">Instagram</a>
      <a href="https://instagram.com/test_school_official">dup</a>
      <a href="https://www.instagram.com/p/AbC123/">post</a>
      <script src="//www.instagram.com/embed.js"></script>
      <a href="https://www.instagram.com/test_club.basketball?igsh=xyz">club</a>
      <a href="https://twitter.com/share?url=x">share</a><a href="https://x.com/cafe_abc">x</a>
      <iframe src="https://www.facebook.com/plugins/page.php?href=https%3A%2F%2Fwww.facebook.com%2Fcafeabc.page&tabs=timeline"></iframe>
      <a href="https://line.me/R/ti/p/%40abc123">line</a> <script>var u = "https:\/\/www.tiktok.com\/@cafe.abc";</script>
    ''';
    expect(_ids(socialFromHtml(html)), [
      'instagram:test_school_official',
      'instagram:test_club.basketball',
      'x:cafe_abc',
      'facebook:cafeabc.page',
      'line:@abc123',
      'tiktok:cafe.abc',
    ]);
  });

  group('Place.fromOsm のカテゴリ判定', () {
    test('SNS 付きのカフェ（way は center 座標を使う）', () {
      final place = Place.fromOsm({
        'type': 'way',
        'id': 42,
        'center': {'lat': 35.5, 'lon': 139.5},
        'tags': {'name': 'テスト店', 'amenity': 'cafe', 'contact:instagram': 'test_cafe', 'contact:twitter': 'test_x'},
      })!;
      expect(place.id, 'way/42');
      expect(place.position.latitude, 35.5);
      expect(place.categories, {PlaceCategory.restaurant, PlaceCategory.sns});
      // アカウントのあるお店は SNS のアイコンで表示する
      expect(place.primaryCategory(PlaceCategory.values.toSet()), PlaceCategory.sns);
      expect(place.isInstitution, isFalse);
      expect(place.kind, 'カフェ');
      expect(place.primaryLink()!.handle, '@test_cafe');
      expect(place.primaryLink({SnsPlatform.x})!.handle, '@test_x');
      expect(place.precomputed, isFalse);
    });

    test('配信データの要素は sns をそのまま使い、確認済みとして扱う', () {
      final place = Place.fromOsm({
        'type': 'node',
        'id': 1,
        'lat': 35.0,
        'lon': 139.0,
        'tags': {'name': 'テスト高等学校', 'amenity': 'school'},
        'sns': [
          ['instagram', 'test_hs', 'website'],
          ['x', 'test_hs_x', 'wikidata'],
          ['unknown', 'zzz', 'osm'],
        ],
      })!;
      expect(place.precomputed, isTrue);
      expect(place.categories, {PlaceCategory.highSchool, PlaceCategory.sns});
      expect(_ids(place.links), ['instagram:test_hs', 'x:test_hs_x']);
      expect(place.links.first.source, SnsSource.website);
      expect(Place.fromOsm({..._node(2, {'name': 'テスト高等学校', 'amenity': 'school'}), 'sns': []})!.precomputed,
          isTrue);
    });

    test('高校は名前か isced:level で判定し、小中学校は除く', () {
      expect(Place.fromOsm(_node(1, {'amenity': 'school', 'name': '神奈川県立テスト高等学校'}))!.categories,
          {PlaceCategory.highSchool});
      expect(Place.fromOsm(_node(2, {'amenity': 'school', 'name': 'Test Academy', 'isced:level': '2;3'}))!
          .categories, {PlaceCategory.highSchool});
      expect(Place.fromOsm(_node(3, {'amenity': 'school', 'name': 'テスト小学校'})), isNull);
      expect(Place.fromOsm(_node(4, {'amenity': 'school', 'name': 'テスト高等専門学校'}))!.categories,
          {PlaceCategory.vocational});
    });

    test('大学（短期大学を含み、専門学校は除く）', () {
      expect(Place.fromOsm(_node(1, {'amenity': 'university', 'name': 'テスト大学'}))!.categories,
          {PlaceCategory.university});
      expect(Place.fromOsm(_node(2, {'amenity': 'college', 'name': 'テスト短期大学'}))!.categories,
          {PlaceCategory.university});
      expect(Place.fromOsm(_node(3, {'amenity': 'college', 'name': 'テスト専門学校'}))!.categories,
          {PlaceCategory.vocational});
    });

    // tool/test_sns.py の CLASSIFY_CASES と同じ例
    test('専門学校・通信制・飲食店・美容室（tool/build_data.py と同じ判定）', () {
      const cases = <(Map<String, String>, String, Set<String>)>[
        ({'amenity': 'college'}, '日本電子専門学校', {'vocational'}),
        ({'amenity': 'college'}, '日本デザイナー学院', {'vocational'}),
        ({'amenity': 'school'}, '東京都立産業技術高等専門学校', {'vocational'}),
        ({'amenity': 'college'}, '武蔵野短期大学', {'university'}),
        ({'amenity': 'college'}, '千葉県警察学校', {}),
        ({'building': 'yes'}, '日本電子専門学校 7号館', {}),
        ({'amenity': 'kindergarten'}, '越谷保育専門学校附属幼稚園', {}),
        ({'amenity': 'university'}, '放送大学東京多摩学習センター', {'university', 'correspondence'}),
        ({'building': 'yes'}, '放送大学学園放送大学埼玉学習センター', {'correspondence'}),
        ({'amenity': 'university'}, '電気通信大学', {'university'}),
        ({'amenity': 'school'}, 'クラーク記念国際高等学校 さいたまキャンパス', {'highSchool', 'correspondence'}),
        ({'amenity': 'school'}, 'N高等学校', {'highSchool', 'correspondence'}),
        ({'amenity': 'college'}, 'KTCおおぞら高等学院厚木キャンパス', {'correspondence'}),
        ({'amenity': 'college'}, 'ゼロ高等学院', {'correspondence'}),
        ({'amenity': 'school'}, '私立早稲田大学本庄高等学院', {}),
        ({'amenity': 'college'}, '湘南ゼミナール', {}),
        ({'amenity': 'college'}, '君津商業高等学校', {}),
        ({'amenity': 'school'}, '早稲田大学高等学院', {}),
        ({'amenity': 'community_centre'}, '渋谷学習センター', {}),
        ({'amenity': 'restaurant', 'cuisine': 'ramen'}, '麺屋はるか', {'restaurant'}),
        ({'amenity': 'cafe'}, 'カフェ・ド・ポン', {'restaurant'}),
        ({'shop': 'bakery'}, 'ベーカリー麦', {'restaurant'}),
        ({'shop': 'hairdresser'}, 'HAIR SALON A', {'beauty'}),
        ({'shop': 'beauty'}, 'ネイルサロン B', {'beauty'}),
        ({'shop': 'beauty'}, 'メンズエステ C', {}),
        ({'amenity': 'school', 'isced:level': '3'}, '県立第一', {'highSchool'}),
        ({'amenity': 'social_facility'}, '市ボランティアセンター', {}),
        ({'historic': 'castle'}, '佐倉城', {'historic'}),
        ({'historic': 'archaeological_site'}, '明戸古墳', {'historic'}),
        ({'historic': 'memorial'}, '忠霊塔', {}),
        ({'historic': 'memorial', 'wikidata': 'Q1'}, '二・二六事件慰霊像', {'historic'}),
        ({'amenity': 'place_of_worship', 'wikidata': 'Q2'}, '浅草寺', {'historic'}),
        ({'amenity': 'place_of_worship'}, '神明社', {}),
        ({'heritage': '2', 'man_made': 'bridge'}, '一石橋', {'historic'}),
        ({'office': 'company'}, '株式会社テスト', {'company'}),
        ({'office': 'company'}, '佐川急便 千葉南営業所', {}),
        ({'building': 'yes'}, 'ホーチキ本社', {'company'}),
        ({'amenity': 'restaurant'}, 'ラーメン山田 本店', {'restaurant'}),
      ];
      for (final (tags, name, expected) in cases) {
        expect(classify(tags, name).map((c) => c.name).toSet(), expected, reason: name);
      }
      final ramen = Place.fromOsm(_node(1, {'amenity': 'restaurant', 'cuisine': 'ramen;japanese', 'name': '麺屋'}))!;
      expect(ramen.kind, 'ラーメン');
      final n = Place.fromOsm(_node(2, {'amenity': 'school', 'name': 'N高等学校'}))!;
      expect(n.kind, '通信制高校');
      expect(n.isInstitution, isTrue);
    });

    test('体験施設は名前・タグで判定し、行政のボランティア施設や道路はボランティアに含めない', () {
      // ボランティアは施設の場所ではなく開催地を表示するため、OSM の社会福祉協議会・ボランティアセンターは除外
      expect(Place.fromOsm(_node(1, {'office': 'association', 'name': 'テスト市社会福祉協議会'})), isNull);
      expect(
        Place.fromOsm(
            _node(5, {'office': 'association', 'name': 'テスト市社会福祉協議会', 'contact:instagram': 'shakyo_test'}))!
            .categories,
        {PlaceCategory.sns},
      );
      expect(Place.fromOsm(_node(2, {'tourism': 'attraction', 'name': '陶芸体験工房'}))!.categories,
          {PlaceCategory.experience});
      expect(Place.fromOsm(_node(3, {'craft': 'pottery', 'name': 'テスト窯'}))!.categories,
          {PlaceCategory.experience});
      expect(Place.fromOsm(_node(4, {'highway': 'residential', 'name': 'ボランティア通り'})), isNull);
    });

    test('複数カテゴリに当てはまる場合は表示中の優先カテゴリで色を決める', () {
      final place = Place.fromOsm(
          _node(1, {'amenity': 'university', 'name': 'テスト大学', 'contact:instagram': 'test_univ'}))!;
      expect(place.categories, {PlaceCategory.university, PlaceCategory.sns});
      expect(place.primaryCategory(PlaceCategory.values.toSet()), PlaceCategory.university);
      expect(place.primaryCategory({PlaceCategory.sns}), PlaceCategory.sns);
    });
  });

  test('同じ施設の重複を除く', () {
    final places = placesFromOsm([
      _node(1, {'amenity': 'university', 'name': 'テスト大学'}),
      {'type': 'way', 'id': 2, 'center': {'lat': 35.0, 'lon': 139.0}, 'tags': {'amenity': 'university', 'name': 'テスト大学'}},
      _node(3, {'amenity': 'cafe'}),
    ]);
    expect(places.map((p) => p.id), ['node/1']);
  });

  test('アプリで見つけたアカウントを追加するとカテゴリにも反映され、重複は除く', () {
    final place = Place.fromOsm(_node(1, {'amenity': 'school', 'name': 'テスト高等学校'}))!;
    expect(place.categories, {PlaceCategory.highSchool});
    expect(place.isInstitution, isTrue);
    place.addLinks([
      const SocialLink(SnsPlatform.instagram, 'test_hs', SnsSource.website),
      const SocialLink(SnsPlatform.instagram, 'TEST_HS', SnsSource.wikidata),
      const SocialLink(SnsPlatform.x, 'test_hs', SnsSource.website),
    ]);
    expect(_ids(place.links), ['instagram:test_hs', 'x:test_hs']);
    expect(place.categories, {PlaceCategory.highSchool, PlaceCategory.sns});
  });

  test('チェーン店は支店名か近くの地名を付けて表示し、別の店舗はまとめない', () {
    expect(Place.displayName('スシロー', branch: '金沢八景店'), 'スシロー 金沢八景店');
    expect(Place.displayName('スシロー', area: '六浦'), 'スシロー（六浦）');
    expect(Place.displayName('スシロー金沢八景店', branch: '金沢八景店'), 'スシロー金沢八景店');
    expect(Place.displayName('六浦郵便局', area: '六浦'), '六浦郵便局');
    final places = placesFromOsm([
      {..._node(1, {'amenity': 'restaurant', 'name': 'スシロー'}), 'area': '六浦'},
      {..._node(2, {'amenity': 'restaurant', 'name': 'スシロー'}), 'lat': 35.1, 'area': '六浦'},
      {..._node(3, {'amenity': 'restaurant', 'name': 'スシロー', 'branch': '金沢八景店'}), 'lat': 35.2},
    ]);
    expect(places.map((p) => p.name), ['スシロー（六浦）', 'スシロー（六浦）', 'スシロー 金沢八景店']);
    expect(places.first.searchQuery, 'スシロー 六浦');
  });

  test('誰向けのお店・学校か（タグと名前で判定）', () {
    expect(audienceOf({'shop': 'hairdresser', 'female': 'yes'}, 'Salon A'), Audience.women);
    expect(audienceOf({'shop': 'hairdresser', 'male': 'yes', 'female': 'yes'}, 'Salon B'), Audience.unisex);
    expect(audienceOf({'shop': 'hairdresser', 'unisex': 'yes'}, 'Salon C'), Audience.unisex);
    expect(audienceOf({'shop': 'hairdresser', 'hairdresser': 'barber'}, 'Fit'), Audience.men);
    expect(audienceOf({'shop': 'hairdresser'}, '理容キング'), Audience.men);
    expect(audienceOf({'shop': 'clothes'}, "WOMEN'S SHOP"), Audience.women);
    expect(audienceOf({'shop': 'clothes'}, "Men's Shop マルキヤ"), Audience.men);
    expect(audienceOf({'shop': 'clothes'}, 'ウィメンズ館'), Audience.women);
    expect(audienceOf({'amenity': 'university'}, '東京女子体育大学'), Audience.women);
    expect(audienceOf({'amenity': 'restaurant'}, '麺屋'), Audience.none);
    final place = Place.fromOsm(_node(1, {'shop': 'hairdresser', 'name': 'Hair Ladies'}))!;
    expect(place.audience, Audience.women);
    final shrine = Place.fromOsm(_node(2, {'amenity': 'place_of_worship', 'religion': 'shinto', 'wikidata': 'Q3', 'name': '烏森神社'}))!;
    expect(shrine.categories, {PlaceCategory.historic});
    expect(shrine.kind, '神社');
    expect(Place.fromOsm(_node(3, {'shop': 'hairdresser', 'name': '理容 ホープ'}))!.kind, '理容室');
  });

  test('タグ付け・メンションされた投稿の URL', () {
    expect(const SocialLink(SnsPlatform.instagram, 'cafe_abc').taggedPosts?.url,
        'https://www.instagram.com/cafe_abc/tagged/');
    expect(const SocialLink(SnsPlatform.x, 'cafe_x').taggedPosts?.url,
        'https://x.com/search?q=%40cafe_x+-from%3Acafe_x&f=live');
    const location = SocialLink(SnsPlatform.instagram, 'https://www.instagram.com/explore/locations/2432706/');
    expect(location.isInstagramLocation, isTrue);
    expect(location.taggedPosts?.url, location.url);
    expect(const SocialLink(SnsPlatform.youtube, '@cafe').taggedPosts, isNull);
  });

  test('SocialLink は保存形式で往復できる', () {
    const link = SocialLink(SnsPlatform.youtube, '@cafe-abc', SnsSource.website);
    final restored = SocialLink.fromJson(link.toJson())!;
    expect(restored, link);
    expect(restored.source, SnsSource.website);
    expect(restored.url, 'https://www.youtube.com/@cafe-abc');
  });

  test('配信データのタイルは中心に近い順に、データのあるものだけ選ぶ', () {
    final meta = SpotMeta(
      generated: '2026-10-31T00:00:00Z',
      tileDeg: 0.1,
      coverage: {'35_139'},
      tiles: {'353_1396', '353_1395', '354_1396', '300_1300'},
    );
    expect(meta.covers(const LatLng(35.33, 139.62)), isTrue);
    expect(meta.covers(const LatLng(35.10, 129.04)), isFalse); // 釜山（範囲外）
    expect(meta.tilesAround(const LatLng(35.33, 139.62), 1000), ['353_1396']);
    expect(meta.tilesAround(const LatLng(35.39, 139.61), 3000), ['353_1396', '353_1395', '354_1396']);
  });

  test('Overpass 用のタイルと問い合わせ（ボランティア施設の問い合わせは含めない）', () {
    final tiles = PlaceRepository.tilesAround(const LatLng(35.658, 139.7016), 1000);
    // 約 2km 四方のタイルなので、半径 1km なら 2〜3 タイル四方
    expect(tiles.length, inInclusiveRange(4, 9));
    final query = OverpassService.buildQuery(const Bounds(35.6, 139.6, 35.7, 139.7));
    expect(query, contains('[bbox:35.600000,139.600000,35.700000,139.700000]'));
    expect(query, contains('nwr["contact:twitter"]'));
    expect(query, contains('nwr["shop"~"^(bakery|pastry|confectionery|hairdresser|beauty)\$"]["name"]'));
    expect(query, isNot(contains('社会福祉協議会')));
  });

  test('UserListing は婚活・合コン・ボランティア・有償体験で JSON 往復できる', () {
    final listing = UserListing(
      id: 'abc',
      category: PlaceCategory.experience,
      title: '陶芸体験',
      position: const LatLng(35.1, 139.2),
      createdAt: DateTime(2026, 10, 30, 12),
      fee: '3,000円',
    );
    final restored = UserListing.fromJson(listing.toJson());
    expect(restored.title, '陶芸体験');
    expect(restored.category, PlaceCategory.experience);
    expect(restored.position, const LatLng(35.1, 139.2));
    expect(restored.fee, '3,000円');
    expect(restored.toPlace().id, 'listing/abc');

    final mixer = UserListing(
      id: 'mix1',
      category: PlaceCategory.matchmaking,
      title: '横浜カフェ合コン',
      position: const LatLng(35.46, 139.62),
      createdAt: DateTime(2026, 11, 3, 19),
      fee: '男性 4,000円 / 女性 1,500円',
    );
    final restoredMixer = UserListing.fromJson(mixer.toJson());
    expect(restoredMixer.category, PlaceCategory.matchmaking);
    expect(restoredMixer.toPlace().kind, '婚活・合コン');
    expect(restoredMixer.toPlace().isGathering, isTrue);

    final vol = UserListing(
      id: 'vol1',
      category: PlaceCategory.volunteer,
      title: '海岸クリーンアップ',
      position: const LatLng(35.33, 139.63),
      createdAt: DateTime(2026, 11, 3, 9),
    );
    expect(vol.toPlace().kind, 'ボランティア募集（開催地）');
  });

  group('公開イベント情報からの婚活・合コン・ボランティア開催地抽出', () {
    final now = DateTime(2026, 11, 3, 10);

    test('こくちーずプロ: 会場座標つきの婚活・ボランティアを抽出し、オンライン・終了済み・ビジネス勧誘は除く', () {
      const html = r'''
      <script type="application/ld+json">
      [
        {
          "@context": "http://schema.org",
          "@type": "Event",
          "name": "横浜駅近・20代30代恋活カフェ合コン",
          "url": "https://www.kokuchpro.com/event/yokohama_goukon/",
          "startDate": "2026-11-15T14:00:00+09:00",
          "endDate": "2026-11-15T16:00:00+09:00",
          "eventAttendanceMode": "https://schema.org/OfflineEventAttendanceMode",
          "location": {
            "@type": "Place",
            "name": "横浜ラウンジスペース",
            "address": "神奈川県神奈川県横浜市西区南幸2-1-1",
            "geo": {"@type": "GeoCoordinates", "latitude": "35.4641", "longitude": "139.6195"}
          },
          "offers": {"@type": "Offer", "price": "2500", "priceCurrency": "JPY"},
          "organizer": {"@type": "Organization", "name": "横浜恋活サークル"}
        },
        {
          "@context": "http://schema.org",
          "@type": "Event",
          "name": "多摩川河川敷ごみ拾いボランティア",
          "url": "https://www.kokuchpro.com/event/tamagawa_clean/",
          "startDate": "2026-11-22T09:30:00+09:00",
          "location": {
            "@type": "Place",
            "name": "丸子橋ピクニック広場",
            "address": "神奈川県川崎市中原区上丸子八幡町",
            "geo": {"@type": "GeoCoordinates", "latitude": 35.5812, "longitude": 139.6684}
          },
          "offers": {"@type": "Offer", "price": "0", "priceCurrency": "JPY"}
        },
        {
          "@context": "http://schema.org",
          "@type": "Event",
          "name": "Zoomオンライン婚活パーティー",
          "url": "https://www.kokuchpro.com/event/online_konkatsu/",
          "startDate": "2026-11-20T20:00:00+09:00",
          "eventAttendanceMode": "https://schema.org/OnlineEventAttendanceMode",
          "location": {"@type": "VirtualLocation", "url": "https://zoom.us/j/1"}
        },
        {
          "@context": "http://schema.org",
          "@type": "Event",
          "name": "起業で年商1000万マーケティング出会い交流会",
          "url": "https://www.kokuchpro.com/event/biz_spam/",
          "startDate": "2026-11-20T19:00:00+09:00",
          "location": {
            "@type": "Place",
            "name": "会議室",
            "address": "東京都渋谷区渋谷1-1-1",
            "geo": {"@type": "GeoCoordinates", "latitude": 35.659, "longitude": 139.702}
          }
        },
        {
          "@context": "http://schema.org",
          "@type": "Event",
          "name": "過去の街コン",
          "url": "https://www.kokuchpro.com/event/past_event/",
          "startDate": "2026-10-01T14:00:00+09:00",
          "endDate": "2026-10-01T16:00:00+09:00",
          "location": {
            "@type": "Place",
            "name": "会場",
            "address": "東京都新宿区新宿3-1-1",
            "geo": {"@type": "GeoCoordinates", "latitude": 35.69, "longitude": 139.70}
          }
        }
      ]
      </script>
      ''';
      final parsed = EventService.parseKokuchproHtml(html, now: now);
      expect(parsed.length, 2);

      final mixer = parsed[0];
      expect(mixer.category, PlaceCategory.matchmaking);
      expect(mixer.venue, '横浜ラウンジスペース');
      expect(mixer.address, '神奈川県横浜市西区南幸2-1-1');
      expect(mixer.position, const LatLng(35.4641, 139.6195));
      expect(mixer.fee, '2,500円');
      expect(mixer.organizer, '横浜恋活サークル');

      final vol = parsed[1];
      expect(vol.category, PlaceCategory.volunteer);
      expect(vol.venue, '丸子橋ピクニック広場');
      expect(vol.position, const LatLng(35.5812, 139.6684));
      expect(vol.fee, '無料');
    });

    test('街コンジャパン・オミカレ: 一覧と詳細から開催会場の住所・料金を抽出する', () {
      const machiconList = r'''
      <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "Event",
        "name": "みなとみらい同世代街コン",
        "url": "https://machicon.jp/events/abc123/",
        "startDate": "2026-11-21T18:00:00+09:00",
        "endDate": "2026-11-21T20:00:00+09:00",
        "location": {"@type": "Place", "name": "桜木町・みなとみらい周辺"},
        "offers": [
          {"@type": "Offer", "name": "女性", "price": "1000"},
          {"@type": "Offer", "name": "男性", "price": "5500"}
        ]
      }
      </script>
      ''';
      final list = EventService.parseMachiconListHtml(machiconList, now: now);
      expect(list.length, 1);
      expect(list.first.category, PlaceCategory.matchmaking);
      expect(list.first.coarseArea, '桜木町・みなとみらい周辺');
      expect(list.first.fee, '女性 1,000円 / 男性 5,500円');

      const machiconDetail = r'''
      <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "Event",
        "name": "みなとみらい同世代街コン",
        "location": {
          "@type": "Place",
          "name": "カフェダイニング みなと",
          "address": {
            "@type": "PostalAddress",
            "addressRegion": "神奈川県",
            "addressLocality": "横浜市中区",
            "streetAddress": "桜木町1-1-1"
          }
        }
      }
      </script>
      ''';
      final detail = EventService.parseMachiconDetailHtml(machiconDetail);
      expect(detail.venue, 'カフェダイニング みなと');
      expect(detail.address, '神奈川県 横浜市中区 桜木町1-1-1');

      const omikareDetail = '''
      <dl>
        <dt>会場</dt><dd>パーティーサロン横浜</dd>
        <dt>住所</dt><dd>神奈川県横浜市西区北幸1-2-3</dd>
      </dl>
      ''';
      final omi = EventService.parseOmikareDetailHtml(omikareDetail);
      expect(omi.venue, 'パーティーサロン横浜');
      expect(omi.address, '神奈川県横浜市西区北幸1-2-3');

      expect(prefectures.firstWhere((p) => p.name == '高知県').omikareSlug, 'kouchi');
      expect(prefectures.firstWhere((p) => p.name == '大分県').omikareSlug, 'ooita');
      expect(prefectures.firstWhere((p) => p.name == '新潟県').activoSlug, 'nigata');
    });

    test('activo: 団体の事務所所在地ではなく JobPosting.jobLocation の実際の開催地を取り出す', () {
      const activoList = r'''
      <script>{"request":{"page":1},"response":{"hits":{"hits":[
        {"_source":{
          "id": 99901,
          "is_vol": true,
          "title": "金沢八景・海の公園ビーチクリーン",
          "description": "砂浜の清掃ボランティアです",
          "user": {"name": "NPO法人テスト環境ネット"},
          "_modified_text_for_views": {
            "online_possibility": "offline",
            "display_activity_locations": "神奈川 [横浜市金沢区/海の公園駅 徒歩2分]",
            "dates_or_terms": "2026年11月29日(日)",
            "prices": "無料"
          }
        }},
        {"_source":{
          "id": 99902,
          "is_vol": true,
          "title": "完全在宅オンライン事務ボランティア",
          "_modified_text_for_views": {
            "online_possibility": "online_only",
            "display_activity_locations": "神奈川 [横浜市]"
          }
        }}
      ]}}}</script>
      ''';
      final list = EventService.parseActivoListHtml(activoList, prefShortName: '神奈川');
      expect(list.length, 1);
      expect(list.first.category, PlaceCategory.volunteer);
      expect(list.first.coarseArea, '横浜市金沢区');
      expect(list.first.organizer, 'NPO法人テスト環境ネット');

      const activoDetail = r'''
      <script type="application/ld+json">
      //<![CDATA[
      {
        "@context": "http://schema.org",
        "@type": "JobPosting",
        "title": "金沢八景・海の公園ビーチクリーン",
        "hiringOrganization": {
          "@type": "Organization",
          "name": "NPO法人テスト環境ネット",
          "address": "東京都千代田区霞が関1-1-1（本部事務所）"
        },
        "jobLocation": [
          {
            "@type": "Place",
            "address": {
              "@type": "PostalAddress",
              "addressRegion": "神奈川県",
              "addressLocality": "横浜市金沢区",
              "streetAddress": "海の公園10"
            }
          }
        ]
      }
      //]]>
      </script>
      ''';
      final detail = EventService.parseActivoDetailHtml(activoDetail);
      expect(detail.address, '神奈川県横浜市金沢区海の公園10');
      expect(detail.venue, '海の公園10');
    });
  });

  test('Instagram 検索の高速切り替え状態管理', () {
    final browser = SnsBrowserController();
    browser.searchInstagram('カフェ 六浦');
    expect(browser.started, isTrue);
    expect(browser.url, SnsBrowserController.searchUrl);
    expect(browser.searchQuery, 'カフェ 六浦');
    expect(browser.searchStatus, InstagramSearchStatus.searching);

    // 別の SNS ページを開いたら検索待ちを解除する
    browser.open('https://x.com/home');
    expect(browser.url, 'https://x.com/home');
    expect(browser.searchStatus, InstagramSearchStatus.none);
  });

  test('個別スポットのチェック非表示とカテゴリ一括切り替えが件数・一覧に反映される', () async {
    final hiddenStore = _FakeHiddenStore();
    final eventPlace = Place(
      id: 'event/mixer1',
      name: '六浦カフェ恋活パーティー',
      position: const LatLng(35.3305, 139.6205),
      categories: {PlaceCategory.matchmaking},
      kind: '恋活イベント',
      address: '神奈川県横浜市金沢区六浦1-1',
      website: 'https://example.com/mixer1',
      event: const EventInfo(source: 'こくちーずプロ', venue: '六浦テラス'),
    );
    final controller = NearbyController(
      repository: _FakePlaceRepository([
        {
          'type': 'node',
          'id': 10,
          'lat': 35.3301,
          'lon': 139.6201,
          'tags': {'name': 'ベーカリー六浦', 'shop': 'bakery'},
          'sns': const [],
        },
        {
          'type': 'node',
          'id': 11,
          'lat': 35.3302,
          'lon': 139.6202,
          'tags': {'name': 'サロン六浦', 'shop': 'hairdresser'},
          'sns': const [],
        },
      ]),
      events: _FakeEventService([eventPlace]),
      hiddenStore: hiddenStore,
      listingStore: _FakeListingStore(),
      historyStore: _FakeHistoryStore(),
      geocoding: _NoopGeocoding(),
      finder: _NoopSnsFinder(),
    );

    await controller.setCenter(const LatLng(35.3300, 139.6200), name: '六浦', radius: 1000);
    expect(controller.visiblePlaces.map((p) => p.name), ['ベーカリー六浦', 'サロン六浦', '六浦カフェ恋活パーティー']);
    expect(controller.countOf(PlaceCategory.restaurant), 1);
    expect(controller.countOf(PlaceCategory.matchmaking), 1);

    // 個別にチェックを付けて非表示にする
    final bakery = controller.visiblePlaces.first;
    await controller.setHidden(bakery, true);
    expect(controller.isHidden(bakery.id), isTrue);
    expect(controller.visiblePlaces.map((p) => p.name), ['サロン六浦', '六浦カフェ恋活パーティー']);
    expect(controller.countOf(PlaceCategory.restaurant), 0);
    expect(controller.hiddenPlacesInRange.map((p) => p.name), ['ベーカリー六浦']);
    expect(hiddenStore.saved, {'node/10': 'ベーカリー六浦'});

    // カテゴリの一括解除・一括選択
    controller.setAllCategories(false);
    expect(controller.visiblePlaces, isEmpty);
    controller.setAllCategories(true);
    expect(controller.visiblePlaces.length, 2);

    // 非表示を解除すると元に戻る
    await controller.unhideById('node/10');
    expect(controller.visiblePlaces.length, 3);
    expect(controller.countOf(PlaceCategory.restaurant), 1);
  });

  testWidgets('地図の上のボタンで検索範囲と表示する種類を変えられる', (tester) async {
    final c = NearbyController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListenableBuilder(listenable: c, builder: (context, _) => MapFilterBar(controller: c))),
    ));
    expect(find.text('範囲 1km'), findsOneWidget);
    await tester.tap(find.text('範囲 1km'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('半径 3km'));
    await tester.pumpAndSettle();
    expect(c.radius, 3000);
    expect(find.text('範囲 3km'), findsOneWidget);

    // 種類のボタンは横にスクロールして選ぶ
    final restaurant = find.textContaining(PlaceCategory.restaurant.label);
    await tester.scrollUntilVisible(restaurant, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(restaurant);
    await tester.pump();
    expect(c.enabled.contains(PlaceCategory.restaurant), isFalse);

    await tester.scrollUntilVisible(find.text('絞り込み'), -200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('絞り込み'));
    await tester.pumpAndSettle();
    expect(find.text('検索範囲'), findsOneWidget);
    expect(find.text('対象'), findsOneWidget);
  });

  testWidgets('一覧のチェックで個別非表示・再表示でき、ワンタップで Instagram 検索を呼べる', (tester) async {
    final c = NearbyController(
      repository: _FakePlaceRepository([
        {
          'type': 'node',
          'id': 20,
          'lat': 35.3301,
          'lon': 139.6201,
          'tags': {'name': 'カフェ六浦', 'amenity': 'cafe'},
          'sns': const [],
        },
      ]),
      events: _FakeEventService(const []),
      hiddenStore: _FakeHiddenStore(),
      listingStore: _FakeListingStore(),
      historyStore: _FakeHistoryStore(),
      geocoding: _NoopGeocoding(),
      finder: _NoopSnsFinder(),
    );
    await c.setCenter(const LatLng(35.3300, 139.6200), name: '六浦', radius: 1000);

    String? searchedQuery;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) => SingleChildScrollView(
            child: Column(
              children: [
                SearchFilters(controller: c),
                for (final p in c.visiblePlaces)
                  SizedBox(
                    height: PlaceTile.height,
                    child: PlaceTile(
                      place: p,
                      category: p.primaryCategory(c.enabled),
                      selected: false,
                      onTap: () {},
                      onOpenLink: (_) {},
                      isHidden: c.isHidden(p.id),
                      onToggleHidden: (hide) => c.setHidden(p, hide),
                      onSearchInstagram: (q) => searchedQuery = q,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ));

    expect(find.text('カフェ六浦'), findsOneWidget);

    // 一覧の Instagram 検索ボタンからワンタップで検索語が渡る
    await tester.tap(find.byIcon(Icons.person_search_outlined));
    await tester.pump();
    expect(searchedQuery, 'カフェ六浦');

    // チェックボックスを押すと非表示になり、「チェックして非表示にした場所（1件）」ボタンが出る
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(find.text('カフェ六浦'), findsNothing);
    expect(find.text('チェックして非表示にした場所（1件）'), findsOneWidget);

    // 非表示一覧シートを開いてチェックを外すと再表示される
    await tester.tap(find.text('チェックして非表示にした場所（1件）'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(find.text('カフェ六浦'), findsOneWidget);
  });
}
