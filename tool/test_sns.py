"""tool/sns.py と build_data.classify の確認（test/widget_test.dart と同じ内容）。  python tool/test_sns.py"""

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

# カテゴリの判定（test/widget_test.dart の classify と同じ例）
import build_data  # noqa: E402

CLASSIFY_CASES = [
    ({'amenity': 'college'}, '日本電子専門学校', {'vocational'}),
    ({'amenity': 'college'}, '日本デザイナー学院', {'vocational'}),
    ({'amenity': 'school'}, '東京都立産業技術高等専門学校', {'vocational'}),
    ({'amenity': 'college'}, '武蔵野短期大学', {'university'}),
    ({'amenity': 'college'}, '千葉県警察学校', set()),
    ({'building': 'yes'}, '日本電子専門学校 7号館', set()),
    ({'amenity': 'kindergarten'}, '越谷保育専門学校附属幼稚園', set()),
    ({'amenity': 'university'}, '放送大学東京多摩学習センター', {'university', 'correspondence'}),
    ({'building': 'yes'}, '放送大学学園放送大学埼玉学習センター', {'correspondence'}),
    ({'amenity': 'university'}, '電気通信大学', {'university'}),
    ({'amenity': 'school'}, 'クラーク記念国際高等学校 さいたまキャンパス', {'highSchool', 'correspondence'}),
    ({'amenity': 'school'}, 'N高等学校', {'highSchool', 'correspondence'}),
    ({'amenity': 'college'}, 'KTCおおぞら高等学院厚木キャンパス', {'correspondence'}),
    ({'amenity': 'college'}, 'ゼロ高等学院', {'correspondence'}),
    ({'amenity': 'school'}, '私立早稲田大学本庄高等学院', set()),
    ({'amenity': 'college'}, '湘南ゼミナール', set()),
    ({'amenity': 'college'}, '君津商業高等学校', set()),
    ({'amenity': 'school'}, '早稲田大学高等学院', set()),
    ({'amenity': 'community_centre'}, '渋谷学習センター', set()),
    ({'amenity': 'restaurant', 'cuisine': 'ramen'}, '麺屋はるか', {'restaurant'}),
    ({'amenity': 'cafe'}, 'カフェ・ド・ポン', {'restaurant'}),
    ({'shop': 'bakery'}, 'ベーカリー麦', {'restaurant'}),
    ({'shop': 'hairdresser'}, 'HAIR SALON A', {'beauty'}),
    ({'shop': 'beauty'}, 'ネイルサロン B', {'beauty'}),
    ({'shop': 'beauty'}, 'メンズエステ C', set()),
    ({'amenity': 'school', 'isced:level': '3'}, '県立第一', {'highSchool'}),
    ({'amenity': 'social_facility'}, '市ボランティアセンター', {'volunteer'}),
    ({'historic': 'castle'}, '佐倉城', {'historic'}),
    ({'historic': 'archaeological_site'}, '明戸古墳', {'historic'}),
    ({'historic': 'memorial'}, '忠霊塔', set()),
    ({'historic': 'memorial', 'wikidata': 'Q1'}, '二・二六事件慰霊像', {'historic'}),
    ({'amenity': 'place_of_worship', 'wikidata': 'Q2'}, '浅草寺', {'historic'}),
    ({'amenity': 'place_of_worship'}, '神明社', set()),
    ({'heritage': '2', 'man_made': 'bridge'}, '一石橋', {'historic'}),
    ({'office': 'company'}, '株式会社テスト', {'company'}),
    ({'office': 'company'}, '佐川急便 千葉南営業所', set()),
    ({'building': 'yes'}, 'ホーチキ本社', {'company'}),
    ({'amenity': 'restaurant'}, 'ラーメン山田 本店', {'restaurant'}),
]
for tags, name, expected in CLASSIFY_CASES:
    check((name, build_data.classify(tags, name)), (name, expected))

# チェーン店に付ける近くの地名
areas = build_data.AreaIndex([(35.3400, 139.6200, '六浦'), (35.3500, 139.6300, '金沢八景'), (35.40, 139.70, '遠く')])
check(areas.nearest(35.3402, 139.6203), '六浦')
check(areas.nearest(35.3490, 139.6290), '金沢八景')
check(areas.nearest(35.2000, 139.5000), None)
check(build_data.CHOME.sub('', '六浦二丁目'), '六浦')
check(build_data.CHOME.sub('', '六浦東1丁目'), '六浦東')

print('sns.py, classify, area: all checks passed')
