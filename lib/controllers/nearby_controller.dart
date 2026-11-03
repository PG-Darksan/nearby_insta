import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/listing.dart';
import '../models/place.dart';
import '../services/event_service.dart';
import '../services/geocoding_service.dart';
import '../services/hidden_places_store.dart';
import '../services/listing_store.dart';
import '../services/location_service.dart';
import '../services/place_repository.dart';
import '../services/search_history.dart';
import '../services/sns_finder.dart';

/// 検索地点・検索範囲・検索結果・登録した募集情報・非表示設定・検索履歴をまとめて管理する。
class NearbyController extends ChangeNotifier {
  NearbyController({
    LocationService? location,
    PlaceRepository? repository,
    SnsFinder? finder,
    GeocodingService? geocoding,
    ListingStore? listingStore,
    SearchHistoryStore? historyStore,
    HiddenPlacesStore? hiddenStore,
    EventService? events,
  })  : _location = location ?? LocationService(),
        _repository = repository ?? PlaceRepository(),
        _finder = finder ?? SnsFinder(),
        geocoding = geocoding ?? GeocodingService(),
        _listingStore = listingStore ?? ListingStore(),
        _historyStore = historyStore ?? SearchHistoryStore(),
        _hiddenStore = hiddenStore ?? HiddenPlacesStore() {
    _events = events ?? EventService(geocoding: this.geocoding);
  }

  final LocationService _location;
  final PlaceRepository _repository;
  final SnsFinder _finder;
  final GeocodingService geocoding;
  final ListingStore _listingStore;
  final SearchHistoryStore _historyStore;
  final HiddenPlacesStore _hiddenStore;
  late final EventService _events;

  static const radiusOptions = [300, 1000, 3000, 5000, 10000, 20000];
  static const minRadius = 100;
  static const maxRadius = 50000;
  // 飲食店まで含めると数万件になるので、Vincenty より軽い Haversine で距離を求める
  static const _distance = Distance(calculator: Haversine());
  static const _maxHistory = 15;

  LatLng? center;
  LocationSource? source;
  String? locationLabel;

  /// 検索地点の町名（例: 渋谷二丁目）。国外などで分からなければ null。
  String? centerName;
  String? locationNote;
  int radius = 1000;

  final Set<PlaceCategory> enabled = {...PlaceCategory.values};

  /// 「SNS」カテゴリで表示するサービス。
  final Set<SnsPlatform> platforms = {...SnsPlatform.values};

  /// 表示する対象（女性向け・男女兼用など）。
  final Set<Audience> audiences = {...Audience.values};

  /// 個別にチェックを付けて非表示にした場所（ID -> 名前）。
  final Map<String, String> hiddenPlaces = {};

  String filter = '';
  String? selectedId;

  bool locating = false;
  bool searching = false;
  String? error;

  /// 取得中・再試行中などの経過メッセージ。
  String? status;

  /// 公式サイトなどから SNS アカウントを探している間の経過メッセージ。
  String? snsStatus;

  /// 婚活・合コン・ボランティア開催地を取得している間の経過メッセージ。
  String? eventStatus;

  List<UserListing> listings = [];
  List<SearchPoint> history = [];

  List<Place> _osmPlaces = const [];
  List<Place> _eventPlaces = const [];
  List<Place> _inRange = const [];

  /// 古い検索の結果で新しい結果を上書きしないための連番。
  int _searchSeq = 0;

  bool get busy => locating || searching;

  /// 検索範囲内の場所（カテゴリ・キーワード・個別非表示で絞り込む前）。近い順。
  List<Place> get placesInRange => _inRange;

  /// 現在の検索範囲内で、チェックを付けて非表示にしている場所。
  List<Place> get hiddenPlacesInRange => _inRange.where((p) => hiddenPlaces.containsKey(p.id)).toList();

  List<Place> get visiblePlaces => _visible ??= _inRange.where((p) => isShown(p) && p.matches(filter)).toList();

