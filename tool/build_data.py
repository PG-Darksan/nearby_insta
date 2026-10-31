#!/usr/bin/env python3
"""OSM の抽出データから、アプリがすぐに読み込める「近くのスポット」タイルを作る。

1. OSM（Geofabrik の .osm.pbf）から、SNS アカウントのタグがある場所・高校・大学・
   ボランティア/体験施設・Web サイトのあるお店や施設を取り出す
2. Wikidata と各施設の公式サイトに載っている SNS アカウントを探す
   （結果は --cache に保存し、次回は期限切れのものだけ確認し直す）
3. 0.1 度ごとのタイル（JSON）と meta.json を --out に書き出す

    python tool/build_data.py japan-latest.osm.pbf --out site/data/v1 --cache cache
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from urllib import robotparser
from urllib.parse import urljoin, urlsplit, urlunsplit

import osmium

import sns

UA = 'nearby_insta-databot/1.0 (+https://github.com/PG-Darksan/nearby_insta)'
TILE_DEG = 0.1
FORMAT = 1

# 道路・駅・行政区域などは対象外
EXCLUDE_KEYS = ('highway', 'public_transport', 'railway', 'boundary', 'place', 'landuse', 'natural', 'waterway',
                'route', 'power', 'barrier', 'aeroway', 'admin_level')
# お店・施設らしいもの
POI_KEYS = ('amenity', 'shop', 'office', 'craft', 'tourism', 'leisure', 'healthcare', 'club', 'historic', 'sport',
            'building')
# 運営会社のサイトしか載っていないことが多いもの
SKIP_AMENITY = {
    'parking', 'parking_entrance', 'parking_space', 'bicycle_parking', 'motorcycle_parking', 'toilets', 'bench',
    'vending_machine', 'atm', 'post_box', 'waste_basket', 'waste_disposal', 'recycling', 'charging_station',
    'bicycle_rental', 'car_sharing', 'car_rental', 'telephone', 'drinking_water', 'shelter', 'taxi', 'fuel',
    'bus_station', 'ferry_terminal', 'loading_dock', 'compressed_air', 'water_point', 'fire_hydrant',
}
# アプリが使うタグだけを残す
KEEP_TAGS = (
    'name', 'name:ja', 'brand', 'amenity', 'shop', 'tourism', 'leisure', 'craft', 'office', 'club', 'healthcare',
    'isced:level', 'addr:full', 'addr:province', 'addr:city', 'addr:quarter', 'addr:neighbourhood',
    'addr:block_number', 'addr:street', 'addr:housenumber', 'website', 'contact:website', 'wikidata',
)

HIGH_SCHOOL = re.compile(r'高等学校|高校|中等教育学校|high school', re.I)
VOLUNTEER = re.compile(r'ボランティア|社会福祉協議会|市民活動|NPOセンター|volunteer', re.I)
EXPERIENCE = re.compile(r'体験|ワークショップ|workshop|陶芸', re.I)

# 口コミ・予約サイトや地図など、お店自身のサイトではないもの
SKIP_HOSTS = (
    'tabelog.com', 'hotpepper.jp', 'gnavi.co.jp', 'retty.me', 'google.com', 'google.co.jp', 'goo.gl',
    'maps.app.goo.gl', 'jalan.net', 'rakuten.co.jp', 'ekiten.jp', 'wikipedia.org', 'tripadvisor.com',
    'tripadvisor.jp', 'booking.com', 'expedia.co.jp', 'ikyu.com', 'yahoo.co.jp', 'navitime.co.jp',
    'mapion.co.jp', 'itp.ne.jp', 'amazon.co.jp', 'minkou.jp', 'epark.jp', 'openstreetmap.org',
)

WIKIDATA_PROPS = {
    'P2003': 'instagram', 'P2002': 'x', 'P2013': 'facebook', 'P7085': 'tiktok', 'P11245': 'youtube',
    'P2397': 'youtube', 'P11892': 'threads', 'P12361': 'bluesky',
}

# 同じサイト・リンクがこれ以上の地点（約 1km 四方の別々の区画）にあれば、チェーン店の本部サイトや
# 自治体サイト共通のフッターとみなす（学校などは同じ大学のキャンパス違いがあるので緩める）
SHARED_THRESHOLD = 6
SHARED_THRESHOLD_INSTITUTION = 15

# 成人向けの店は対象外
ADULT = {('amenity', 'brothel'), ('amenity', 'stripclub'), ('amenity', 'swingerclub'), ('amenity', 'love_hotel'),
         ('shop', 'erotic'), ('shop', 'adult')}

OSM_TYPES = {'n': 'node', 'w': 'way', 'r': 'relation'}


def log(*args):
    print(time.strftime('%H:%M:%S'), *args, flush=True)


def is_institution(tags: dict, name: str) -> bool:
    amenity = tags.get('amenity')
    isced = [s.strip() for s in re.split('[;,]', tags.get('isced:level', ''))]
    return bool(
        (amenity == 'school' and (HIGH_SCHOOL.search(name) or '3' in isced))
        or amenity == 'university'
        or (amenity == 'college' and '大学' in name)
        or VOLUNTEER.search(name)
        or EXPERIENCE.search(name)
        or tags.get('craft') in ('pottery', 'glassblower')
    )


def normalize_url(raw: str) -> str | None:
    raw = raw.split(';')[0].strip()
    if not raw or ' ' in raw:
        return None
    if '//' not in raw:
        raw = 'https://' + raw
    try:
        p = urlsplit(raw)
    except ValueError:
        return None
    if p.scheme not in ('http', 'https') or not p.hostname or '.' not in p.hostname:
        return None
    path = p.path or '/'
    return urlunsplit((p.scheme, p.netloc.lower(), path, p.query, ''))


def host_of(url: str) -> str:
    host = (urlsplit(url).hostname or '').lower()
    return host[4:] if host.startswith('www.') else host


def skip_host(host: str) -> bool:
    return any(host == h or host.endswith('.' + h) for h in SKIP_HOSTS) or sns._platform_of_host(host) is not None


# ---------------------------------------------------------------- 1. OSM から取り出す

class Candidate:
    __slots__ = ('type', 'id', 'tags', 'name', 'inst', 'chain', 'links', 'website', 'wikidata', 'lat', 'lon', 'refs',
                 'members')

    def __init__(self, otype, oid, tags, name, inst, chain, links, website, wikidata):
        self.type, self.id, self.tags, self.name, self.inst, self.chain = otype, oid, tags, name, inst, chain
        self.links = [(p, i, 'osm') for p, i in links]
        self.website, self.wikidata = website, wikidata
        self.lat = self.lon = None
        self.refs = None
        self.members = None

    def cell(self):
        return (round(self.lat, 2), round(self.lon, 2))


def extract(pbf: str):
    cands: list[Candidate] = []
    coverage: set[str] = set()
    fp = (osmium.FileProcessor(pbf)
          .with_filter(osmium.filter.KeyFilter('name', 'brand', *sns.ALL_TAG_KEYS))
          .with_filter(osmium.filter.KeyFilter(*POI_KEYS, *sns.ALL_TAG_KEYS, 'website', 'contact:website')))
    seen = 0
    for obj in fp:
        seen += 1
        otags = obj.tags
        if any(k in otags for k in EXCLUDE_KEYS):
            continue
        if obj.is_node():
            coverage.add(f'{math.floor(obj.location.lat)}_{math.floor(obj.location.lon)}')
        elif obj.is_relation() and otags.get('type') not in ('multipolygon', 'site', 'building'):
            continue
        tags = {t.k: t.v for t in otags}
        if any((k, tags.get(k)) in ADULT for k in ('amenity', 'shop')) or 'love_hotel' in tags:
            continue
        links = sns.from_tags(tags)
        name = tags.get('name:ja') or tags.get('name') or tags.get('brand') or (links[0][1] if links else None)
        if not name:
            continue
        inst = is_institution(tags, name)
        poi = any(k in tags for k in POI_KEYS) and tags.get('amenity') not in SKIP_AMENITY
        website = None
        for key in ('contact:website', 'website', 'url'):
            if tags.get(key):
                website = normalize_url(tags[key])
                if website and skip_host(host_of(website)):
                    website = None
                break
        wikidata = tags.get('wikidata') if re.match(r'^Q\d+$', tags.get('wikidata', '')) else None
        if not (links or inst or (poi and (website or wikidata))):
            continue
        cand = Candidate(OSM_TYPES[obj.type_str()], obj.id, {k: tags[k] for k in KEEP_TAGS if k in tags}, name, inst,
                         'brand' in tags or 'brand:wikidata' in tags, links, website, wikidata)
        if obj.is_node():
            cand.lat, cand.lon = obj.location.lat, obj.location.lon
        elif obj.is_way():
            cand.refs = [n.ref for n in obj.nodes]
        else:
            cand.members = [(m.type, m.ref) for m in obj.members if m.type in ('n', 'w')]
        cands.append(cand)
    log(f'OSM: {seen} 件を確認し、候補 {len(cands)} 件')

    # relation の構成要素の way を読み、必要なノードの位置をまとめて取得する
    member_ways = {ref for c in cands if c.members for t, ref in c.members if t == 'w'}
    way_refs: dict[int, list[int]] = {}
    if member_ways:
        for w in osmium.FileProcessor(pbf, osmium.osm.WAY).with_filter(osmium.filter.IdFilter(member_ways)):
            way_refs[w.id] = [n.ref for n in w.nodes]
    needed: set[int] = set()
    for c in cands:
        if c.refs:
            needed.update(c.refs)
        elif c.members:
            for t, ref in c.members:
                if t == 'n':
                    needed.add(ref)
                else:
                    needed.update(way_refs.get(ref, ()))
    locs: dict[int, tuple[float, float]] = {}
    if needed:
        for n in osmium.FileProcessor(pbf, osmium.osm.NODE).with_filter(osmium.filter.IdFilter(needed)):
            if n.location.valid():
                locs[n.id] = (n.location.lat, n.location.lon)
    del needed

    out = []
    for c in cands:
        if c.lat is None:
            ids = c.refs if c.refs else [
                r for t, ref in c.members for r in ((ref,) if t == 'n' else way_refs.get(ref, ()))]
            pts = [locs[i] for i in ids if i in locs]
            if not pts:
                continue
            # Overpass の `out center` と同じく外接矩形の中心
            lats, lons = [p[0] for p in pts], [p[1] for p in pts]
            c.lat, c.lon = (min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2
        c.refs = c.members = None
        out.append(c)
    return out, coverage


# ---------------------------------------------------------------- 2a. Wikidata

class JsonCache:
    def __init__(self, path: Path):
        self.path = path
        self.data = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
        self.lock = threading.Lock()

    def fresh(self, key: str, days: float) -> dict | None:
        entry = self.data.get(key)
        if not entry:
            return None
        # 一度に期限切れにならないよう、キーごとに期限を最大 25% ずらす
        jitter = int(hashlib.md5(key.encode()).hexdigest()[:4], 16) / 0xFFFF * 0.25
        return entry if time.time() - entry['t'] < days * (1 + jitter) * 86400 else None

    def put(self, key: str, value: dict):
        with self.lock:
            self.data[key] = {'t': int(time.time()), **value}

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps(self.data, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
        tmp.replace(self.path)


def http_get(url: str, timeout: float, max_bytes: int, accept: str = 'text/html,application/xhtml+xml'):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': accept, 'Accept-Language': 'ja,en;q=0.5'})
    with urllib.request.urlopen(req, timeout=timeout) as res:
        return res.status, res.geturl(), res.headers.get('Content-Type', ''), res.read(max_bytes)


def wikidata_lookup(qids: list[str], cache: JsonCache, workers: int = 4) -> None:
    todo = [q for q in sorted(set(qids)) if not cache.fresh(q, 30)]
    log(f'Wikidata: {len(set(qids))} 件中 {len(todo)} 件を確認')

    def batch(ids):
        url = ('https://www.wikidata.org/w/api.php?action=wbgetentities&props=claims&format=json&maxlag=5&ids='
               + '|'.join(ids))
        for attempt in range(4):
            try:
                _, _, _, body = http_get(url, 30, 50_000_000, 'application/json')
                data = json.loads(body)
                if 'error' in data:
                    raise RuntimeError(data['error'].get('code'))
                break
            except Exception as e:  # noqa: BLE001
                if attempt == 3:
                    log(f'  Wikidata の取得に失敗: {e}')
                    return
                time.sleep(5 * (attempt + 1))
        for qid, entity in data.get('entities', {}).items():
            claims = entity.get('claims', {})

            def values(prop):
                for c in claims.get(prop, ()):
                    if c.get('rank') == 'deprecated' or 'P582' in c.get('qualifiers', {}):
                        continue  # 廃止されたアカウント
                    v = c.get('mainsnak', {}).get('datavalue', {}).get('value')
                    if isinstance(v, str):
                        yield v

            links = []
            for prop, platform in WIKIDATA_PROPS.items():
                for v in values(prop):
                    if platform == 'youtube':
                        v = ('channel/' + v) if prop == 'P2397' else '@' + v.lstrip('@')
                        links.append((platform, v))
                    else:
                        links.extend(sns.parse_tag(platform, v))
            cache.put(qid, {'l': sns.dedupe(links), 'w': next(values('P856'), None)})

    with ThreadPoolExecutor(workers) as pool:
        list(pool.map(batch, [todo[i:i + 50] for i in range(0, len(todo), 50)]))


# ---------------------------------------------------------------- 2b. 公式サイト

class Robots:
    def __init__(self):
        self.parsers: dict[str, robotparser.RobotFileParser | None] = {}
        self.locks: dict[str, threading.Lock] = {}
        self.lock = threading.Lock()

    def allowed(self, url: str) -> bool:
        p = urlsplit(url)
        origin = f'{p.scheme}://{p.netloc}'
        with self.lock:
            lock = self.locks.setdefault(origin, threading.Lock())
        with lock:
            if origin not in self.parsers:
                parser = None
                try:
                    status, _, _, body = http_get(origin + '/robots.txt', 8, 500_000, 'text/plain')
                    if status == 200:
                        parser = robotparser.RobotFileParser()
                        parser.parse(body.decode('utf-8', 'replace').splitlines())
                except Exception:  # noqa: BLE001  robots.txt がなければ制限なし
                    pass
                self.parsers[origin] = parser
            parser = self.parsers[origin]
        return parser is None or parser.can_fetch(UA, url)


_FRAME = re.compile(r'<(?:i?frame)[^>]+src=["\']?([^"\'\s>]+)', re.I)
_REFRESH = re.compile(r'<meta[^>]+http-equiv=["\']?refresh["\']?[^>]+content=["\']?\d+\s*;\s*url=([^"\'\s>]+)', re.I)


def scan_site(url: str, robots: Robots) -> dict:
    """公式サイトのトップページ（フレームや自動転送の先も 1 回だけ）から SNS へのリンクを探す。"""
    urls: list[str] = []
    target, hops = url, 0
    while True:
        if not robots.allowed(target):
            return {'u': urls, 'e': 'robots'}
        try:
            status, final, ctype, body = http_get(target, 12, 1_500_000)
        except urllib.error.HTTPError as e:
            return {'u': urls, 'e': f'http {e.code}'}
        except (urllib.error.URLError, socket.timeout, ssl.SSLError, ConnectionError, OSError, ValueError) as e:
            if target.startswith('https://') and hops == 0 and url == target and 'CERTIFICATE' not in str(e):
                target = 'http://' + target[8:]  # https に対応していない古いサイト
                hops += 1
                continue
            return {'u': urls, 'e': type(e).__name__}
        if ctype and 'html' not in ctype.lower():
            return {'u': urls, 'e': 'not html'}
        html = body.decode('latin-1')  # URL は ASCII なので文字コードは気にしなくてよい
        # 解釈の規則を直したときに取り直さなくて済むよう、SNS ドメインの URL をそのまま保存する
        urls += [u for u in sns.find_urls(html) if u not in urls]
        nxt = _REFRESH.search(html) or (None if sns.from_urls(urls) else _FRAME.search(html))
        if not nxt or hops >= 2:
            return {'u': urls}
        nxt_url = urljoin(final, nxt.group(1))
        if host_of(nxt_url) != host_of(final) or nxt_url == final:
            return {'u': urls}
        target, hops = nxt_url, hops + 1


def _site_ttl(entry: dict | None) -> float:
    # 繋がらなかったサイトは 2 週間後、それ以外は 2 か月後に確認し直す
    err = (entry or {}).get('e')
    return 14 if err and err not in ('robots', 'not html') and not err.startswith('http 4') else 60


def crawl(urls: list[str], cache: JsonCache, minutes: float, workers: int) -> None:
    todo = [u for u in sorted(set(urls)) if not cache.fresh(u, _site_ttl(cache.data.get(u)))]
    log(f'公式サイト: {len(set(urls))} 件中 {len(todo)} 件を確認（最大 {minutes:.0f} 分）')
    # 同じサーバーに連続でアクセスしないよう、ホスト名のハッシュで混ぜる
    todo.sort(key=lambda u: hashlib.md5(host_of(u).encode()).hexdigest())
    robots = Robots()
    deadline = time.time() + minutes * 60
    done = found = 0
    socket.setdefaulttimeout(15)

    def task(u):
        if time.time() > deadline:
            return None
        return u, scan_site(u, robots)

    with ThreadPoolExecutor(workers) as pool:
        for fut in as_completed([pool.submit(task, u) for u in todo]):
            res = fut.result()
            if res is None:
                continue
            u, value = res
            cache.put(u, value)
            done += 1
            found += bool(sns.from_urls(value['u']))
            if done % 2000 == 0:
                log(f'  {done}/{len(todo)} 件（SNS あり {found} 件）')
                cache.save()
    log(f'  確認 {done} 件、SNS あり {found} 件' + ('（時間切れのため残りは次回）' if done < len(todo) else ''))


# ---------------------------------------------------------------- 3. まとめて書き出す

def apply_wikidata(cands: list[Candidate], wd: JsonCache) -> None:
    for c in cands:
        entry = wd.data.get(c.wikidata) if c.wikidata else None
        if not entry:
            continue
        c.links += [(p, i, 'wikidata') for p, i in entry['l']]
        # OSM に Web サイトがなければ Wikidata の公式サイトを確認する
        if not c.website and entry.get('w'):
            url = normalize_url(entry['w'])
            if url and not skip_host(host_of(url)):
                c.website = url


def site_urls(cands: list[Candidate]) -> set[str]:
    """確認する公式サイト。チェーン店の本部サイトのように多くの地点で共有されているものは、
    店ごとのアカウントが載っていないので除く（学校などは同じサイトでも確認する）。"""
    cells: dict[str, set] = {}
    for c in cands:
        if c.website and not c.inst:
            cells.setdefault(c.website, set()).add(c.cell())
    return {c.website for c in cands
            if c.website and (c.inst or len(cells.get(c.website, ())) < SHARED_THRESHOLD)}


def build(cands: list[Candidate], sites: JsonCache):
    urls = site_urls(cands)
    # サイト共通のフッターなど、多くの地点で見つかったリンクも店ごとのアカウントではない
    link_cells: dict[str, set] = {}
    site_links: dict[int, list] = {}
    for idx, c in enumerate(cands):
        if c.website not in urls:
            continue
        entry = sites.data.get(c.website)
        if entry and (links := sns.from_urls(entry.get('u', ()))):
            site_links[idx] = links
            for link in site_links[idx]:
                link_cells.setdefault(sns.key(link), set()).add(c.cell())

    out = []
    for idx, c in enumerate(cands):
        for p, i in site_links.get(idx, ()):
            shared = len(link_cells[sns.key((p, i))])
            # チェーン店（brand タグあり）の店舗ページにあるのは本部のアカウントのことが多い
            limit = SHARED_THRESHOLD_INSTITUTION if c.inst else (2 if c.chain else SHARED_THRESHOLD)
            if shared < limit:
                c.links.append((p, i, 'website'))
        seen, links = set(), []
        for p, i, s in c.links:
            if sns.key((p, i)) not in seen:
                seen.add(sns.key((p, i)))
                links.append([p, i, s])
        if not links and not c.inst:
            continue
        # sns は空でも付ける（アプリはこれを見て、Wikidata・公式サイトの確認が済んでいると判断する）
        out.append({'type': c.type, 'id': c.id, 'lat': round(c.lat, 6), 'lon': round(c.lon, 6), 'tags': c.tags,
                    'sns': links[:10]})
    return out


def write_tiles(elements: list[dict], coverage: set[str], out_dir: Path, source: str):
    tiles: dict[str, list] = {}
    for el in elements:
        key = f'{math.floor(el["lat"] / TILE_DEG)}_{math.floor(el["lon"] / TILE_DEG)}'
        tiles.setdefault(key, []).append(el)
    tile_dir = out_dir / 't'
    tile_dir.mkdir(parents=True, exist_ok=True)
    for old in tile_dir.glob('*.json'):
        old.unlink()
    for key, els in tiles.items():
        (tile_dir / f'{key}.json').write_text(
            json.dumps({'elements': els}, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    platforms: dict[str, int] = {}
    for el in elements:
        for p in {link[0] for link in el.get('sns', ())}:
            platforms[p] = platforms.get(p, 0) + 1
    meta = {
        'format': FORMAT,
        'generated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'source': source,
        'tileDeg': TILE_DEG,
        'coverage': sorted(coverage),
        'tiles': sorted(tiles),
        'counts': {'elements': len(elements), 'withSns': sum(1 for e in elements if e['sns']), **platforms},
    }
    (out_dir / 'meta.json').write_text(json.dumps(meta, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    log(f'タイル {len(tiles)} 個、{meta["counts"]}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('pbf')
    ap.add_argument('--out', default='site/data/v1')
    ap.add_argument('--cache', default='cache')
    ap.add_argument('--source', default='OpenStreetMap')
    ap.add_argument('--crawl-minutes', type=float, default=120)
    ap.add_argument('--workers', type=int, default=48)
    ap.add_argument('--no-crawl', action='store_true', help='公式サイトを確認せず、保存済みの結果だけを使う')
    args = ap.parse_args()

    cache_dir = Path(args.cache)
    wd = JsonCache(cache_dir / 'wikidata.json')
    sites = JsonCache(cache_dir / 'sites.json')

    cands, coverage = extract(args.pbf)
    log(f'位置を確定した候補 {len(cands)} 件（SNS タグあり {sum(1 for c in cands if c.links)} 件）')

    wikidata_lookup([c.wikidata for c in cands if c.wikidata], wd)
    wd.save()
    apply_wikidata(cands, wd)

    if not args.no_crawl:
        try:
            crawl(list(site_urls(cands)), sites, args.crawl_minutes, args.workers)
        finally:
            sites.save()

    elements = build(cands, sites)
    write_tiles(elements, coverage, Path(args.out), args.source)


if __name__ == '__main__':
    sys.exit(main())
