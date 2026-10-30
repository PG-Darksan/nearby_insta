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
- 検索範囲の切り替え（300m / 500m / 1km / 2km / 5km）とカテゴリごとの表示切り替え
- 名前・Instagram ユーザー名・種別でのキーワード絞り込み
- 場所を選ぶと詳細カードを表示し、Instagram・Web サイト・OpenStreetMap をワンクリックで開ける
- **募集情報の登録**: 地図を右クリック（スマホは長押し）→「ここに募集情報を登録」で、ボランティア募集や有償体験（タイトル・主催・内容・料金・日時・URL・連絡先）を登録・編集・削除できる
- 地図を右クリック（長押し）→「この地点で検索」、または「地図の中心で検索」で別の場所を検索できる
- PC では地図と一覧を横並び、スマホでは「地図」「一覧」タブで切り替え

## データの出どころと制約

- **地図と場所のデータ**は [OpenStreetMap](https://www.openstreetmap.org/)（OSM）を [Overpass API](https://overpass-api.de/) 経由で取得しています。© OpenStreetMap contributors（[ODbL](https://www.openstreetmap.org/copyright)）
- **Instagram**: Instagram には「位置から近くのアカウントを探す」公式 API がないため、OSM の `contact:instagram` / `instagram` タグが登録されている場所を表示しています。OSM に登録されていないアカウントは表示されません。プロフィール画像も取得していません。
- **高校・大学**: OSM の `amenity=school`（名前または `isced:level=3` で高校を判定）、`amenity=university` / `college`（名前に「大学」を含むもの）。
- **ボランティア・有償体験**: 「いま募集中か」「料金はいくらか」を全国規模で取得できる公開 API がないため、OSM 上の関連施設を名前で判定して表示し、実際の募集情報はアプリで登録する方式にしています。登録した情報は端末内（アプリのデータフォルダの `listings.json`）にのみ保存され、他の端末とは共有されません。
- Overpass API の公開サーバーは混雑することがあります。混雑時は予備サーバーで自動的に再試行し、それでも失敗した場合は時間をおいて再検索してください。

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
  services/overpass_service.dart  Overpass API での検索（再試行つき）
  services/location_service.dart  現在地の取得
  services/listing_store.dart     募集情報の保存
  widgets/                        マーカー・一覧・詳細カード・登録ダイアログ
```
