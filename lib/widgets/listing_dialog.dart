import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/listing.dart';
import '../models/place.dart';

/// 募集情報（ボランティア募集・婚活/合コン・有償体験）を登録・編集するダイアログ。
/// 保存すると [UserListing] を返す。
Future<UserListing?> showListingDialog(BuildContext context, {required LatLng position, UserListing? initial}) {
  return showDialog<UserListing>(
    context: context,
    builder: (_) => _ListingDialog(position: position, initial: initial),
  );
}

class _ListingDialog extends StatefulWidget {
  const _ListingDialog({required this.position, this.initial});

  final LatLng position;
  final UserListing? initial;

  @override
  State<_ListingDialog> createState() => _ListingDialogState();
}

class _ListingDialogState extends State<_ListingDialog> {
  final _form = GlobalKey<FormState>();
  late PlaceCategory _category = widget.initial?.category ?? PlaceCategory.volunteer;
  late final _title = TextEditingController(text: widget.initial?.title);
  late final _organizer = TextEditingController(text: widget.initial?.organizer);
  late final _description = TextEditingController(text: widget.initial?.description);
  late final _fee = TextEditingController(text: widget.initial?.fee);
  late final _schedule = TextEditingController(text: widget.initial?.schedule);
  late final _url = TextEditingController(text: widget.initial?.url);
  late final _contact = TextEditingController(text: widget.initial?.contact);

  @override
  void dispose() {
    for (final c in [_title, _organizer, _description, _fee, _schedule, _url, _contact]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _value(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  bool get _hasFee => _category == PlaceCategory.experience || _category == PlaceCategory.matchmaking;

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final initial = widget.initial;
    Navigator.pop(
      context,
      UserListing(
        id: initial?.id ?? DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        category: _category,
        title: _title.text.trim(),
        position: widget.position,
        createdAt: initial?.createdAt ?? DateTime.now(),
        organizer: _value(_organizer),
        description: _value(_description),
        fee: _hasFee ? _value(_fee) : null,
        schedule: _value(_schedule),
        url: _value(_url),
        contact: _value(_contact),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hintTitle = switch (_category) {
      PlaceCategory.volunteer => '例: 公園の清掃ボランティア',
      PlaceCategory.matchmaking => '例: 20代・30代 カフェ合コン・街コン',
      _ => '例: 陶芸体験（初心者歓迎）',
    };
    return AlertDialog(
      title: Text(widget.initial == null ? '募集情報を登録' : '募集情報を編集'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<PlaceCategory>(
                  showSelectedIcon: false,
                  segments: [
                    for (final c in [PlaceCategory.volunteer, PlaceCategory.matchmaking, PlaceCategory.experience])
                      ButtonSegment(
                        value: c,
                        icon: Icon(c.icon, size: 18),
                        label: Text(switch (c) {
                          PlaceCategory.volunteer => 'ボランティア',
                          PlaceCategory.matchmaking => '婚活・合コン',
                          _ => '有償体験',
                        }),
                      ),
                  ],
                  selected: {_category},
                  onSelectionChanged: (s) => setState(() => _category = s.first),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _title,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'タイトル *',
                    hintText: hintTitle,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'タイトルを入力してください' : null,
                ),
                TextFormField(
                  controller: _organizer,
                  decoration: const InputDecoration(labelText: '主催・団体名・会場名'),
                ),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: '内容'),
                  minLines: 2,
                  maxLines: 5,
                ),
                if (_hasFee)
                  TextFormField(
                    controller: _fee,
                    decoration: InputDecoration(
                      labelText: '料金・参加費',
                      hintText: _category == PlaceCategory.matchmaking ? '例: 男性 5,000円 / 女性 1,000円' : '例: 3,000円',
                    ),
                  ),
                TextFormField(
                  controller: _schedule,
                  decoration: const InputDecoration(labelText: '日時・期間', hintText: '例: 毎週土曜 10:00〜12:00'),
                ),
                TextFormField(
                  controller: _url,
                  decoration: const InputDecoration(labelText: '詳細ページの URL'),
                  keyboardType: TextInputType.url,
                  validator: (v) {
                    final s = v?.trim() ?? '';
                    if (s.isEmpty) return null;
                    final uri = Uri.tryParse(s.startsWith('http') ? s : 'https://$s');
                    return uri == null || uri.host.isEmpty ? 'URL の形式が正しくありません' : null;
                  },
                ),
                TextFormField(
                  controller: _contact,
                  decoration: const InputDecoration(labelText: '連絡先'),
                ),
                const SizedBox(height: 12),
                Text(
                  '開催地の位置: ${widget.position.latitude.toStringAsFixed(5)}, ${widget.position.longitude.toStringAsFixed(5)}'
                  '\n指定した地点が開催地として地図に表示されます（この端末の中だけに保存されます）。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
