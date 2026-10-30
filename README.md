# 近くのスポット (nearby_insta)

現在地の近くにある次の場所を、地図と一覧で表示する Flutter アプリです（Windows / Android）。

| カテゴリ | 表示されるもの |
| --- | --- |
| Instagram | Instagram アカウントが登録されているお店・施設 |
| 高校 | 高等学校・中等教育学校 |
| 大学 | 大学・短期大学 |
| ボランティア | ボランティアセンター・社会福祉協議会・市民活動センターなど ＋ 自分で登録した「ボランティア募集」 |
| 有償体験 | 体験施設・ワークショップ・陶芸工房など ＋ 自分で登録した「有償体験」 |

## 主な機能

- 現在地の自動取得（端末の位置情報 → 使えない場合は IP アドレスからおおよその位置を推定）
- 検索範囲の切り替え（300m / 1km / 3km / 5km / 10km / 20km）とカテゴリごとの表示切り替え
- **地点の指定**: 地図をタップ →「ここから検索」、地名・住所での検索（国土地理院・Nominatim）、「地図の中心で検索」、右クリック／長押しメニュー
- **検索結果の再利用**: 取得したデータは約 2km 四方のタイルごとに端末へ 7 日間保存し、同じ場所や範囲の一部をもう一度検索したときは通信せずにすぐ表示。足りない範囲だけを中心に近い順に取得する。検索履歴（最大 15 件）からワンクリックで再表示でき、更新ボタンで最新データに取り直せる
- **学校・施設の Instagram**: OSM に Instagram が登録されていない学校・施設も、Wikidata の「Instagram ユーザー名」と、公式サイトに掲載された Instagram リンクから自動で探して表示（結果は 30 日間保存）。見つからない場合は「Instagram で探す」から名前で Web 検索できる
- 名前・Instagram ユーザー名・種別でのキーワード絞り込み
- 場所を選ぶと詳細カードを表示し、Instagram・Web サイト・OpenStreetMap をワンクリックで開ける
- **募集情報の登録**: 地図をタップ（または右クリック／長押し）→「ここに募集を登録」で、ボランティア募集や有償体験（タイトル・主催・内容・料金・日時・URL・連絡先）を登録・編集・削除できる
- PC では地図と一覧を横並び、スマホでは「地図」「一覧」タブで切り替え

## データの出どころと制約

- **地図と場所のデータ**は [OpenStreetMap](https://www.openstreetmap.org/)（OSM）を [Overpass API](https://overpass-api.de/) 経由で取得しています。© OpenStreetMap contributors（[ODbL](https://www.openstreetmap.org/copyright)）
- **Instagram**: Instagram には「位置から近くのアカウントを探す」公式 API がないため、フォロワー数などで絞っているわけではなく、次の公開情報で見つかったアカウントだけを表示しています。どこにも掲載されていないアカウントは表示されません。プロフィール画像も取得していません。
  1. OSM の `contact:instagram` / `instagram` タグ
  2. OSM の `wikidata` タグから引いた [Wikidata](https://www.wikidata.org/) の Instagram ユーザー名（P2003）
  3. 学校・施設の公式サイト（OSM の `website` または Wikidata の公式サイト）に掲載されている Instagram へのリンク
- **高校・大学**: OSM の `amenity=school`（名前または `isced:level=3` で高校を判定）、`amenity=university` / `college`（名前に「大学」を含むもの）。
- **ボランティア・有償体験**: 「いま募集中か」「料金はいくらか」を全国規模で取得できる公開 API がないため、OSM 上の関連施設を名前で判定して表示し、実際の募集情報はアプリで登録する方式にしています。登録した情報は端末内（アプリのデータフォルダの `listings.json`）にのみ保存され、他の端末とは共有されません。
- Overpass API の公開サーバーは混雑することがあり、初めて検索する範囲は 30 秒〜数分かかることがあります。応答が遅いときは 10 秒ごとに別のサーバーにも並行して問い合わせ、最初に返ってきた結果を使います。一度取得した範囲は端末に保存されるので、2 回目以降はすぐに表示されます。

## ダウンロード

[Releases](../../releases) から入手できます。

- **Android**: `nearby_insta-android.apk` をインストール（提供元不明のアプリのインストールを許可する必要があります。デバッグ署名のため Google Play には公開できません）
- **Windows**: `nearby_insta-windows-x64.zip` を展開して `nearby_insta.exe` を実行

## ビルド方法

Flutter 3.41 以降が必要です。

```bash
flutter pub get
flutter test
flutter build windows --release   # build/windows/x64/runner/Release/
flutter build apk --release       # build/app/outputs/flutter-apk/app-release.apk
```

Windows ではプロジェクトのパスが長すぎるとビルドに失敗するため、`C:\Users\<名前>\nearby_insta` のような短いパスに置いてください。

## 構成

```
lib/
  main.dart                       アプリのエントリポイント
  screens/home_page.dart          画面全体（地図・レイアウト・操作）
  controllers/nearby_controller.dart  検索地点・範囲・結果・登録情報の状態管理
  models/place.dart               場所とカテゴリ判定、Instagram タグの解析
  models/listing.dart             登録した募集情報
  services/overpass_service.dart  Overpass API での取得（複数サーバーへの並行問い合わせ）
  services/place_repository.dart  タイル単位の保存と、足りない範囲だけの取得
  services/instagram_finder.dart  Wikidata・公式サイトからの Instagram 探索
  services/geocoding_service.dart 地名・住所検索と町名の取得
  services/search_history.dart    検索履歴
  services/location_service.dart  現在地の取得
  services/listing_store.dart     募集情報の保存
  widgets/                        マーカー・一覧・詳細カード・登録ダイアログ
```
