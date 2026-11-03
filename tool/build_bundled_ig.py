#!/usr/bin/env python3
"""配信データ（GitHub Pages またはローカルの --src）から、東京都・神奈川県エリアの
Instagram アカウント付きスポットだけを抜き出してアプリ同梱用の圧縮 JSON を作る。

    python tool/build_bundled_ig.py
"""

from __future__ import annotations

import argparse
import gzip
import json
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

DEFAULT_BASE = 'https://pg-darksan.github.io/nearby_insta/data/v1'
UA = 'nearby_insta-databot/1.0 (+https://github.com/PG-Darksan/nearby_insta)'

# 東京都（23区・多摩・伊豆諸島・小笠原諸島）と神奈川県全域をカバーする 0.1 度タイルの範囲
# 本土側: 緯度 35.10〜35.90, 経度 138.90〜139.95
# 島しょ部: 緯度 24.00〜34.85, 経度 139.10〜142.30
OTHER_PREFS = ('埼玉県', '千葉県', '山梨県', '静岡県')


def in_tokyo_kanagawa_bbox(tile_key: str) -> bool:
    y, x = (int(v) for v in tile_key.split('_'))
    lat = y * 0.1
    lon = x * 0.1
    if 35.10 <= lat <= 35.90 and 138.90 <= lon <= 139.95:
        return True
    if 24.00 <= lat <= 34.85 and 139.10 <= lon <= 142.30:
        return True
    return False


def is_other_prefecture(el: dict) -> bool:
    tags = el.get('tags') or {}
    prov = tags.get('addr:province') or ''
    full = tags.get('addr:full') or ''
    if prov and prov not in ('東京都', '神奈川県', '東京', '神奈川'):
        return True
    if any(full.startswith(p) for p in OTHER_PREFS):
        return True
    # 島しょ部バウンディングボックスに入る静岡県伊豆半島（経度 < 139.20 かつ 緯度 >= 34.55）を除外
    lat, lon = el.get('lat', 0.0), el.get('lon', 0.0)
    if lat < 35.10 and lat >= 34.55 and lon < 139.22:
        return True
    return False


def fetch_json(base: str, rel: str) -> dict:
    if base.startswith(('http://', 'https://')):
        req = urllib.request.Request(f'{base.rstrip("/")}/{rel}', headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=20) as res:
            return json.loads(res.read().decode('utf-8'))
    return json.loads((Path(base) / rel).read_text(encoding='utf-8'))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--src', default=DEFAULT_BASE)
    ap.add_argument('--out', default='assets/data/tokyo_kanagawa_instagram.bin')
    args = ap.parse_args()

    meta = fetch_json(args.src, 'meta.json')
    target_tiles = sorted(t for t in meta['tiles'] if in_tokyo_kanagawa_bbox(t))

    def load_tile(key: str):
        data = fetch_json(args.src, f't/{key}.json')
        ig_elements = []
        for el in data.get('elements', ()):
            sns_list = el.get('sns') or []
            if not any(s and s[0] == 'instagram' for s in sns_list):
                continue
            if is_other_prefecture(el):
                continue
            ig_elements.append(el)
        return key, ig_elements

    with ThreadPoolExecutor(16) as pool:
        results = list(pool.map(load_tile, target_tiles))

    tiles_map = {k: els for k, els in results if els}
    total_spots = sum(len(els) for els in tiles_map.values())

    payload = {
        'format': 1,
        'generated': meta['generated'],
        'tileDeg': meta['tileDeg'],
        'region': 'tokyo_kanagawa',
        'spotCount': total_spots,
        'tiles': tiles_map,
    }
    raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    compressed = gzip.compress(raw, compresslevel=9, mtime=0)
    out_path.write_bytes(compressed)
    print(f'Wrote {out_path} ({len(tiles_map)} tiles, {total_spots} Instagram spots, '
          f'raw {len(raw)/1024:.1f} KB -> gzip {len(compressed)/1024:.1f} KB)')


if __name__ == '__main__':
    main()
