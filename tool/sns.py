"""SNS アカウントの URL・タグ値の解釈（lib/models/social.dart と同じ規則）。

アカウントは (platform, id) の組で表す。id はユーザー名（@ なし）か、
ユーザー名で表せないもの（Facebook の profile.php など）は URL そのもの。
"""

from __future__ import annotations

import re
from urllib.parse import unquote, urlsplit

PLATFORMS = ('instagram', 'x', 'facebook', 'tiktok', 'youtube', 'line', 'threads', 'bluesky')

# OSM でアカウントを記録するタグ（先にあるものを優先）
TAG_KEYS = {
    'instagram': ('contact:instagram', 'instagram'),
    'x': ('contact:x', 'contact:twitter', 'twitter'),
    'facebook': ('contact:facebook', 'facebook'),
    'tiktok': ('contact:tiktok', 'tiktok'),
    'youtube': ('contact:youtube', 'youtube'),
    'line': ('contact:line',),
    'threads': ('contact:threads',),
    'bluesky': ('contact:bluesky', 'bluesky'),
}
ALL_TAG_KEYS = tuple(k for keys in TAG_KEYS.values() for k in keys)

_USER = {
    'instagram': re.compile(r'^[A-Za-z0-9._]{1,30}$'),
    'x': re.compile(r'^[A-Za-z0-9_]{1,15}$'),
    'facebook': re.compile(r'^[A-Za-z0-9.\-]{2,80}$'),
    'tiktok': re.compile(r'^[A-Za-z0-9._]{2,24}$'),
    'threads': re.compile(r'^[A-Za-z0-9._]{1,30}$'),
    'bluesky': re.compile(r'^(?:[A-Za-z0-9.\-]{3,253}\.[A-Za-z]{2,}|did:[a-z]+:[A-Za-z0-9._:%\-]{4,200})$'),
}

# ユーザー名ではないパス（投稿・共有ボタン・公式アカウント自身など）
RESERVED = {
    'instagram': {
        'explore', 'p', 'reel', 'reels', 'stories', 'tv', 'accounts', 'about', 'developer', 'legal', 'direct',
        'web', 'static', 'embed', 'oauth', 'share', 'sharer', 'intent', 'instagram', 'privacy', 'terms', 'press',
    },
    'x': {
        'share', 'intent', 'home', 'search', 'hashtag', 'i', 'widgets', 'widgets.js', 'login', 'signup', 'tos',
        'privacy', 'messages', 'notifications', 'compose', 'settings', 'explore', 'twitter', 'x', 'about', 'jobs',
        'download', 'oauth', 'account', 'help', 'status', 'statuses', 'personalization', 'rules',
    },
    'facebook': {
        'sharer', 'sharer.php', 'share', 'share.php', 'plugins', 'dialog', 'tr', 'login', 'login.php', 'help',
        'policies', 'privacy', 'policy', 'policy.php', 'legal', 'about', 'facebook', 'watch', 'events', 'marketplace',
        'gaming', 'business', 'ads', 'hashtag', 'photo', 'photo.php', 'photos', 'video', 'video.php', 'story.php',
        'permalink.php', 'home.php', 'l.php', 'search', 'media', 'notes', 'reel', 'reels', 'share_channel',
        'recover', 'r.php', 'campaign', 'careers', 'terms', 'fbml', 'x', 'connect', 'v2.0', 'v3.0', 'u', 'pg',
        'messages', 'settings', 'whitehat', 'directory', 'pages', 'people', 'groups', 'profile.php',
    },
    'tiktok': {'tiktok'},
    'threads': {'threads'},
    'youtube': {'@youtube'},
}

_FILE = re.compile(r'\.(js|php|html?|css|png|jpe?g|gif|svg|webp|ico|json|xml)$', re.I)