  // 一度の画面の構築で何度も読むので、状態が変わる（notifyListeners）までまとめて覚えておく
  List<Place>? _visible;
  Map<Object, int>? _counts;

  @override
  void notifyListeners() {
    _visible = null;
    _counts = null;
    super.notifyListeners();
  }

  /// カテゴリ・SNS の種類ごとの件数を 1 回の走査で数える（個別非表示の場所は除く）。
  Map<Object, int> get _countMap => _counts ??= () {
        final counts = <Object, int>{};
        void add(Object key) => counts[key] = (counts[key] ?? 0) + 1;
        for (final p in _inRange) {
          if (hiddenPlaces.containsKey(p.id)) continue;
          add(p.audience);
          p.baseCategories.forEach(add);
          final linked = {for (final l in p.links) l.platform};
          linked.forEach(add);
          if (linked.any(platforms.contains)) add(PlaceCategory.sns);
        }
        return counts;
      }();

  /// 個別の非表示チェック、カテゴリ、SNS の種類の表示設定で、地図・一覧に出すか。
  bool isShown(Place p) =>
      !hiddenPlaces.containsKey(p.id) &&
      audiences.contains(p.audience) &&
      (p.baseCategories.any(enabled.contains) || (enabled.contains(PlaceCategory.sns) && p.hasLinkOn(platforms)));

  bool isHidden(String id) => hiddenPlaces.containsKey(id);

  int countOf(PlaceCategory category) => _countMap[category] ?? 0;

  int countOfPlatform(SnsPlatform platform) => _countMap[platform] ?? 0;

  int countOfAudience(Audience audience) => _countMap[audience] ?? 0;

