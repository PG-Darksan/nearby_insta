import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// 対応している SNS。並び順が一覧や詳細カードでの表示順になる。
enum SnsPlatform {
  instagram('Instagram', FontAwesomeIcons.instagram, Color(0xFFDD2A7B)),
  x('X', FontAwesomeIcons.xTwitter, Color(0xFF14171A)),
  facebook('Facebook', FontAwesomeIcons.facebook, Color(0xFF1877F2)),
  tiktok('TikTok', FontAwesomeIcons.tiktok, Color(0xFF111111)),
  youtube('YouTube', FontAwesomeIcons.youtube, Color(0xFFE62117)),
  line('LINE', FontAwesomeIcons.line, Color(0xFF06C755)),
  threads('Threads', FontAwesomeIcons.threads, Color(0xFF101010)),
  bluesky('Bluesky', FontAwesomeIcons.bluesky, Color(0xFF1185FE));

  const SnsPlatform(this.label, this.icon, this.color);

  final String label;
  final FaIconData icon;
  final Color color;

  /// [query] をこの SNS の中で検索する URL（ログインしていると結果が多く表示される）。
  String searchUrl(String query) {
    final q = Uri.encodeQueryComponent(query);
    return switch (this) {
      instagram => 'https://www.instagram.com/explore/search/keyword/?q=$q',
      x => 'https://x.com/search?q=$q&f=live',
      facebook => 'https://www.facebook.com/search/top?q=$q',
      tiktok => 'https://www.tiktok.com/search?q=$q',
      youtube => 'https://www.youtube.com/results?search_query=$q',
      line => 'https://www.google.com/search?q=${Uri.encodeQueryComponent('LINE公式アカウント $query')}',
      threads => 'https://www.threads.com/search?q=$q',
      bluesky => 'https://bsky.app/search?q=$q',
    };
  }
}

/// SNS アカウントをどこで見つけたか。
enum SnsSource {
  osm('OpenStreetMap'),
  wikidata('Wikidata'),
  website('公式サイトに掲載');

  const SnsSource(this.label);
  final String label;
}

/// SNS アカウント 1 件。[id] はユーザー名（@ なし）、YouTube の `@handle` や `channel/UC…`、
/// ユーザー名で表せないものは URL そのもの（tool/sns.py と同じ表し方）。
class SocialLink {
  const SocialLink(this.platform, this.id, [this.source = SnsSource.osm]);

  final SnsPlatform platform;
  final String id;
  final SnsSource source;

  bool get _isUrl => id.startsWith('http');

  String get url {
    if (_isUrl) return id;
    return switch (platform) {
      SnsPlatform.instagram => 'https://www.instagram.com/$id/',
      SnsPlatform.x => 'https://x.com/$id',
      SnsPlatform.facebook => 'https://www.facebook.com/$id',
      SnsPlatform.tiktok => 'https://www.tiktok.com/@$id',
      SnsPlatform.youtube => 'https://www.youtube.com/$id',
      SnsPlatform.line => 'https://line.me/R/ti/p/${Uri.encodeComponent(id)}',
      SnsPlatform.threads => 'https://www.threads.com/@$id',
      SnsPlatform.bluesky => 'https://bsky.app/profile/$id',
    };
  }

  /// Instagram の場所ページ（その場所でタグ付けされた投稿の一覧）か。
  bool get isInstagramLocation => platform == SnsPlatform.instagram && id.contains('/explore/locations/');