# プロフィールを表示するホスト名（developers.facebook.com や help.instagram.com などは除く）
_HOSTS = {
    'instagram.com': 'instagram', 'www.instagram.com': 'instagram', 'm.instagram.com': 'instagram',
    'instagr.am': 'instagram',
    'twitter.com': 'x', 'www.twitter.com': 'x', 'mobile.twitter.com': 'x', 'm.twitter.com': 'x',
    'x.com': 'x', 'www.x.com': 'x', 'mobile.x.com': 'x',
    'facebook.com': 'facebook', 'www.facebook.com': 'facebook', 'm.facebook.com': 'facebook',
    'web.facebook.com': 'facebook', 'mobile.facebook.com': 'facebook', 'fb.com': 'facebook',
    'www.fb.com': 'facebook', 'fb.me': 'facebook',
    'tiktok.com': 'tiktok', 'www.tiktok.com': 'tiktok', 'm.tiktok.com': 'tiktok',
    'youtube.com': 'youtube', 'www.youtube.com': 'youtube', 'm.youtube.com': 'youtube',
    'line.me': 'line', 'page.line.me': 'line', 'lin.ee': 'line',
    'threads.net': 'threads', 'www.threads.net': 'threads', 'threads.com': 'threads', 'www.threads.com': 'threads',
    'bsky.app': 'bluesky',
}
_FACEBOOK_LOCALE = re.compile(r'^[a-z]{2}-[a-z]{2}\.facebook\.com$')

# HTML 中の SNS への URL（// の直後がホスト名のものだけ）
_SNS_IN_HTML = re.compile(
    r'//((?:[a-z0-9-]+\.)*(?:instagram\.com|instagr\.am|twitter\.com|x\.com|facebook\.com|fb\.com|tiktok\.com'
    r'|youtube\.com|line\.me|lin\.ee|threads\.net|threads\.com|bsky\.app))(?=[/?#"\'\s<>\\]|$)([^\s"\'<>()\\]*)',
    re.I,
)


def _platform_of_host(host: str) -> str | None:
    host = host.lower().rstrip('.')
    if _FACEBOOK_LOCALE.match(host):  # ja-jp.facebook.com など
        return 'facebook'
    return _HOSTS.get(host)


def _valid_user(platform: str, name: str) -> bool:
    lower = name.lower()
    if lower in RESERVED.get(platform, ()) or _FILE.search(lower) or lower.startswith('.'):
        return False
    pattern = _USER.get(platform)
    return bool(pattern and pattern.match(name))


def parse_url(url: str) -> tuple[str, str] | None:
    """SNS のプロフィール URL なら (platform, id)。投稿や共有リンクなどは None。"""
    url = url.strip().replace('&amp;', '&')
    if '//' not in url:
        url = 'https://' + url.lstrip('/')
    try:
        parts = urlsplit(url)
    except ValueError:
        return None
    platform = _platform_of_host(parts.hostname or '')
    if platform is None:
        return None
    path = parts.path
    if not parts.query and '&' in path:  # ?href= に埋め込まれた URL の続き（&tabs=... など）を除く
        path = path.split('&', 1)[0]
    if parts.fragment.startswith('!/'):  # twitter.com/#!/name
        path = parts.fragment[1:]
    segs = [unquote(s) for s in path.split('/') if s]
    if not segs:
        return None
    first = segs[0]

    if platform == 'instagram':
        if first.lower() == 'explore' and len(segs) >= 3 and segs[1].lower() == 'locations':
            return platform, 'https://www.instagram.com/' + '/'.join(segs[:4]) + '/'
        return (platform, first) if _valid_user(platform, first) else None
    if platform in ('x', 'tiktok', 'threads'):
        name = first[1:] if first.startswith('@') else first
        if platform != 'x' and not first.startswith('@'):
            return None  # tiktok.com/@name と threads.net/@name だけがプロフィール
        return (platform, name) if _valid_user(platform, name) else None
    if platform == 'facebook':
        lower = first.lower()
        if lower == 'profile.php':
            m = re.search(r'(?:^|&)id=(\d+)', parts.query)
            return (platform, f'https://www.facebook.com/profile.php?id={m.group(1)}') if m else None
        if lower in ('pages', 'people') and len(segs) >= 3 and segs[2].isdigit():
            return platform, 'https://www.facebook.com/' + '/'.join(segs[:3])
        if lower == 'groups' and len(segs) >= 2:
            return platform, 'https://www.facebook.com/groups/' + segs[1]
        if lower.endswith('.php'):
            return None
        return (platform, first) if _valid_user(platform, first) else None
    if platform == 'youtube':
        lower = first.lower()
        if first.startswith('@') and re.match(r'^@[A-Za-z0-9._\-]{3,30}$', first) and lower != '@youtube':
            return platform, first
        if lower == 'channel' and len(segs) >= 2 and re.match(r'^UC[A-Za-z0-9_\-]{22}$', segs[1]):
            return platform, 'channel/' + segs[1]
        if lower in ('c', 'user') and len(segs) >= 2 and re.match(r'^[^\s/?#]{1,100}$', segs[1]):
            return platform, f'{lower}/{segs[1]}'
        return None
    if platform == 'line':
        host = (parts.hostname or '').lower()
        if host == 'lin.ee':
            return (platform, f'https://lin.ee/{first}') if re.match(r'^[A-Za-z0-9]{4,}$', first) else None
        if host == 'page.line.me':
            return (platform, '@' + first.lstrip('@')) if re.match(r'^@?[A-Za-z0-9._\-]{2,30}$', first) else None
        # line.me/R/ti/p/@id, line.me/ti/p/@id
        tail = segs[1:] if first == 'R' else segs
        if len(tail) >= 3 and tail[0] == 'ti' and tail[1] == 'p' and re.match(r'^@[A-Za-z0-9._\-]{2,30}$', tail[2]):
            return platform, tail[2]
        return None
    if platform == 'bluesky':
        if first == 'profile' and len(segs) >= 2 and _valid_user(platform, segs[1]):
            return platform, segs[1]
        return None
    return None


