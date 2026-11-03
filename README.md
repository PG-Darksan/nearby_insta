# 近くのスポット (nearby_insta)

現在地や指定した地点の近くにある次の場所を、地図と一覧で表示する Flutter アプリです（Windows / Android）。

| カテゴリ | 表示されるもの |
| --- | --- |
| SNS | Instagram・X・Facebook・TikTok・YouTube・LINE・Threads・Bluesky のアカウントが分かっているお店・施設（飲食店や個人経営のお店も含む） |
| 婚活・合コン | 公開イベント情報（こくちーずプロ・街コンジャパン・オミカレ）から取得した婚活・街コン・合コン・恋活の開催会場 ＋ 自分で登録した「婚活・合コン」 |
| 高校 | 高等学校・中等教育学校 |
| 専門学校 | 専門学校・専修学校・高等専門学校・職業能力開発校など |
| 大学 | 大学・短期大学 |
| 通信制 | 通信制の大学（放送大学の学習センターなど）・通信制高校のキャンパス・サポート校 |
| ボランティア | 公開イベント・募集情報（こくちーずプロ・activo）の実際の**開催地・活動場所**（行政窓口や団体の事務所などの施設は除く） ＋ 自分で登録した「ボランティア募集」 |
| 有償体験 | 体験施設・ワークショップ・陶芸工房など ＋ 自分で登録した「有償体験」 |
| 飲食店 | レストラン・カフェ・居酒屋・ファストフード・バー・パン屋・ケーキ屋など（SNS がなくても表示） |
| 美容室 | 美容室・理容室・ネイル・まつげ・エステなどのサロン（SNS がなくても表示） |
| 史跡・名所 | 城跡・遺跡・古墳・歴史的建造物・文化財、Wikidata に載っている寺社や観光地 |
| 本社・企業 | 会社の事務所（支店・営業所などは除く）と、名前に「本社」「本店」を含む事務所・ビル |

## 主な機能

- **すぐに表示（東京・神奈川の Instagram データはアプリに同梱）**: 東京都・神奈川県エリアの Instagram アカウント付きスポット（約 5,600 件）はアプリ内に予め埋め込んであり、通信前やオフライン時でも起動直後に即座に表示される。その他の地域・カテゴリも、あらかじめ作っておいた全国のデータ（毎週更新）を約 10km 四方の区画ごとに読み込むので、検索してから 1〜2 秒で表示される。一度読んだ区画は端末に保存され、次からは通信なしで表示
- **SNS アカウント**: OpenStreetMap に登録されたアカウントに加えて、Wikidata と、お店・施設の公式サイトに載っている SNS へのリンクから探したアカウントを表示。SNS の種類ごとに表示を切り替えられる
- **アプリ内で SNS を使う**: アカウントを選ぶとアプリ内のブラウザで開く。Instagram などに一度ログインすれば、次回起動時もログインしたまま、フォロー・DM などそのまま操作できる（パスワードは SNS のログイン画面に直接入力され、アプリは保存しない。メニューの「ログイン情報を消去」でログアウト）
- **対象（女性向け・男女兼用・男性向け）で絞り込み**: OSM の `female` / `male` / `unisex` / `hairdresser=barber` / `clothes` のタグと、名前（レディース・メンズ・理容・女子大学など）から、お店や学校が誰向けかを判定して絞り込める。判定できないものは「指定なし」
- **タグ付けされた投稿**: 詳細カードの「タグ付けされた投稿」から、Instagram のアカウントがタグ付けされた投稿、X・Threads・Bluesky でのメンション、Instagram の場所ページ（その場所でタグ付けされた投稿。Wikidata に場所 ID がある所）をアプリ内ブラウザで開く
- **この地域のアカウントを探す**: 検索地点の地名（例: 六浦）で Instagram のアカウント検索を開く。X のボタンでは、その地名をプロフィールに書いているユーザーを X のユーザー検索で探す。個人のアカウントはここから探せる
- **Instagram で探す（高速切り替え）**: データにアカウントがない場所も、一覧の検索ボタンや詳細カードから名前（支店名・地名つき）でワンタップで Instagram のアカウントを検索できる。起動時に検索画面を裏で準備し、すでに Instagram を開いていればページの再読み込みなしで検索欄を直接書き換えるため素早く切り替わる（ログインが必要。ログインしていなければ、ログインした後に入力する。入力できなかったときは、検索する言葉をコピーできる）
- **チェックで表示／非表示の切り替え**: 一覧の各項目のチェックボックスや詳細カードの「非表示にする」から、不要な場所を個別に地図・一覧から隠せる（「非表示にした場所」一覧からいつでも再表示でき、設定は端末に保存される）。カテゴリ・SNS・対象もチェックマーク付きボタンと「すべて選択／すべて解除」でまとめて切り替えられる
- **Jev による Instagram「フォロー中・フォロワー」女性アカウントのみ表示＋費用表示**: アプリ内の SNS ブラウザ上部の「女性のみ」設定で TypeSafe API キー（端末内にのみ保存）を登録すると、Instagram で「フォロー中」「フォロワー」一覧を開いたときに Jev（`jev-latest`）へ**アカウントのアイコン画像**と**アカウント名・表示名**を渡して判定し、女性個人のアカウントのみを表示する（男性・店舗・企業・性別不明アカウントを非表示。ツールバーのボタンでいつでも ON/OFF 切り替え可能。掛かった Jev の費用（USD・日本円目安・トークン数）をブラウザ上部と設定ダイアログに常時表示し、判定結果は端末にキャッシュされるため同じアカウントに再課金しない）
- **SNS を広く表示**: アプリ内ブラウザの操作ボタンは 1 行にまとめ、スマホでは SNS タブの上のバーを隠す。右上の「広げて表示」で、PC では地図を、スマホでは下のタブも隠して全体に表示する
- **支店名・地名つきの名前**: チェーン店などは OSM の `branch`（例: スシロー 金沢八景店）を付けて表示し、ない場合は近くの地名を括弧で付ける（例: スシロー（六浦））
- 現在地の自動取得（端末の位置情報 → 使えない場合は IP アドレスからおおよその位置を推定）
- 検索範囲の切り替え（300m / 1km / 3km / 5km / 10km / 20km のプリセット ＋ **任意の km 数値を 0.1〜50km で直接入力指定**）とカテゴリごとの表示切り替え（スマホでは地図の上の「範囲」と種類のボタン、PC でも地図上の「範囲」「表示切替」から変えられる。SNS の種類や対象は「絞り込み」から）
- **地点の指定**: 地図をタップ →「ここから検索」、地名・住所での検索（国土地理院・Nominatim）、「地図の中心で検索」、右クリック／長押しメニュー
- **検索履歴**（最大 15 件）からワンクリックで再表示。更新ボタンで最新のデータを取り直す
- 名前・ユーザー名・種別・住所・会場名でのキーワード絞り込み
- **募集・集まり情報の登録**: 地図上の開催地をタップ（または右クリック／長押し）→「ここに募集を登録」で、ボランティア募集・婚活・合コン・有償体験（タイトル・主催・内容・料金・日時・URL・連絡先）を登録・編集・削除できる
- PC では地図と一覧（または SNS）を横並び、スマホでは「地図」「一覧」「SNS」タブで切り替え

