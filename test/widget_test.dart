import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:nearby_insta/models/listing.dart';
import 'package:nearby_insta/models/place.dart';
import 'package:nearby_insta/services/overpass_service.dart';

Map<String, dynamic> _node(int id, Map<String, String> tags) =>
    {'type': 'node', 'id': id, 'lat': 35.0, 'lon': 139.0, 'tags': tags};

void main() {
  group('parseInstagram', () {
    test('ユーザー名のみ', () {
      final link = parseInstagram('hobgoblinshibuya')!;
      expect(link.username, 'hobgoblinshibuya');
      expect(link.url, 'https://www.instagram.com/hobgoblinshibuya/');
    });

    test('@付き', () {
      expect(parseInstagram('@tasuichi.shibuya')!.username, 'tasuichi.shibuya');
    });

    test('プロフィール URL（クエリ・末尾スラッシュ付き）', () {
      expect(parseInstagram('https://www.instagram.com/mepicabari/?hl=ja')!.username, 'mepicabari');
      expect(parseInstagram('instagram.com/the_bellwood')!.username, 'the_bellwood');
    });

    test('複数値ではユーザー名を優先', () {
      final link = parseInstagram('bar_trench;https://instagram.com/explore/locations/2432706/bar-trench')!;
      expect(link.username, 'bar_trench');
    });

    test('場所ページの URL しかない場合は URL のみ', () {
      const url = 'https://instagram.com/explore/locations/149995422254132/takenoko';
      final link = parseInstagram(url)!;
      expect(link.username, isNull);
      expect(link.url, url);
    });

    test('Instagram と無関係な値は無視', () {
      expect(parseInstagram('https://example.com/foo'), isNull);
    });
  });

  group('Place.fromOsm のカテゴリ判定', () {
    test('Instagram 付きのカフェ（way は center 座標を使う）', () {
      final place = Place.fromOsm({
        'type': 'way',
        'id': 42,
        'center': {'lat': 35.5, 'lon': 139.5},
        'tags': {'name': 'テスト店', 'amenity': 'cafe', 'contact:instagram': 'test_cafe'},
      })!;
      expect(place.id, 'way/42');
      expect(place.position.latitude, 35.5);
      expect(place.categories, {PlaceCategory.instagram});
      expect(place.kind, 'カフェ');
      expect(place.instagram!.handle, '@test_cafe');
    });

    test('高校は名前か isced:level で判定し、小中学校は除く', () {
      expect(Place.fromOsm(_node(1, {'amenity': 'school', 'name': '神奈川県立テスト高等学校'}))!.categories,
          {PlaceCategory.highSchool});
      expect(Place.fromOsm(_node(2, {'amenity': 'school', 'name': 'Test Academy', 'isced:level': '2;3'}))!
          .categories, {PlaceCategory.highSchool});
      expect(Place.fromOsm(_node(3, {'amenity': 'school', 'name': 'テスト小学校'})), isNull);
      expect(Place.fromOsm(_node(4, {'amenity': 'school', 'name': 'テスト高等専門学校'})), isNull);
    });

    test('大学（短期大学を含み、専門学校は除く）', () {
      expect(Place.fromOsm(_node(1, {'amenity': 'university', 'name': 'テスト大学'}))!.categories,
          {PlaceCategory.university});
      expect(Place.fromOsm(_node(2, {'amenity': 'college', 'name': 'テスト短期大学'}))!.categories,
          {PlaceCategory.university});
      expect(Place.fromOsm(_node(3, {'amenity': 'college', 'name': 'テスト専門学校'})), isNull);
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
      expect(place.categories, {PlaceCategory.university, PlaceCategory.instagram});
      expect(place.primaryCategory(PlaceCategory.values.toSet()), PlaceCategory.university);
      expect(place.primaryCategory({PlaceCategory.instagram}), PlaceCategory.instagram);
    });
  });

  test('Overpass の結果から同じ施設の重複を除く', () {
    final places = OverpassService.parse({
      'elements': [
        _node(1, {'amenity': 'university', 'name': 'テスト大学'}),
        {'type': 'way', 'id': 2, 'center': {'lat': 35.0, 'lon': 139.0}, 'tags': {'amenity': 'university', 'name': 'テスト大学'}},
        _node(3, {'amenity': 'cafe'}),
      ],
    });
    expect(places.map((p) => p.id), ['node/1']);
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
