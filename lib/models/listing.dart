import 'package:latlong2/latlong.dart';

import 'place.dart';

/// ユーザーが地図上に登録した募集情報（ボランティア募集・婚活/合コン・有償体験）。
class UserListing {
  UserListing({
    required this.id,
    required this.category,
    required this.title,
    required this.position,
    required this.createdAt,
    this.organizer,
    this.description,
    this.fee,
    this.schedule,
    this.url,
    this.contact,
  }) : assert(
         category == PlaceCategory.volunteer ||
             category == PlaceCategory.matchmaking ||
             category == PlaceCategory.experience,
       );

  final String id;

  /// [PlaceCategory.volunteer]・[PlaceCategory.matchmaking]・[PlaceCategory.experience] のいずれか。
  final PlaceCategory category;
  final String title;
  final LatLng position;
  final DateTime createdAt;
  final String? organizer;
  final String? description;

  /// 料金（婚活・合コン、有償体験など）。例: "男性 5,000円 / 女性 1,000円"、"3,000円"
  final String? fee;

  /// 日時・期間。例: "毎週土曜 10:00〜12:00"
  final String? schedule;
  final String? url;
  final String? contact;

  Place toPlace() => Place(
        id: 'listing/$id',
        name: title,
        position: position,
        categories: {category},
        kind: switch (category) {
          PlaceCategory.volunteer => 'ボランティア募集（開催地）',
          PlaceCategory.matchmaking => '婚活・合コン',
          _ => '有償体験（開催イベント）',
        },
        website: url,
        listing: this,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category.name,
        'title': title,
        'lat': position.latitude,
        'lon': position.longitude,
        'createdAt': createdAt.toIso8601String(),
        'organizer': organizer,
        'description': description,
        'fee': fee,
        'schedule': schedule,
        'url': url,
        'contact': contact,
      };

  factory UserListing.fromJson(Map<String, dynamic> json) => UserListing(
        id: json['id'] as String,
        category: PlaceCategory.values.byName(json['category'] as String),
        title: json['title'] as String,
        position: LatLng((json['lat'] as num).toDouble(), (json['lon'] as num).toDouble()),
        createdAt: DateTime.parse(json['createdAt'] as String),
        organizer: json['organizer'] as String?,
        description: json['description'] as String?,
        fee: json['fee'] as String?,
        schedule: json['schedule'] as String?,
        url: json['url'] as String?,
        contact: json['contact'] as String?,
      );
}