  /// このアカウント（または場所）がタグ付け・メンションされた投稿を見る URL と、その説明。
  /// 外から一覧を取得する手段がないので、ログインしたアプリ内ブラウザで各 SNS のページを開く。
  ({String url, String label})? get taggedPosts {
    if (isInstagramLocation) return (url: url, label: 'この場所でタグ付けされた投稿');
    final name = username;
    if (name == null) return null;
    String q(String s) => Uri.encodeQueryComponent(s);
    return switch (platform) {
      SnsPlatform.instagram => (url: 'https://www.instagram.com/$name/tagged/', label: '@$name がタグ付けされた投稿'),
      SnsPlatform.x => (url: 'https://x.com/search?q=${q('@$name -from:$name')}&f=live', label: '@$name へのメンション'),
      SnsPlatform.threads => (url: 'https://www.threads.com/search?q=${q('@$name')}', label: '@$name へのメンション'),
      SnsPlatform.bluesky => (url: 'https://bsky.app/search?q=${q('mentions:$name')}', label: '@$name へのメンション'),
      _ => null,
    };
  }

  /// 画面に表示する名前（@ユーザー名など）。
  String get handle {
    if (isInstagramLocation) return 'Instagram の場所ページ';
    if (_isUrl) return '${platform.label} ページ';
    return switch (platform) {
      SnsPlatform.youtube => id.startsWith('@') ? id : 'YouTube チャンネル',
      SnsPlatform.line => id.startsWith('@') ? id : 'LINE 公式アカウント',
      SnsPlatform.facebook => id,
      _ => '@$id',
    };
  }

  /// 絞り込み検索の対象にするユーザー名。
  String? get username => _isUrl ? null : id.replaceFirst('@', '');

  String get key => '${platform.name}:${id.toLowerCase()}';

  List<String> toJson() => [platform.name, id, source.name];

  /// `[platform, id, source]` の形（タイルのデータと保存形式）から読む。
  static SocialLink? fromJson(Object? json) {
    if (json is! List || json.length < 2) return null;
    final platform = SnsPlatform.values.asNameMap()[json[0]];
    final id = json[1];
    if (platform == null || id is! String) return null;
    final source = json.length > 2 ? SnsSource.values.asNameMap()[json[2]] : null;
    return SocialLink(platform, id, source ?? SnsSource.osm);
  }

  @override
  bool operator ==(Object other) => other is SocialLink && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => '${platform.name}:$id';
}

// ---- URL・タグ値の解釈（tool/sns.py と同じ規則）

/// OSM でアカウントを記録するタグ。
const snsTagKeys = {
  SnsPlatform.instagram: ['contact:instagram', 'instagram'],
  SnsPlatform.x: ['contact:x', 'contact:twitter', 'twitter'],
  SnsPlatform.facebook: ['contact:facebook', 'facebook'],
  SnsPlatform.tiktok: ['contact:tiktok', 'tiktok'],
  SnsPlatform.youtube: ['contact:youtube', 'youtube'],
  SnsPlatform.line: ['contact:line'],
  SnsPlatform.threads: ['contact:threads'],
  SnsPlatform.bluesky: ['contact:bluesky'],
};

final _userPatterns = {
  SnsPlatform.instagram: RegExp(r'^[A-Za-z0-9._]{1,30}$'),
  SnsPlatform.x: RegExp(r'^[A-Za-z0-9_]{1,15}$'),
  SnsPlatform.facebook: RegExp(r'^[A-Za-z0-9.\-]{2,80}$'),
  SnsPlatform.tiktok: RegExp(r'^[A-Za-z0-9._]{2,24}$'),
  SnsPlatform.threads: RegExp(r'^[A-Za-z0-9._]{1,30}$'),
  SnsPlatform.bluesky: RegExp(r'^[A-Za-z0-9.\-]{3,253}\.[A-Za-z]{2,}$'),
};

