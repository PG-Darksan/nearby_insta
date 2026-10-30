import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/listing.dart';
import '../models/place.dart';
import '../services/listing_store.dart';
import '../services/location_service.dart';
import '../services/overpass_service.dart';

/// 検索地点・検索範囲・検索結果・登録した募集情報をまとめて管理する。
class NearbyController extends ChangeNotifier {
  NearbyController({LocationService? location, OverpassService? overpass, ListingStore? store})
      : _location = location ?? LocationService(),
        _overpass = overpass ?? OverpassService(),
        _store = store ?? ListingStore();

  final LocationService _location;
  final OverpassService _overpass;
  final ListingStore _store;

  static const radiusOptions = [300, 500, 1000, 2000, 5000];
  static const _distance = Distance();

  LatLng? center;
  LocationSource? source;
  String? locationLabel;
  String? locationNote;
  int radius = 1000;

  final Set<PlaceCategory> enabled = {...PlaceCategory.values};
  String filter = '';
  String? selectedId;

  bool locating = false;
  bool searching = false;
  String? error;

  /// 再試行中などの経過メッセージ。
  String? status;

  List<UserListing> listings = [];

  List<Place> _osmPlaces = const [];
  LatLng? _fetchedCenter;
  int _fetchedRadius = 0;
  List<Place> _inRange = const [];

  /// 古い検索の結果で新しい結果を上書きしないための連番。
  int _searchSeq = 0;

  bool get busy => locating || searching;

  /// 検索範囲内の場所（カテゴリ・キーワードで絞り込む前）。近い順。
  List<Place> get placesInRange => _inRange;

  List<Place> get visiblePlaces => _inRange
      .where((p) => p.categories.any(enabled.contains) && p.matches(filter))
      .toList();

  int countOf(PlaceCategory category) => _inRange.where((p) => p.categories.contains(category)).length;

  Place? get selected {
    for (final p in _inRange) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  Future<void> init() async {
    try {
      listings = await _store.load();
    } catch (e) {
      debugPrint('募集情報の読み込みに失敗: $e');
    }
    _recompute();
    await locate();
  }

  Future<void> locate() async {
    locating = true;
    error = null;
    notifyListeners();
    try {
      final result = await _location.getCurrentLocation();
      center = result.position;
      source = result.source;
      locationLabel = result.label;
      locationNote = result.note;
      _recompute();
    } catch (e) {
      error = _message(e);
    } finally {
      locating = false;
      notifyListeners();
    }
    if (center != null) await search();
  }

  Future<void> setCenter(LatLng position) {
    center = position;
    source = LocationSource.manual;
    locationLabel = '地図で指定した地点';
    locationNote = null;
    _recompute();
    return search();
  }

  Future<void> setRadius(int value) {
    radius = value;
    _recompute();
    return search();
  }

  /// 同じ地点をより広い範囲で取得済みなら、通信せずに絞り込みだけ行う。
  Future<void> search({bool force = false}) async {
    final at = center;
    if (at == null) return;
    if (!force && at == _fetchedCenter && radius <= _fetchedRadius) {
      notifyListeners();
      return;
    }
    final seq = ++_searchSeq;
    final searchRadius = radius;
    searching = true;
    error = null;
    status = null;
    notifyListeners();
    try {
      final result = await _overpass.search(at, searchRadius, onRetry: (message) {
        if (seq != _searchSeq) return;
        status = message;
        notifyListeners();
      });
      if (seq != _searchSeq) return;
      _osmPlaces = result;
      _fetchedCenter = at;
      _fetchedRadius = searchRadius;
      _recompute();
    } catch (e) {
      if (seq == _searchSeq) error = _message(e);
    } finally {
      if (seq == _searchSeq) {
        searching = false;
        status = null;
        notifyListeners();
      }
    }
  }

  void toggleCategory(PlaceCategory category) {
    if (!enabled.remove(category)) enabled.add(category);
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
    await _store.save(listings);
  }

  Future<void> deleteListing(String id) async {
    listings = listings.where((l) => l.id != id).toList();
    if (selectedId == 'listing/$id') selectedId = null;
    _recompute();
    notifyListeners();
    await _store.save(listings);
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
