import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/place.dart';

const instagramGradient = LinearGradient(
  begin: Alignment.bottomLeft,
  end: Alignment.topRight,
  colors: [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF), Color(0xFF515BD4)],
);

/// SNS のページを開く（アプリ内ブラウザが使えればそこで、なければ外部で）。
typedef OpenLink = void Function(String url);

String formatDistance(double meters) =>
    meters < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(1)} km';

Future<void> openExternal(String url) {
  final uri = Uri.parse(url.startsWith('http') || url.contains(':') ? url : 'https://$url');
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// 地図のマーカー。登録した募集は角丸の四角、OSM の場所は丸で描く。SNS は種類ごとのアイコン。
class PlaceMarker extends StatelessWidget {
  const PlaceMarker({
    super.key,
    required this.place,
    required this.category,
    required this.selected,
    this.platforms,
  });

  final Place place;
  final PlaceCategory category;
  final bool selected;
  final Set<SnsPlatform>? platforms;

  @override
  Widget build(BuildContext context) {
    final size = selected ? 46.0 : 32.0;
    final platform = category == PlaceCategory.sns ? place.primaryLink(platforms)?.platform : null;
    final isInstagram = platform == SnsPlatform.instagram;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: place.isListing ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: place.isListing ? BorderRadius.circular(size * 0.28) : null,
        color: isInstagram ? null : (platform?.color ?? category.color),
        gradient: isInstagram ? instagramGradient : null,
        border: Border.all(color: Colors.white, width: selected ? 3 : 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: platform != null
          ? FaIcon(platform.icon, color: Colors.white, size: size * 0.46)
          : Icon(category.icon, color: Colors.white, size: size * 0.52),
    );
  }
}

/// 一覧用のアイコン。SNS は種類ごとのアイコン、それ以外はカテゴリのアイコンを表示する。
class PlaceAvatar extends StatelessWidget {
  const PlaceAvatar({super.key, required this.place, required this.category, this.size = 44, this.platforms});

  final Place place;
  final PlaceCategory category;
  final double size;
  final Set<SnsPlatform>? platforms;

  @override
  Widget build(BuildContext context) {
    final platform = category == PlaceCategory.sns ? place.primaryLink(platforms)?.platform : null;
    final color = platform?.color ?? category.color;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        shape: place.isListing ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: place.isListing ? BorderRadius.circular(size * 0.28) : null,
        border: Border.all(color: color, width: 2),
      ),
      child: platform != null
          ? FaIcon(platform.icon, color: color, size: size * 0.44)
          : Icon(category.icon, color: color, size: size * 0.5),
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
    required this.onOpenLink,
    this.platforms,
  });

  static const height = 76.0;

  final Place place;
  final PlaceCategory category;
  final bool selected;
  final VoidCallback onTap;
  final OpenLink onOpenLink;
  final Set<SnsPlatform>? platforms;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final listing = place.listing;
    final link = place.primaryLink(platforms);
    final (String? subtitle, Color? subtitleColor) = switch (place) {
      _ when listing != null => (
          [listing.organizer, listing.fee, listing.schedule].whereType<String>().join(' · '),
          null
        ),
      _ when link != null => (
          [link.handle, if (place.links.length > 1) '他 ${place.links.length - 1} 件'].join('  '),
          link.platform.color
        ),
      _ => (place.address, null),
    };
    // 種類ごとに 1 つずつ、最大 3 つのボタンを並べる
    final buttons = <SocialLink>[];
    for (final l in place.sortedLinks) {
      if (buttons.length < 3 && !buttons.any((b) => b.platform == l.platform)) buttons.add(l);
    }
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Row(
            children: [
              PlaceAvatar(place: place, category: category, platforms: platforms),
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
              for (final b in buttons)
                IconButton(
                  tooltip: '${b.platform.label} で開く（${b.handle}）',
                  visualDensity: VisualDensity.compact,
                  icon: FaIcon(b.platform.icon, size: 18, color: b.platform.color),
                  onPressed: () => onOpenLink(b.url),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 詳細カード内の SNS アカウント 1 件（見つけた場所も添える）。
class _SnsRow extends StatelessWidget {
  const _SnsRow({required this.link, required this.onOpenLink});

  final SocialLink link;
  final OpenLink onOpenLink;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = link.platform.color;
    return InkWell(
      onTap: () => onOpenLink(link.url),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          children: [
            SizedBox(width: 18, child: Center(child: FaIcon(link.platform.icon, size: 15, color: color))),
            Text(link.handle, style: text.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w600)),
            Text('（${link.source.label}）',
                style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
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
    required this.onOpenLink,
    this.platforms,
    this.onEdit,
    this.onDelete,
  });

  final Place place;
  final PlaceCategory category;
  final VoidCallback onClose;
  final OpenLink onOpenLink;
  final Set<SnsPlatform>? platforms;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final listing = place.listing;
    final link = place.primaryLink(platforms) ?? place.primaryLink();
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
            PlaceAvatar(place: place, category: category, size: 52, platforms: platforms),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(place.name, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  for (final l in place.sortedLinks) _SnsRow(link: l, onOpenLink: onOpenLink),
                  const SizedBox(height: 4),
                  CategoryBadges(place: place),
                  const SizedBox(height: 4),
                  Text(
                    [?place.kind, '検索地点から ${formatDistance(place.distanceMeters)}'].join(' · '),
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
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (link != null)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: link.platform.color),
                          onPressed: () => onOpenLink(link.url),
                          icon: FaIcon(link.platform.icon, size: 16),
                          label: Text('${link.platform.label} で開く'),
                        ),
                      if (place.website case final url?)
                        OutlinedButton.icon(
                          onPressed: () => openExternal(url),
                          icon: const Icon(Icons.language, size: 18),
                          label: Text(listing != null ? '詳細ページ' : 'Web サイト'),
                        ),
                      if (!place.isListing) SnsSearchButton(query: place.name, onOpenLink: onOpenLink),
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

/// 名前で各 SNS を検索するメニュー。データにないアカウントや、その場所についての投稿を探すのに使う。
class SnsSearchButton extends StatelessWidget {
  const SnsSearchButton({super.key, required this.query, required this.onOpenLink, this.label = 'SNS で探す'});

  final String query;
  final OpenLink onOpenLink;
  final String label;

  static const _platforms = [
    SnsPlatform.instagram,
    SnsPlatform.x,
    SnsPlatform.tiktok,
    SnsPlatform.threads,
    SnsPlatform.facebook,
    SnsPlatform.youtube,
  ];

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final p in _platforms)
          MenuItemButton(
            leadingIcon: SizedBox(width: 20, child: Center(child: FaIcon(p.icon, size: 16, color: p.color))),
            onPressed: () => onOpenLink(p.searchUrl(query)),
            child: Text('${p.label} で「$query」を検索'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.travel_explore, size: 20),
          onPressed: () => openExternal('https://www.google.com/search?q=${Uri.encodeQueryComponent('"$query" '
              '(site:instagram.com OR site:x.com OR site:facebook.com OR site:tiktok.com)')}'),
          child: const Text('Google で SNS のアカウントを探す'),
        ),
      ],
      builder: (context, menu, _) => TextButton.icon(
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.manage_search, size: 18),
        label: Text(label),
      ),
    );
  }
}
