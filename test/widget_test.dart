import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:nearby_insta/models/listing.dart';
import 'package:nearby_insta/models/place.dart';
import 'package:nearby_insta/services/overpass_service.dart';
import 'package:nearby_insta/services/place_repository.dart';
import 'package:nearby_insta/services/spot_data_service.dart';

Map<String, dynamic> _node(int id, Map<String, String> tags) =>
    {'type': 'node', 'id': id, 'lat': 35.0, 'lon': 139.0, 'tags': tags};

List<String> _ids(Iterable<SocialLink> links) => [for (final l in links) '${l.platform.name}:${l.id}'];

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
        ({'amenity': 'social_facility'}, '市ボランティアセンター', {'volunteer'}),
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

    test('ボランティア・体験施設は名前で判定し、道路は除く', () {
      expect(Place.fromOsm(_node(1, {'office': 'association', 'name': 'テスト市社会福祉協議会'}))!.categories,
          {PlaceCategory.volunteer});
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

  test('Overpass 用のタイルと問い合わせ', () {
    final tiles = PlaceRepository.tilesAround(const LatLng(35.658, 139.7016), 1000);
    // 約 2km 四方のタイルなので、半径 1km なら 2〜3 タイル四方
    expect(tiles.length, inInclusiveRange(4, 9));
    final query = OverpassService.buildQuery(const Bounds(35.6, 139.6, 35.7, 139.7));
    expect(query, contains('[bbox:35.600000,139.600000,35.700000,139.700000]'));
    expect(query, contains('nwr["contact:twitter"]'));
    expect(query, contains('nwr["shop"~"^(bakery|pastry|confectionery|hairdresser|beauty)\$"]["name"]'));
  });

  test('UserListing は JSON で往復できる', () {
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
  });
}