def parse_tag(platform: str, raw: str) -> list[tuple[str, str]]:
    """OSM タグの値（ユーザー名・@付き・URL・; 区切りの複数値）を解釈する。"""
    found: list[tuple[str, str]] = []
    for part in (p.strip() for p in raw.split(';')):
        if not part:
            continue
        if '/' in part or part.lower().startswith('http'):
            link = parse_url(part)
            if link:
                found.append(link)
            continue
        name = part[1:] if part.startswith('@') else part
        if platform == 'line':
            if re.match(r'^[A-Za-z0-9._\-]{2,30}$', name):
                found.append((platform, '@' + name))
        elif platform == 'youtube':
            if re.match(r'^UC[A-Za-z0-9_\-]{22}$', name):
                found.append((platform, 'channel/' + name))
            elif re.match(r'^[A-Za-z0-9._\-]{3,30}$', name):
                found.append((platform, '@' + name))
        elif _valid_user(platform, name):
            found.append((platform, name))
    return found


def from_tags(tags) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for platform, keys in TAG_KEYS.items():
        for key in keys:
            value = tags.get(key)
            if value:
                found.extend(parse_tag(platform, value))
    # website に SNS の URL が書かれていることもある
    for key in ('website', 'contact:website', 'url'):
        value = tags.get(key)
        if value:
            for part in value.split(';'):
                link = parse_url(part)
                if link:
                    found.append(link)
    return dedupe(found)


def find_urls(html: str, limit: int = 60) -> list[str]:
    """Web ページに含まれる SNS ドメインへの URL（解釈する前のもの）。"""
    html = html.replace('\\/', '/').replace('%3A', ':').replace('%3a', ':').replace('%2F', '/').replace('%2f', '/')
    urls: list[str] = []
    seen: set[str] = set()
    pos = 0
    while (m := _SNS_IN_HTML.search(html, pos)) and len(urls) < limit:
        # 共有ボタンの ?href=https://facebook.com/xxx のような入れ子の URL も拾えるよう、ホスト名の直後から探し直す
        pos = m.end(1)
        url = 'https://' + m.group(1) + m.group(2)
        if url.lower() not in seen:
            seen.add(url.lower())
            urls.append(url)
    return urls


def from_urls(urls, per_platform: int = 3) -> list[tuple[str, str]]:
    """URL の一覧から SNS のプロフィールを取り出す（同じサービスは最大 per_platform 件）。"""
    counts: dict[str, int] = {}
    found: list[tuple[str, str]] = []
    seen: set[str] = set()
    for url in urls:
        link = parse_url(url)
        if not link or counts.get(link[0], 0) >= per_platform or key(link) in seen:
            continue
        counts[link[0]] = counts.get(link[0], 0) + 1
        seen.add(key(link))
        found.append(link)
    return found


def from_html(html: str, per_platform: int = 3) -> list[tuple[str, str]]:
    """Web ページから SNS のプロフィールへのリンクを抜き出す。"""
    return from_urls(find_urls(html), per_platform)


def key(link: tuple[str, str]) -> str:
    return f'{link[0]}:{link[1].lower()}'


def dedupe(links) -> list[tuple[str, str]]:
    seen: set[str] = set()
    out = []
    for link in links:
        if key(link) not in seen:
            seen.add(key(link))
            out.append(link)
    return out