/// ユーザー名ではないパス（投稿・共有ボタン・サービス自身のアカウントなど）。
const reservedSnsPaths = {
  SnsPlatform.instagram: {
    'explore', 'p', 'reel', 'reels', 'stories', 'tv', 'accounts', 'about', 'developer', 'legal', 'direct', //
    'web', 'static', 'embed', 'oauth', 'share', 'sharer', 'intent', 'instagram', 'privacy', 'terms', 'press',
  },
  SnsPlatform.x: {
    'share', 'intent', 'home', 'search', 'hashtag', 'i', 'widgets', 'widgets.js', 'login', 'signup', 'tos', //
    'privacy', 'messages', 'notifications', 'compose', 'settings', 'explore', 'twitter', 'x', 'about', 'jobs',
    'download', 'oauth', 'account', 'help', 'status', 'statuses', 'personalization', 'rules',
  },
  SnsPlatform.facebook: {
    'sharer', 'sharer.php', 'share', 'share.php', 'plugins', 'dialog', 'tr', 'login', 'login.php', 'help', //
    'policies', 'privacy', 'policy', 'policy.php', 'legal', 'about', 'facebook', 'watch', 'events', 'marketplace',
    'gaming', 'business', 'ads', 'hashtag', 'photo', 'photo.php', 'photos', 'video', 'video.php', 'story.php',
    'permalink.php', 'home.php', 'l.php', 'search', 'media', 'notes', 'reel', 'reels', 'share_channel',
    'recover', 'r.php', 'campaign', 'careers', 'terms', 'fbml', 'x', 'connect', 'v2.0', 'v3.0', 'u', 'pg',
    'messages', 'settings', 'whitehat', 'directory', 'pages', 'people', 'groups', 'profile.php',
  },
  SnsPlatform.tiktok: {'tiktok'},
  SnsPlatform.threads: {'threads'},
};

final _fileName = RegExp(r'\.(js|php|html?|css|png|jpe?g|gif|svg|webp|ico|json|xml)$', caseSensitive: false);

const _hosts = {
  'instagram.com': SnsPlatform.instagram, 'www.instagram.com': SnsPlatform.instagram, //
  'm.instagram.com': SnsPlatform.instagram, 'instagr.am': SnsPlatform.instagram,
  'twitter.com': SnsPlatform.x, 'www.twitter.com': SnsPlatform.x, 'mobile.twitter.com': SnsPlatform.x,
  'm.twitter.com': SnsPlatform.x, 'x.com': SnsPlatform.x, 'www.x.com': SnsPlatform.x, 'mobile.x.com': SnsPlatform.x,
  'facebook.com': SnsPlatform.facebook, 'www.facebook.com': SnsPlatform.facebook,
  'm.facebook.com': SnsPlatform.facebook, 'web.facebook.com': SnsPlatform.facebook,
  'mobile.facebook.com': SnsPlatform.facebook, 'fb.com': SnsPlatform.facebook, 'www.fb.com': SnsPlatform.facebook,
  'fb.me': SnsPlatform.facebook,
  'tiktok.com': SnsPlatform.tiktok, 'www.tiktok.com': SnsPlatform.tiktok, 'm.tiktok.com': SnsPlatform.tiktok,
  'youtube.com': SnsPlatform.youtube, 'www.youtube.com': SnsPlatform.youtube, 'm.youtube.com': SnsPlatform.youtube,
  'line.me': SnsPlatform.line, 'page.line.me': SnsPlatform.line, 'lin.ee': SnsPlatform.line,
  'threads.net': SnsPlatform.threads, 'www.threads.net': SnsPlatform.threads, 'threads.com': SnsPlatform.threads,
  'www.threads.com': SnsPlatform.threads,
  'bsky.app': SnsPlatform.bluesky,
};
final _facebookLocale = RegExp(r'^[a-z]{2}-[a-z]{2}\.facebook\.com$');

SnsPlatform? _platformOfHost(String host) {
  host = host.toLowerCase();
  if (_facebookLocale.hasMatch(host)) return SnsPlatform.facebook;
  return _hosts[host];
}

bool _validUser(SnsPlatform platform, String name) {
  final lower = name.toLowerCase();
  if ((reservedSnsPaths[platform]?.contains(lower) ?? false) || _fileName.hasMatch(lower) || lower.startsWith('.')) {
    return false;
  }
  return _userPatterns[platform]?.hasMatch(name) ?? false;
}

