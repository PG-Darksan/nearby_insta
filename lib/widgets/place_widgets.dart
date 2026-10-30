import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/place.dart';

const instagramGradient = LinearGradient(
  begin: Alignment.bottomLeft,
  end: Alignment.topRight,
  colors: [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF), Color(0xFF515BD4)],
);

const instagramPink = Color(0xFFC13584);

String formatDistance(double meters) =>
    meters < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(1)} km';

Future<void> openExternal(String url) {
  final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// 地図のマーカー。登録した募集は角丸の四角、OSM の場所は丸で描く。
class PlaceMarker extends StatelessWidget {
  const PlaceMarker({super.key, required this.place, required this.category, required this.selected});

  final Place place;
  final PlaceCategory category;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final size = selected ? 46.0 : 32.0;
    final isInstagram = category == PlaceCategory.instagram;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: place.isListing ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: place.isListing ? BorderRadius.circular(size * 0.28) : null,
        color: isInstagram ? null : category.color,
        gradient: isInstagram ? instagramGradient : null,
        border: Border.all(color: Colors.white, width: selected ? 3 : 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: Icon(category.icon, color: Colors.white, size: size * 0.52),
    );
  }
}

/// 一覧用のアイコン。Instagram は頭文字、それ以外はカテゴリのアイコンを表示する。
class PlaceAvatar extends StatelessWidget {
  const PlaceAvatar({super.key, required this.place, required this.category, this.size = 44});

  final Place place;
  final PlaceCategory category;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (category != PlaceCategory.instagram) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: category.color.withValues(alpha: 0.12),
          shape: place.isListing ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: place.isListing ? BorderRadius.circular(size * 0.28) : null,
          border: Border.all(color: category.color, width: 2),
        ),
        child: Icon(category.icon, color: category.color, size: size * 0.5),
      );
    }
    final initial = (place.instagram?.username ?? place.name).characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: instagramGradient),
      child: Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.surface),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w700, color: instagramPink),
        ),
      ),
    );
  }
}

class CategoryBadges extends StatelessWidget {
  const CategoryBadges({super.key, required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        if (place.isListing) const _Badge(label: '登録した募集', color: Color(0xFF616161)),
        for (final c in PlaceCategory.values)
          if (place.categories.contains(c)) _Badge(label: c.label, color: c.color),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class PlaceTile extends StatelessWidget {
  const PlaceTile({
    super.key,
    required this.place,
    required this.category,
    required this.selected,
    required this.onTap,
  });

  static const height = 76.0;

  final Place place;
  final PlaceCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final listing = place.listing;
    final (String? subtitle, Color? subtitleColor) = switch (place) {
      _ when listing != null => (
          [listing.organizer, listing.fee, listing.schedule].whereType<String>().join(' · '),
          null
        ),
      Place(instagram: final ig?) => (ig.handle, instagramPink),
      _ => (place.address, null),
    };
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              PlaceAvatar(place: place, category: category),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(place.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    if (subtitle != null && subtitle.isNotEmpty)
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: subtitleColor ?? scheme.onSurfaceVariant)),
                    Text(
                      [?place.kind, formatDistance(place.distanceMeters)].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (place.instagram != null)
                IconButton(
                  tooltip: 'Instagram で開く',
                  icon: const Icon(Icons.camera_alt_outlined, size: 20, color: instagramPink),
                  onPressed: () => openExternal(place.instagram!.url),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 地図の下部に重ねて表示する、選択中の場所の詳細カード。
class PlaceDetailCard extends StatelessWidget {
  const PlaceDetailCard({
    super.key,
    required this.place,
    required this.category,
    required this.onClose,
    this.onEdit,
    this.onDelete,
  });

  final Place place;
  final PlaceCategory category;
  final VoidCallback onClose;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final listing = place.listing;
    final ig = place.instagram;
    final details = <(IconData, String)>[
      if (listing?.organizer case final v?) (Icons.groups_outlined, v),
      if (listing?.fee case final v?) (Icons.payments_outlined, v),
      if (listing?.schedule case final v?) (Icons.event_outlined, v),
      if (listing?.contact case final v?) (Icons.mail_outline, v),
      if (place.address case final v?) (Icons.place_outlined, v),
    ];
    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PlaceAvatar(place: place, category: category, size: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(place.name, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  if (ig != null) Text(ig.handle, style: text.bodyMedium?.copyWith(color: instagramPink)),
                  const SizedBox(height: 4),
                  CategoryBadges(place: place),
                  const SizedBox(height: 4),
                  Text(
                    [?place.kind, '現在地から ${formatDistance(place.distanceMeters)}'].join(' · '),
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (listing?.description case final d? when d.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(d, maxLines: 4, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                    ),
                  for (final (icon, value) in details)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(child: Text(value, style: text.bodySmall)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (ig != null)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: instagramGradient,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: Colors.transparent),
                            onPressed: () => openExternal(ig.url),
                            icon: const Icon(Icons.camera_alt_outlined, size: 18),
                            label: const Text('Instagram で開く'),
                          ),
                        ),
                      if (place.website case final url?)
                        OutlinedButton.icon(
                          onPressed: () => openExternal(url),
                          icon: const Icon(Icons.language, size: 18),
                          label: Text(listing != null ? '詳細ページ' : 'Web サイト'),
                        ),
                      if (place.osmUrl case final url?)
                        TextButton.icon(
                          onPressed: () => openExternal(url),
                          icon: const Icon(Icons.map_outlined, size: 18),
                          label: const Text('OSM で見る'),
                        ),
                      if (onEdit != null)
                        TextButton.icon(
                          onPressed: onEdit,
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('編集'),
                        ),
                      if (onDelete != null)
                        TextButton.icon(
                          style: TextButton.styleFrom(foregroundColor: scheme.error),
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('削除'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(onPressed: onClose, icon: const Icon(Icons.close), tooltip: '閉じる'),
          ],
        ),
      ),
    );
  }
}
