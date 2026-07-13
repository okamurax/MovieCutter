# MovieCutter

macOS 向けの動画トリミングアプリ（Swift + SwiftUI）。

動画を開いて開始・終了位置を指定し、その範囲だけを `.mov` として書き出せます。

## 必要環境

- macOS 13 以上
- Swift 6（Command Line Tools でOK。フル版 Xcode は不要）

## ビルドと起動

```bash
# デバッグビルド → MovieCutter.app を作成
./build.sh

# リリースビルド
./build.sh release

# 起動
open MovieCutter.app
```

開発中に素早く動作確認したいだけなら:

```bash
swift run
```

## 使い方

1. 「動画を開く」で動画ファイルを選択
2. プレビューで内容を確認
3. 「開始位置」「終了位置」スライダーで切り出す範囲を指定
4. 「書き出す」（⌘S）で保存先を選んで `.mov` を出力

## プロジェクト構成

```
Package.swift                        SPM 定義
Sources/MovieCutter/
  MovieCutterApp.swift               アプリのエントリポイント
  ContentView.swift                  UI（プレビュー・スライダー・書き出し）
  VideoTrimmer.swift                 AVFoundation によるトリミング処理
Resources/Info.plist                 .app バンドル用のメタデータ
build.sh                             .app バンドル作成スクリプト
```

## 今後の拡張候補

- 分割 / 結合
- フォーマット変換（mp4 など）
- ドラッグ＆ドロップでのファイル読み込み
- 波形・サムネイルによる範囲指定 UI