/// SNS のプロフィール URL ならアカウントを返す。投稿や共有ボタンなどは null。
SocialLink? parseSnsUrl(String raw, [SnsSource source = SnsSource.osm]) {
  try {
    return _parseSnsUrl(raw, source);
  } on FormatException {
    return null;
  } on ArgumentError {
    return null; // 壊れた %xx など
  }
}

SocialLink? _parseSnsUrl(String raw, SnsSource source) {
  var url = raw.trim().replaceAll('&amp;', '&');
  if (!url.contains('//')) url = 'https://${url.replaceFirst(RegExp('^/+'), '')}';
  final uri = Uri.parse(url);
  final platform = _platformOfHost(uri.host);
  if (platform == null) return null;
  var path = uri.path;
  if (uri.query.isEmpty && path.contains('&')) path = path.substring(0, path.indexOf('&'));
  if (uri.fragment.startsWith('!/')) path = uri.fragment.substring(1); // twitter.com/#!/name
  final segs = [
    for (final s in path.split('/'))
      if (s.isNotEmpty) Uri.decodeComponent(s),
  ];
  if (segs.isEmpty) return null;
  final first = segs.first;
  SocialLink link(String id) => SocialLink(platform, id, source);

  switch (platform) {
    case SnsPlatform.instagram:
      if (first.toLowerCase() == 'explore' && segs.length >= 3 && segs[1].toLowerCase() == 'locations') {
        return link('https://www.instagram.com/${segs.take(4).join('/')}/');
      }
      return _validUser(platform, first) ? link(first) : null;
    case SnsPlatform.x || SnsPlatform.tiktok || SnsPlatform.threads:
      final at = first.startsWith('@');
      if (platform != SnsPlatform.x && !at) return null; // tiktok.com/@name と threads.net/@name だけがプロフィール
      final name = at ? first.substring(1) : first;
      return _validUser(platform, name) ? link(name) : null;
    case SnsPlatform.facebook:
      final lower = first.toLowerCase();
      if (lower == 'profile.php') {
        final id = uri.queryParameters['id'];
        return id != null && RegExp(r'^\d+$').hasMatch(id)
            ? link('https://www.facebook.com/profile.php?id=$id')
            : null;
      }
      if ((lower == 'pages' || lower == 'people') && segs.length >= 3 && RegExp(r'^\d+$').hasMatch(segs[2])) {
        return link('https://www.facebook.com/${segs.take(3).join('/')}');
      }
      if (lower == 'groups' && segs.length >= 2) return link('https://www.facebook.com/groups/${segs[1]}');
      if (lower.endsWith('.php')) return null;
      return _validUser(platform, first) ? link(first) : null;
    case SnsPlatform.youtube:
      final lower = first.toLowerCase();
      if (RegExp(r'^@[A-Za-z0-9._\-]{3,30}$').hasMatch(first) && lower != '@youtube') return link(first);
      if (lower == 'channel' && segs.length >= 2 && RegExp(r'^UC[A-Za-z0-9_\-]{22}$').hasMatch(segs[1])) {
        return link('channel/${segs[1]}');
      }
      if ((lower == 'c' || lower == 'user') && segs.length >= 2 && RegExp(r'^[^\s/?#]{1,100}$').hasMatch(segs[1])) {
        return link('$lower/${segs[1]}');
      }
      return null;
    case SnsPlatform.line:
      final host = uri.host.toLowerCase();
      if (host == 'lin.ee') return RegExp(r'^[A-Za-z0-9]{4,}$').hasMatch(first) ? link('https://lin.ee/$first') : null;
      if (host == 'page.line.me') {
        return RegExp(r'^@?[A-Za-z0-9._\-]{2,30}$').hasMatch(first)
            ? link('@${first.replaceFirst('@', '')}')
            : null;
      }
      final tail = first == 'R' ? segs.sublist(1) : segs; // line.me/R/ti/p/@id
      if (tail.length >= 3 && tail[0] == 'ti' && tail[1] == 'p' && RegExp(r'^@[A-Za-z0-9._\-]{2,30}$').hasMatch(tail[2])) {
        return link(tail[2]);
      }
      return null;
    case SnsPlatform.bluesky:
      return first == 'profile' && segs.length >= 2 && _validUser(platform, segs[1]) ? link(segs[1]) : null;
  }
}