  Place? get selected {
    for (final p in _inRange) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  Future<void> init() async {
    try {
      final results = await Future.wait([
        _listingStore.load(),
        _historyStore.load(),
        _hiddenStore.load(),
      ]);
      listings = results[0] as List<UserListing>;
      history = results[1] as List<SearchPoint>;
      hiddenPlaces
        ..clear()
        ..addAll(results[2] as Map<String, String>);
    } catch (e) {
      debugPrint('保存データの読み込みに失敗: $e');
    }
    await Future.wait([_finder.warmUp(), _repository.warmUp()]);
    _recompute();
    await locate();
  }

  Future<void> locate() async {
    locating = true;
    error = null;
    notifyListeners();
    try {
      final result = await _location.getCurrentLocation();
      _setCenter(result.position, result.source, result.label);
      locationNote = result.note;
    } catch (e) {
      error = _message(e);
    } finally {
      locating = false;
      notifyListeners();
    }
    if (center != null) await search();
  }

  /// 地図や地名検索・履歴で選んだ地点を検索する。[name] が分かっていれば町名の代わりに表示する。
  Future<void> setCenter(LatLng position, {String? name, int? radius}) {
    _setCenter(position, LocationSource.manual, name != null ? '指定した地点' : '地図で指定した地点', name: name);
    if (radius != null) this.radius = radius.clamp(minRadius, maxRadius);
    locationNote = null;
    final bundled = _repository.cachedBundledAround(position, this.radius);
    if (bundled.isNotEmpty) _osmPlaces = placesFromOsm(bundled);
    _eventPlaces = _events.cachedAround(position, this.radius);
    _recompute();
    return search();
  }

  void _setCenter(LatLng position, LocationSource source, String? label, {String? name}) {
    center = position;
    this.source = source;
    locationLabel = label;
    centerName = name;
    if (name == null) {
      geocoding.placeName(position).then((n) {
        if (n == null) return;
        // 先に履歴へ入った座標表記などのラベルも町名に置き換える
        history = [
          for (final h in history) h.position == position ? SearchPoint(h.position, n, h.radius, h.at) : h,
        ];
        if (center == position) centerName = n;
        _historyStore.save(history).catchError((Object e) => debugPrint('履歴の保存に失敗: $e'));
        notifyListeners();
      });
    }
  }

  Future<void> setRadius(int value) {
    radius = value.clamp(minRadius, maxRadius);
    if (center case final at?) {
      final cachedEvents = _events.cachedAround(at, radius);
      if (cachedEvents.isNotEmpty) _eventPlaces = cachedEvents;
    }
    _recompute();
    notifyListeners(); // 現在地を取得中で検索しないときも、選んだ範囲を表示する
    return search();
  }

  /// ユーザーが指定した km 単位の数値（例: 0.5, 2.5, 15）で検索範囲を変更する。
  Future<void> setRadiusKm(double km) => setRadius((km * 1000).round());

  /// 保存済みの範囲はすぐに表示し、足りない範囲だけを取得する。[refresh] なら全て取り直す。
  Future<void> search({bool refresh = false}) async {
    final at = center;
    if (at == null) return;
    final seq = ++_searchSeq;
    searching = true;
    error = null;
    status = null;
    snsStatus = null;
    if (!refresh) {
      final cachedEvents = _events.cachedAround(at, radius);
      if (cachedEvents.isNotEmpty) {
        _eventPlaces = cachedEvents;
        _recompute();
      }
    }
    notifyListeners();

    // 婚活・合コン・ボランティア開催地の取得は地図データの読み込みと並行して進め、届き次第反映する
    final eventsFuture = _loadEvents(seq, at, refresh: refresh);

    var ok = false;
    try {
      await _repository.load(
        at,
        radius,
        refresh: refresh,
        onElements: (elements, {required complete}) {
          if (seq != _searchSeq) return;
          _setElements(elements);
          if (!complete) status = '保存済みの結果を表示中。残りの範囲を取得しています…';
          notifyListeners();
        },
        onStatus: (message) {
          if (seq != _searchSeq) return;
          status = message;
          notifyListeners();
        },
      );
      ok = true;
    } catch (e) {
      if (seq == _searchSeq) error = _message(e);
    } finally {
      if (seq == _searchSeq) {
        searching = false;
        status = null;
        notifyListeners();
      }
    }
    if (ok && seq == _searchSeq) {
      _remember(at);
      await Future.wait([_findSns(seq), eventsFuture]);
    } else {
      await eventsFuture;
    }
  }

  Future<void> _loadEvents(int seq, LatLng at, {required bool refresh}) async {
    eventStatus = '婚活・合コン・ボランティアの開催地を確認中…';
    notifyListeners();
    try {
      final found = await _events.load(
        at,
        radius,
        localArea: centerName,
        refresh: refresh,
        isCancelled: () => seq != _searchSeq,
      );
      if (seq != _searchSeq) return;
      _eventPlaces = found;
      _recompute();
    } catch (e) {
      debugPrint('イベント情報の取得に失敗: $e');
    } finally {
      if (seq == _searchSeq && eventStatus != null) {
        eventStatus = null;
        notifyListeners();
      }
    }
  }

  void _setElements(List<Map<String, dynamic>> elements) {
    _osmPlaces = placesFromOsm(elements);
    for (final p in _osmPlaces) {
      if (p.precomputed) continue;
      final found = _finder.cached(p.id);
      if (found != null) p.addLinks(found);
    }
    _recompute();
  }

  /// 配信データの範囲外の学校や施設について、SNS アカウントを Wikidata・公式サイトから探し、
  /// 見つかったものから表示に反映する。
  Future<void> _findSns(int seq) async {
    final byId = {for (final p in _osmPlaces) p.id: p};
    try {
      await _finder.find(
        _inRange,
        isCancelled: () => seq != _searchSeq,
        onFound: (id, links) {
          if (seq != _searchSeq) return;
          byId[id]?.addLinks(links);
          notifyListeners();
        },
        onProgress: (done, total) {
          if (seq != _searchSeq) return;
          snsStatus = done < total ? '学校・施設の公式サイトから SNS を確認中… ($done/$total)' : null;
          notifyListeners();
        },
      );
    } finally {
      if (seq == _searchSeq && snsStatus != null) {
        snsStatus = null;
        notifyListeners();
      }
    }
  }

  void _remember(LatLng at) {
    final label = centerName ?? locationLabel ?? '${at.latitude.toStringAsFixed(4)}, ${at.longitude.toStringAsFixed(4)}';
    history = [
      SearchPoint(at, label, radius, DateTime.now()),
      ...history.where((h) => _distance.distance(h.position, at) > 200),
    ].take(_maxHistory).toList();
    _historyStore.save(history).catchError((Object e) => debugPrint('履歴の保存に失敗: $e'));
    notifyListeners();
  }

  void clearHistory() {
    history = [];
    _historyStore.save(history);
    notifyListeners();
  }

  void toggleCategory(PlaceCategory category) {
    if (!enabled.remove(category)) enabled.add(category);
    notifyListeners();
  }

  void setAllCategories(bool value) {
    if (value) {
      enabled.addAll(PlaceCategory.values);
    } else {
      enabled.clear();
    }
    notifyListeners();
  }

  void togglePlatform(SnsPlatform platform) {
    if (!platforms.remove(platform)) platforms.add(platform);
    notifyListeners();
  }

  void setAllPlatforms(bool value) {
    if (value) {
      platforms.addAll(SnsPlatform.values);
    } else {
      platforms.clear();
    }
    notifyListeners();
  }

  void toggleAudience(Audience audience) {
    if (!audiences.remove(audience)) audiences.add(audience);
    notifyListeners();
  }

  /// 個別の場所にチェックを付けて非表示にする／チェックを外して再表示する。
  Future<void> setHidden(Place place, bool hidden) async {
    if (hidden) {
      hiddenPlaces[place.id] = place.name;
      if (selectedId == place.id) selectedId = null;
    } else {
      hiddenPlaces.remove(place.id);
    }
    notifyListeners();
    try {
      await _hiddenStore.save(hiddenPlaces);
    } catch (e) {
      debugPrint('非表示設定の保存に失敗: $e');
    }
  }

  Future<void> unhideById(String id) async {
    if (hiddenPlaces.remove(id) == null) return;
    notifyListeners();
    try {
      await _hiddenStore.save(hiddenPlaces);
    } catch (e) {
      debugPrint('非表示設定の保存に失敗: $e');
    }
  }

  Future<void> unhideAll() async {
    if (hiddenPlaces.isEmpty) return;
    hiddenPlaces.clear();
    notifyListeners();
    try {
      await _hiddenStore.save(hiddenPlaces);
    } catch (e) {
      debugPrint('非表示設定の保存に失敗: $e');
    }
  }

  void select(String? id) {
    if (selectedId == id) return;
    selectedId = id;
    notifyListeners();
  }

  void setFilter(String value) {
    filter = value;
    notifyListeners();
  }

  Future<void> saveListing(UserListing listing) async {
    final index = listings.indexWhere((l) => l.id == listing.id);
    listings = [...listings];
    if (index >= 0) {
      listings[index] = listing;
    } else {
      listings.add(listing);
    }
    enabled.add(listing.category);
    selectedId = 'listing/${listing.id}';
    hiddenPlaces.remove(selectedId);
    _recompute();
    notifyListeners();
    await _listingStore.save(listings);
  }

  Future<void> deleteListing(String id) async {
    listings = listings.where((l) => l.id != id).toList();
    if (selectedId == 'listing/$id') selectedId = null;
    _recompute();
    notifyListeners();
    await _listingStore.save(listings);
  }

  void _recompute() {
    final at = center;
    if (at == null) {
      _inRange = const [];
      return;
    }
    final all = [..._osmPlaces, ..._eventPlaces, ...listings.map((l) => l.toPlace())];
    for (final p in all) {
      p.distanceMeters = _distance.distance(at, p.position).toDouble();
    }
    _inRange = all.where((p) => p.distanceMeters <= radius).toList()
      ..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
  }

  String _message(Object e) => e.toString().replaceFirst('Exception: ', '');
}
