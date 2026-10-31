import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/listing.dart';
import '../models/place.dart';
import '../services/geocoding_service.dart';
import '../services/sns_finder.dart';
import '../services/listing_store.dart';
import '../services/location_service.dart';
import '../services/place_repository.dart';
import '../services/search_history.dart';

/// 検索地点・検索範囲・検索結果・登録した募集情報・検索履歴をまとめて管理する。
class NearbyController extends ChangeNotifier {
  NearbyController({
    LocationService? location,
    PlaceRepository? repository,
    SnsFinder? finder,
    GeocodingService? geocoding,
    ListingStore? listingStore,
    SearchHistoryStore? historyStore,
  })  : _location = location ?? LocationService(),
        _repository = repository ?? PlaceRepository(),
        _finder = finder ?? SnsFinder(),
        geocoding = geocoding ?? GeocodingService(),
        _listingStore = listingStore ?? ListingStore(),
        _historyStore = historyStore ?? SearchHistoryStore();

  final LocationService _location;
  final PlaceRepository _repository;
  final SnsFinder _finder;
  final GeocodingService geocoding;
  final ListingStore _listingStore;
  final SearchHistoryStore _historyStore;

  static const radiusOptions = [300, 1000, 3000, 5000, 10000, 20000];
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
  String filter = '';
  String? selectedId;

  bool locating = false;
  bool searching = false;
  String? error;

  /// 取得中・再試行中などの経過メッセージ。
  String? status;

  /// 公式サイトなどから SNS アカウントを探している間の経過メッセージ。
  String? snsStatus;

  List<UserListing> listings = [];
  List<SearchPoint> history = [];

  List<Place> _osmPlaces = const [];
  List<Place> _inRange = const [];

  /// 古い検索の結果で新しい結果を上書きしないための連番。
  int _searchSeq = 0;

  bool get busy => locating || searching;

  /// 検索範囲内の場所（カテゴリ・キーワードで絞り込む前）。近い順。
  List<Place> get placesInRange => _inRange;

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

  /// カテゴリ・SNS の種類ごとの件数を 1 回の走査で数える。
  Map<Object, int> get _countMap => _counts ??= () {
        final counts = <Object, int>{};
        void add(Object key) => counts[key] = (counts[key] ?? 0) + 1;
        for (final p in _inRange) {
          add(p.audience);
          p.baseCategories.forEach(add);
          final linked = {for (final l in p.links) l.platform};
          linked.forEach(add);
          if (linked.any(platforms.contains)) add(PlaceCategory.sns);
        }
        return counts;
      }();

  /// カテゴリと SNS の種類の表示設定で、地図・一覧に出すか。
  bool isShown(Place p) =>
      audiences.contains(p.audience) &&
      (p.baseCategories.any(enabled.contains) || (enabled.contains(PlaceCategory.sns) && p.hasLinkOn(platforms)));

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
      listings = await _listingStore.load();
      history = await _historyStore.load();
    } catch (e) {
      debugPrint('保存データの読み込みに失敗: $e');
    }
    await _finder.warmUp();
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
    if (radius != null) this.radius = radius;
    locationNote = null;
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
    radius = value;
    _recompute();
    return search();
  }

  /// 保存済みの範囲はすぐに表示し、足りない範囲だけを取得する。[refresh] なら全て取り直す。
  Future<void> search({bool refresh = false}) async {
    final at = center;
    if (at == null) return;
    final seq = ++_searchSeq;
    searching = true;
    error = null;
    status = null;
    snsStatus = null;
    notifyListeners();
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
      await _findSns(seq);
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

  void togglePlatform(SnsPlatform platform) {
    if (!platforms.remove(platform)) platforms.add(platform);
    notifyListeners();
  }

  void toggleAudience(Audience audience) {
    if (!audiences.remove(audience)) audiences.add(audience);
    notifyListeners();
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
    final all = [..._osmPlaces, ...listings.map((l) => l.toPlace())];
    for (final p in all) {
      p.distanceMeters = _distance.distance(at, p.position).toDouble();
    }
    _inRange = all.where((p) => p.distanceMeters <= radius).toList()
      ..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
  }

  String _message(Object e) => e.toString().replaceFirst('Exception: ', '');
}