/// OSM タグの値（ユーザー名・@付き・URL・`;` 区切りの複数値）を解釈する。
List<SocialLink> parseSnsTag(SnsPlatform platform, String raw) {
  final found = <SocialLink>[];
  for (final part in raw.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
    if (part.contains('/') || part.toLowerCase().startsWith('http')) {
      if (parseSnsUrl(part) case final link?) found.add(link);
      continue;
    }
    final name = part.startsWith('@') ? part.substring(1) : part;
    switch (platform) {
      case SnsPlatform.line:
        if (RegExp(r'^[A-Za-z0-9._\-]{2,30}$').hasMatch(name)) found.add(SocialLink(platform, '@$name'));
      case SnsPlatform.youtube:
        if (RegExp(r'^UC[A-Za-z0-9_\-]{22}$').hasMatch(name)) {
          found.add(SocialLink(platform, 'channel/$name'));
        } else if (RegExp(r'^[A-Za-z0-9._\-]{3,30}$').hasMatch(name)) {
          found.add(SocialLink(platform, '@$name'));
        }
      default:
        if (_validUser(platform, name)) found.add(SocialLink(platform, name));
    }
  }
  return found;
}

/// OSM のタグから SNS アカウントを集める（`website` に SNS の URL が書かれている場合も含む）。
List<SocialLink> socialFromTags(Map<String, dynamic> tags) {
  final found = <SocialLink>[
    for (final MapEntry(key: platform, value: keys) in snsTagKeys.entries)
      for (final key in keys)
        if (tags[key] case final String value) ...parseSnsTag(platform, value),
    for (final key in ['website', 'contact:website', 'url'])
      if (tags[key] case final String value)
        for (final part in value.split(';')) ?parseSnsUrl(part),
  ];
  return dedupeLinks(found);
}

final _snsInHtml = RegExp(
  r'''//((?:[a-z0-9-]+\.)*(?:instagram\.com|instagr\.am|twitter\.com|x\.com|facebook\.com|fb\.com|tiktok\.com'''
  r'''|youtube\.com|line\.me|lin\.ee|threads\.net|threads\.com|bsky\.app))(?=[/?#"'\s<>\\]|$)([^\s"'<>()\\]*)''',
  caseSensitive: false,
);

/// Web ページから SNS のプロフィールへのリンクを抜き出す（同じサービスは最大 [perPlatform] 件）。
List<SocialLink> socialFromHtml(String html, {int perPlatform = 3}) {
  final text = html
      .replaceAll(r'\/', '/')
      .replaceAll(RegExp('%3a', caseSensitive: false), ':')
      .replaceAll(RegExp('%2f', caseSensitive: false), '/');
  final counts = <SnsPlatform, int>{};
  final found = <SocialLink>[];
  var pos = 0;
  while (pos < text.length) {
    final m = _snsInHtml.allMatches(text, pos).firstOrNull;
    if (m == null) break;
    // 共有ボタンの ?href=https://facebook.com/xxx のような入れ子の URL も拾えるよう、ホスト名の直後から探し直す
    pos = m.start + 2 + m.group(1)!.length;
    final link = parseSnsUrl('https://${m.group(1)}${m.group(2)}', SnsSource.website);
    if (link == null || (counts[link.platform] ?? 0) >= perPlatform || found.contains(link)) continue;
    counts[link.platform] = (counts[link.platform] ?? 0) + 1;
    found.add(link);
  }
  return found;
}

List<SocialLink> dedupeLinks(Iterable<SocialLink> links) {
  final seen = <String>{};
  return [
    for (final l in links)
      if (seen.add(l.key)) l,
  ];
}
