import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../controllers/nearby_controller.dart';
import '../models/place.dart';
import '../services/location_service.dart';
import 'place_widgets.dart';
import 'search_filters.dart';

/// 検索条件と結果一覧。PC では地図の右、スマホでは「一覧」タブに表示する。
class SidePanel extends StatelessWidget {
  const SidePanel({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.onSelect,
    required this.onAddListing,
    required this.onOpenLink,
    required this.onSearchInstagram,
  });

  final NearbyController controller;
  final ScrollController scrollController;
  final ValueChanged<Place> onSelect;
  final VoidCallback onAddListing;
  final OpenLink onOpenLink;
  final ValueChanged<String> onSearchInstagram;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final c = controller;
    final places = c.visiblePlaces;
    // 絞り込みの項目が増えたので、検索条件の部分は高さの半分弱までにして、はみ出す分はその中でスクロールする
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.45),
            child: Scrollbar(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(_sourceIcon(c.source), size: 18, color: scheme.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              c.locating
                                  ? '現在地を取得中…'
                                  : c.centerName != null
                                  ? '${c.centerName} 付近'
                                  : (c.locationLabel ?? '現在地 未取得'),
                              style: text.titleSmall,
                            ),
                          ),
                        ],
                      ),
                      if (!c.locating && c.centerName != null && c.locationLabel != null)
                        Text(c.locationLabel!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      if (c.locationNote != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(c.locationNote!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ),
                      if (c.center != null && !c.locating) _AreaAccountsButton(
                          controller: c, onOpenLink: onOpenLink, onSearchInstagram: onSearchInstagram),
                      const SizedBox(height: 12),
                      SearchFilters(controller: c),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search),
                          hintText: '名前・ユーザー名・種別で絞り込み',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: c.setFilter,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${places.length} 件', style: text.labelLarge),
                      for (final s in [if (c.searching) c.status ?? '検索中…', ?c.snsStatus])
                        Text(s, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant), maxLines: 2),
                    ],
                  ),
                ),
                if (c.busy || c.snsStatus != null)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                TextButton.icon(
                  onPressed: onAddListing,
                  icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                  label: const Text('募集を登録'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildList(context, places)),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              'データ: © OpenStreetMap contributors・Wikidata・各施設の公式サイト ／ 「登録した募集」はこの端末に保存',
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, List<Place> places) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    if (c.error != null) {
      return _Message(
        icon: Icons.cloud_off_outlined,
        color: scheme.error,
        text: c.error!,
        action: TextButton(onPressed: c.search, child: const Text('再試行')),
      );
    }
    if (places.isEmpty && !c.busy) {
      return _Message(
        icon: Icons.search_off,
        color: scheme.onSurfaceVariant,
        text: c.placesInRange.isEmpty
            ? 'この範囲には該当する場所が見つかりませんでした。\n検索範囲を広げるか、地図の別の地点で検索してください。'
            : '絞り込み条件に一致する場所はありません。',
      );
    }
    return ListView.builder(
      controller: scrollController,
      itemExtent: PlaceTile.height,
      itemCount: places.length,
      itemBuilder: (context, i) => PlaceTile(
        place: places[i],
        category: places[i].primaryCategory(c.enabled),
        selected: places[i].id == c.selectedId,
        platforms: c.platforms,
        onTap: () => onSelect(places[i]),
        onOpenLink: onOpenLink,
      ),
    );
  }

  IconData _sourceIcon(LocationSource? source) => switch (source) {
    LocationSource.device => Icons.gps_fixed,
    LocationSource.ip => Icons.wifi_tethering,
    LocationSource.manual => Icons.push_pin_outlined,
    null => Icons.location_searching,
  };
}

/// 検索地点の地名で、その地域のアカウントを探すボタン。Instagram のアカウント検索と、
/// プロフィール（自己紹介）も対象になる X のユーザー検索を開く。
/// 個人のアカウントは住んでいる場所が公開されていないので、地名を名前や自己紹介に書いているアカウントを SNS 自身の検索で探す。
class _AreaAccountsButton extends StatelessWidget {
  const _AreaAccountsButton({required this.controller, required this.onOpenLink, required this.onSearchInstagram});

  final NearbyController controller;
  final OpenLink onOpenLink;
  final ValueChanged<String> onSearchInstagram;

  @override
  Widget build(BuildContext context) {
    final area = controller.centerName?.replaceFirst(RegExp(r'[0-9０-９一二三四五六七八九十〇]+丁目$'), '');
    if (area == null || area.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => onSearchInstagram(area),
              icon: FaIcon(SnsPlatform.instagram.icon, size: 16),
              label: Text('「$area」のアカウントを探す'),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'X で「$area」をプロフィールに書いているユーザーを探す',
            visualDensity: VisualDensity.compact,
            icon: FaIcon(SnsPlatform.x.icon, size: 16),
            onPressed: () => onOpenLink('https://x.com/search?q=${Uri.encodeQueryComponent(area)}&f=user'),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.color, required this.text, this.action});

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            ?action,
          ],
        ),
      ),
    );
  }
}