## データの出どころと制約

- **場所のデータ**は [OpenStreetMap](https://www.openstreetmap.org/)（OSM）です。© OpenStreetMap contributors（[ODbL](https://www.openstreetmap.org/copyright)）
- **SNS アカウント**は次の公開情報から集めています。フォロワー数などでは絞っていません。
  1. OSM の `contact:instagram` / `contact:twitter` / `contact:facebook` などのタグ（`website` が SNS の URL の場合も含む）
  2. OSM の `wikidata` タグから引いた [Wikidata](https://www.wikidata.org/) の SNS アカウント
  3. お店・施設の公式サイト（OSM の `website`、なければ Wikidata の公式サイト）に載っている SNS へのリンク。チェーン店の本部サイトのように多くの店で共通のサイトや、サイト共通のフッターにあるアカウントは除いています
- **個人のアカウント**は自動では表示しません。Instagram や X には「この場所の近くのアカウント」を外部から調べる公開の仕組みがなく、自動で集めると各 SNS の利用規約に反し、ログインしているアカウントが停止される恐れもあるためです。「この地域のアカウントを探す」から、各 SNS 自身の検索で探してください。
- **全国データの作り方**: GitHub Actions（[`.github/workflows/spot-data.yml`](.github/workflows/spot-data.yml)）が毎週、Geofabrik の日本の OSM データから [`tool/build_data.py`](tool/build_data.py) で対象の場所を取り出し、Wikidata と公式サイトを確認して、0.1 度四方のタイル（JSON）を [GitHub Pages](https://pg-darksan.github.io/nearby_insta/) で配信しています。公式サイトの確認は robots.txt に従い、トップページを 2 か月に 1 回程度読むだけです（User-Agent `nearby_insta-databot/1.0`）。
- **日本国外**や配信データに繋がらないときは、これまでどおり [Overpass API](https://overpass-api.de/) から取得します（初めての範囲は 30 秒〜数分かかることがあります）。
- **高校・大学**: OSM の `amenity=school`（名前または `isced:level=3` で高校を判定）、`amenity=university` / `college`（名前に「大学」を含むもの）。
- **専門学校・通信制**: `amenity=college`（名前に「大学」を含まないもの）と、学校の施設のうち名前に「専門学校」「専修学校」「職業能力開発」などを含むもの。通信制は「通信制」「通信教育」「放送大学」や主な通信制高校・サポート校の名前で判定しています（OSM に登録されていないキャンパスは表示されません）。
- **史跡・名所**: `historic=castle` / `ruins` / `archaeological_site` / `building` / `tomb` など、`heritage` タグ（文化財）、Wikidata に載っている寺社（`amenity=place_of_worship`）と観光地（`tourism=attraction`）。記念碑・祠・道標などは Wikidata に載っているものだけ。
- **本社・企業**: OSM で本社かどうかを示すタグはほとんど使われていないため、`office=company`（名前に営業所・支店などを含むものを除く）と、名前に「本社」「本店」を含む事務所・建物を表示しています。
- **女性向け・男性向け**: お店や学校の対象の判定で、アカウントの持ち主の性別ではありません。Instagram などのプロフィールを自動で読むことは利用規約で禁止されているうえ、近くにいる人を性別で絞り込めると悪用のおそれがあるため、アカウントの持ち主の性別は判定していません。
- **飲食店・美容室**: `amenity=restaurant` / `cafe` / `fast_food` / `bar` / `pub` など、`shop=bakery` / `pastry` / `confectionery`、`shop=hairdresser` / `beauty`。
- **タグ付けされた投稿**: Instagram などはタグ付けされた投稿を外部から取得する公開の仕組みがないため、一覧はアプリ内ブラウザで各 SNS のページを開いて見ます（Instagram はログインが必要です）。
- **婚活・合コン・ボランティア・有償体験**: 婚活・街コン・合コン・恋活は公開イベント情報（こくちーずプロ・街コンジャパン・オミカレ）から開催会場を取得して表示します。ボランティアは社会福祉協議会やボランティアセンターなどの行政・事務施設の場所は表示せず、公開募集・イベント情報（こくちーずプロ・activo）の実際の**開催地・活動場所**（会場座標または国土地理院 API による会場住所の座標化）を表示します。有償体験は OSM 上の体験施設・工房を表示します。さらにアプリから「ここに募集を登録」で登録した情報も開催地に表示されます（端末内の `listings.json` にのみ保存され、他の端末とは共有されません）。

## ダウンロード

[Releases](../../releases) から入手できます。

- **Android**: `nearby_insta-<バージョン>-android.apk` をインストール（提供元不明のアプリのインストールを許可する必要があります。デバッグ署名のため Google Play には公開できません）
- **Windows**: `nearby_insta-<バージョン>-windows-x64.zip` を展開して `nearby_insta.exe` を実行。アプリ内ブラウザには Microsoft Edge WebView2 ランタイム（Windows 10/11 には通常入っています）を使います

## ビルド方法

Flutter 3.41 以降が必要です。Windows 版のビルドには NuGet（`winget install Microsoft.NuGet`）も必要です。

```bash
flutter pub get
flutter test
flutter build windows --release   # build/windows/x64/runner/Release/
flutter build apk --release       # build/app/outputs/flutter-apk/app-release.apk
```

リリースに載せるファイルは `pwsh tool/build_release.ps1`（`android` / `windows` で片方だけ）で作ります。`dist/` に `nearby_insta-<バージョン>-android.apk` と `nearby_insta-<バージョン>-windows-x64.zip` ができます（バージョンは `pubspec.yaml` から）。

Windows ではプロジェクトのパスが長すぎるとビルドに失敗するため、`C:\Users\<名前>\nearby_insta` のような短いパスに置いてください。

全国データを手元で作る場合（Python 3.12 以降）:

```bash
pip install -r tool/requirements.txt
python tool/test_sns.py
python tool/build_data.py kanto-latest.osm.pbf --out site/data/v1 --cache cache --crawl-minutes 30
python -m http.server 8765 --directory site
flutter run -d windows --dart-define=SPOT_DATA_URL=http://127.0.0.1:8765/data/v1
```

## 構成

```
lib/
  main.dart                          アプリのエントリポイント
  screens/home_page.dart             画面全体（地図・レイアウト・操作）
  screens/sns_browser.dart           アプリ内の SNS ブラウザ（ログイン状態を保存）
  controllers/nearby_controller.dart 検索地点・範囲・結果・非表示設定・登録情報の状態管理
  models/place.dart                  場所・イベント開催情報とカテゴリ判定
  models/social.dart                 SNS アカウントの種類と URL の解釈
  models/listing.dart                登録した募集情報
  services/spot_data_service.dart    全国データ（GitHub Pages）の読み込み
  services/bundled_instagram_service.dart 東京・神奈川の同梱 Instagram アカウントデータの読み込み
  services/place_repository.dart     同梱データ・全国データ・Overpass API の統合と保存
  services/overpass_service.dart     Overpass API での取得（複数サーバーへの並行問い合わせ）
  services/event_service.dart        婚活・合コン・ボランティア開催地の取得とキャッシュ
  services/jev_service.dart          Jev（TypeSafe AI）によるアイコン＋名前の女性アカウント判定と費用集計
  services/sns_finder.dart           全国データの範囲外での Wikidata・公式サイトからの SNS 探索
  services/geocoding_service.dart    地名・住所検索、会場住所の座標化、町名の取得
  services/search_history.dart       検索履歴
  services/location_service.dart     現在地の取得
  services/listing_store.dart        募集情報の保存
  services/hidden_places_store.dart  個別にチェックして非表示にした場所の保存
  widgets/                           マーカー・一覧・詳細カード・絞り込み・登録ダイアログ
tool/
  build_data.py                      全国データの作成（OSM の抽出・Wikidata・公式サイトの確認・タイル化）
  build_bundled_ig.py                東京・神奈川の同梱 Instagram データの作成
  sns.py                             SNS の URL の解釈（models/social.dart と同じ規則）
```
