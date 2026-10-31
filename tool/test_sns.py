"""tool/sns.py の確認（test/widget_test.dart の SNS の確認と同じ内容）。  python tool/test_sns.py"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import sns  # noqa: E402


def check(actual, expected):
    assert actual == expected, f'\n  expected: {expected}\n  actual:   {actual}'


check(sns.parse_tag('instagram', 'hobgoblinshibuya'), [('instagram', 'hobgoblinshibuya')])
check(sns.parse_tag('instagram', '@tasuichi.shibuya'), [('instagram', 'tasuichi.shibuya')])
check(sns.parse_tag('instagram', 'https://www.instagram.com/mepicabari/?hl=ja'), [('instagram', 'mepicabari')])
check(sns.parse_tag('instagram', 'bar_trench;https://instagram.com/explore/locations/2432706/bar-trench'),
      [('instagram', 'bar_trench'),
       ('instagram', 'https://www.instagram.com/explore/locations/2432706/bar-trench/')])

check(sns.from_tags({
    'contact:twitter': 'https://twitter.com/#!/oldname',
    'contact:facebook': 'https://www.facebook.com/profile.php?id=1234&ref=x',
    'contact:tiktok': '@cafe.abc',
    'contact:youtube': 'UCabcdefghijklmnopqrstuv',
    'contact:line': '@shop1',
    'contact:threads': 'cafe_abc',
    'website': 'https://www.instagram.com/cafe_web/',
}), [
    ('x', 'oldname'),
    ('facebook', 'https://www.facebook.com/profile.php?id=1234'),
    ('tiktok', 'cafe.abc'),
    ('youtube', 'channel/UCabcdefghijklmnopqrstuv'),
    ('line', '@shop1'),
    ('threads', 'cafe_abc'),
    ('instagram', 'cafe_web'),
])

for url in ('https://example.com/foo', 'https://twitter.com/share?url=x', 'https://graph.facebook.com/v25.0/x',
            'https://www.youtube.com/watch?v=1', 'https://www.fedex.com/abc'):
    check(sns.parse_url(url), None)

HTML = r'''
  <a href="https://www.instagram.com/test_school_official/">Instagram</a>
  <a href="https://instagram.com/test_school_official">dup</a>
  <a href="https://www.instagram.com/p/AbC123/">post</a>
  <script src="//www.instagram.com/embed.js"></script>
  <a href="https://www.instagram.com/test_club.basketball?igsh=xyz">club</a>
  <a href="https://twitter.com/share?url=x">share</a><a href="https://x.com/cafe_abc">x</a>
  <iframe src="https://www.facebook.com/plugins/page.php?href=https%3A%2F%2Fwww.facebook.com%2Fcafeabc.page&tabs=timeline"></iframe>
  <a href="https://line.me/R/ti/p/%40abc123">line</a> <script>var u = "https:\/\/www.tiktok.com\/@cafe.abc";</script>
'''
check(sns.from_html(HTML), [
    ('instagram', 'test_school_official'),
    ('instagram', 'test_club.basketball'),
    ('x', 'cafe_abc'),
    ('facebook', 'cafeabc.page'),
    ('line', '@abc123'),
    ('tiktok', 'cafe.abc'),
])

print('sns.py: all checks passed')
