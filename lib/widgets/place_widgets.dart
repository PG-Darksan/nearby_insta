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

/// 地図のマーカー。集まり・募集の開催地は角丸の四角、常設の場所は丸で描く。SNS は種類ごとのアイコン。
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
    // 地図を動かすとマーカーが入れ替わるので、色の切り替えをアニメーションさせない
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: place.isGathering ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: place.isGathering ? BorderRadius.circular(size * 0.28) : null,
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
        shape: place.isGathering ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: place.isGathering ? BorderRadius.circular(size * 0.28) : null,
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
        if (place.event case final ev?) _Badge(label: ev.source, color: const Color(0xFF455A64)),
        for (final c in PlaceCategory.values)
          if (place.categories.contains(c)) _Badge(label: c.label, color: c.color),
        if (place.audience != Audience.none) _Badge(label: place.audience.label, color: place.audience.color),
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
    this.onSearchInstagram,
    this.onSearchTikTok,
    this.onPrevPlace,
    this.onNextPlace,
    this.isHidden = false,
    this.onToggleHidden,
    this.onEdit,
    this.onDelete,
  });

  final Place place;
  final PlaceCategory category;
  final VoidCallback onClose;
  final OpenLink onOpenLink;
  final Set<SnsPlatform>? platforms;

  /// Instagram でアカウントを検索する（引数は検索語）。
  final ValueChanged<String>? onSearchInstagram;

  /// TikTok でアカウントを検索する（引数は検索語）。
  final ValueChanged<String>? onSearchTikTok;

  /// 前後のスポットへ高速切り替えするコールバック。
  final VoidCallback? onPrevPlace;
  final VoidCallback? onNextPlace;

  final bool isHidden;
  final ValueChanged<bool>? onToggleHidden;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final listing = place.listing;
    final event = place.event;
    final link = place.primaryLink(platforms) ?? place.primaryLink();
    final secondarySnsLinks = [
      for (final l in place.sortedLinks)
        if (link == null || l.platform != link.platform)
          if (l.platform == SnsPlatform.instagram || l.platform == SnsPlatform.tiktok) l,
    ];
    final description = listing?.description ?? event?.description;
    final details = <(IconData, String)>[
      if (event?.venue case final v?) (Icons.location_on_outlined, '開催地: $v'),
      if ((listing?.organizer ?? event?.organizer) case final v?) (Icons.groups_outlined, v),
      if ((listing?.fee ?? event?.fee) case final v?) (Icons.payments_outlined, v),
      if ((listing?.schedule ?? event?.schedule) case final v?) (Icons.event_outlined, v),
      if (listing?.contact case final v?) (Icons.mail_outline, v),
      if (place.address case final v?)
        (Icons.place_outlined, place.isGathering && event?.venue == null ? '開催地住所: $v' : v),
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
                  if (description != null && description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(description, maxLines: 4, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
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
                      for (final sec in secondarySnsLinks.take(1))
                        FilledButton.tonalIcon(
                          onPressed: () => onOpenLink(sec.url),
                          icon: FaIcon(sec.platform.icon, size: 15, color: sec.platform.color),
                          label: Text('${sec.platform.label} で開く'),
                        ),
                      if (place.website case final url?)
                        place.isGathering && link == null
                            ? FilledButton.icon(
                                onPressed: () => openExternal(url),
                                icon: const Icon(Icons.open_in_new, size: 18),
                                label: const Text('詳細・申込ページ'),
                              )
                            : OutlinedButton.icon(
                                onPressed: () => openExternal(url),
                                icon: const Icon(Icons.language, size: 18),
                                label: Text(place.isGathering ? '詳細ページ' : 'Web サイト'),
                              ),
                      if (place.sortedLinks.any((l) => l.taggedPosts != null))
                        TaggedPostsButton(links: place.sortedLinks, onOpenLink: onOpenLink),
                      if (!place.isListing && onSearchInstagram != null)
                        TextButton.icon(
                          onPressed: () => onSearchInstagram!(place.searchQuery),
                          icon: FaIcon(SnsPlatform.instagram.icon, size: 16),
                          label: const Text('Instagram で探す'),
                        ),
                      if (!place.isListing && onSearchTikTok != null)
                        TextButton.icon(
                          onPressed: () => onSearchTikTok!(place.searchQuery),
                          icon: FaIcon(SnsPlatform.tiktok.icon, size: 15),
                          label: const Text('TikTok で探す'),
                        ),
                      if (onToggleHidden case final toggle?)
                        FilterChip(
                          selected: isHidden,
                          showCheckmark: true,
                          visualDensity: VisualDensity.compact,
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!isHidden) ...[
                                const Icon(Icons.visibility_off_outlined, size: 16),
                                const SizedBox(width: 4),
                              ],
                              Text(isHidden ? '非表示中' : '非表示にする'),
                            ],
                          ),
                          onSelected: toggle,
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
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(onPressed: onClose, icon: const Icon(Icons.close), tooltip: '閉じる'),
                if (onPrevPlace != null || onNextPlace != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '前のスポット',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                        padding: EdgeInsets.zero,
                        onPressed: onPrevPlace,
                        icon: const Icon(Icons.chevron_left, size: 20),
                      ),
                      IconButton(
                        tooltip: '次のスポット',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                        padding: EdgeInsets.zero,
                        onPressed: onNextPlace,
                        icon: const Icon(Icons.chevron_right, size: 20),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// アカウントがタグ付け・メンションされた投稿や、Instagram の場所ページを開くボタン（複数あればメニュー）。
class TaggedPostsButton extends StatelessWidget {
  const TaggedPostsButton({super.key, required this.links, required this.onOpenLink});

  final List<SocialLink> links;
  final OpenLink onOpenLink;

  static const _label = 'タグ付けされた投稿';
  static const _icon = Icon(Icons.photo_library_outlined, size: 18);

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final l in links)
        if (l.taggedPosts case final t?) (link: l, url: t.url, label: t.label),
    ];
    if (items.length == 1) {
      return OutlinedButton.icon(
        onPressed: () => onOpenLink(items.first.url),
        icon: _icon,
        label: const Text(_label),
      );
    }
    return MenuAnchor(
      menuChildren: [
        for (final item in items)
          MenuItemButton(
            leadingIcon: SizedBox(
              width: 20,
              child: Center(child: FaIcon(item.link.platform.icon, size: 16, color: item.link.platform.color)),
            ),
            onPressed: () => onOpenLink(item.url),
            child: Text('${item.link.platform.label}: ${item.label}'),
          ),
      ],
      builder: (context, menu, _) => OutlinedButton.icon(
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: _icon,
        label: const Text(_label),
      ),
    );
  }
}
