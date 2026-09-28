# SimulatorCameraEx

> iOS シミュレータのアプリに「カメラ」を。QR・バーコード・画像・動画・Mac のカメラを、アプリのコードを変えずにカメラ映像として渡します。

iOS シミュレータにはカメラがありません。`AVCaptureDevice.default(for: .video)` は `nil` を返し、QR やバーコードを読むアプリは、シミュレータではカメラ画面が真っ暗になります。

SimulatorCameraEx は Mac アプリで作った映像を、シミュレータ内のアプリにカメラ映像として渡します。アプリは普段どおり AVFoundation でカメラを開くだけです。expo-camera の `onBarcodeScanned` のようなバーコード読み取りも、そのまま動きます。

- アプリ側の変更は不要です。SDK の組み込みも、`Info.plist` の変更も、`#if targetEnvironment(simulator)` の分岐も要りません。
- シミュレータの **Safari** や、アプリ内の Web 画面（WKWebView）でも、Web ページの `getUserMedia` でカメラ映像を受け取れます。
- 映像ソースは次のとおりです。
  - テストパターン（カラーバー）
  - Mac のカメラ（複数台から選択可）
  - QR コード
  - Code 128
  - EAN-13
  - 静止画
  - 動画
- 付属の CLI（`simcamctl`）や JSON の窓口で映像を切り替えられるので、自動テストや CI、AI エージェントからも使えます。手順は [docs/AUTOMATION.md](docs/AUTOMATION.md) にまとめています。
- **Android エミュレータ**でも、同じ映像をカメラとして使えます（標準の VirtualScene の代わり）。「[Android エミュレータで使う](#android-エミュレータで使う)」を参照してください。

---

## SimulatorCamera を拡張しています

このリポジトリは [dautovri/SimulatorCamera](https://github.com/dautovri/SimulatorCamera)（MIT ライセンス）をもとに拡張したものです。元の履歴はそのまま残しており、`upstream` リモートとして参照できます。

### SimulatorCamera との違い

| 項目 | SimulatorCamera（元） | SimulatorCameraEx（このリポジトリ） |
|---|---|---|
| シミュレータへの映像の届け方 | Mac に仮想カメラ（CMIO 拡張）を登録し、シミュレータがそれを拾う想定 | シミュレータ内のアプリに注入ライブラリ **SimCamInject** を読み込ませ、そこで AVFoundation のカメラを差し替える |
| iOS シミュレータで実際に映るか | **映らない**。Xcode 27 で確認したところ、シミュレータにはカメラを扱う仕組み（mediaserverd など）がなく、見えるカメラは 0 台だった | **映る**。iOS 18.5 のシミュレータと Expo Go で確認済み |
| バーコード読み取り | なし | Mac 側の Vision で検出し、`AVCaptureMetadataOutput` の結果としてアプリに渡す（expo-camera の `onBarcodeScanned` が動く） |
| 映像ソース | テストパターン、Mac カメラ、動画、静止画、QR | 左の5つに加えて **Code 128 / EAN-13** の生成、**Mac カメラの選択** |
| 映像の向き | 横 1280×720 のみ | シミュレータ向けは **縦 720×1280**（既定）と横を切り替えられる |
| テストパターン | 黒地に白い線 | **カラーバー**（シミュレータと仮想カメラで同じ絵） |
| CLI | 仮想カメラへ1枚だけ送る | アプリ経由でシミュレータと仮想カメラの両方に送れる。注入の管理（`sim-*`）、カメラの一覧・選択、向きの切り替えも追加 |
| シミュレータ起動時の設定 | — | アプリ起動中は、起動したシミュレータへの注入を自動で有効化 |
| 仮想カメラ（CMIO 拡張） | 必須 | iOS シミュレータだけなら**任意**。Android エミュレータや Zoom などの Mac アプリで使う場合に有効化する |
| Android エミュレータ | — | 仮想カメラを背面カメラにして AVD を起動する機能（画面・`android-*` コマンド） |
| 署名・ID | 作者のチーム・`com.dautov.*` | BLUECODE,INC.（`C5TUJ8526Z`）・`jp.co.bluecode.*` |
| 表示名・アイコン | SimulatorCamera | SimulatorCameraEx（独自アイコン） |

元のコードにあった不具合も、あわせて直しています。
- 拡張機能のファイル名が原因で Activate できなかった
- 仮想カメラへの送信キューが取得できなかった
- 縦向きの動画が上下逆さまに映った
- CLI が毎回「受け取られなかった」と誤ってエラーを出していた

変更の一覧は git の履歴（`git log upstream/main..main`）で確認できます。

---

## しくみ

```
┌──────────────── Mac ────────────────────────────────────────────┐
│ /Applications/SimulatorCameraEx.app                              │
│   映像ソース（カメラ / QR / Code128 / EAN-13 / 画像 / 動画）    │
│      ├─▶ SimulatorFeed   127.0.0.1:47847  フレーム＋バーコード   │
│      │                   検出結果（Vision）を配信               │
│      ├─▶ ControlServer   127.0.0.1:47848  simcamctl からの操作  │
│      └─▶ CMIO 拡張（任意） Mac の仮想カメラ                      │
│             「SimulatorCamera Virtual」                         │
│                                                                  │
│  ┌──────────── iOS シミュレータ ───────────────────────────┐    │
│  │ アプリ（Expo Go、開発中のアプリなど）                    │    │
│  │   └ SimCamInject.dylib（DYLD_INSERT_LIBRARIES で読み込み）│    │
│  │       AVCaptureDevice / Session / VideoDataOutput /      │    │
│  │       MetadataOutput / PreviewLayer を差し替え           │    │
│  │       ← 127.0.0.1:47847 から映像を受け取る                │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

- Android エミュレータは、CMIO 拡張の仮想カメラを Mac のカメラ（`webcamN`）の1台として使います。Android 側への注入はありません。
- Safari と WKWebView の Web ページには、別の方法で映像を渡します。WebKit はカメラを GPU 用の別プロセスで扱いますが、このプロセスには注入ライブラリを読み込ませられません。そこで、注入ライブラリが Web ページに小さなスクリプト（`SimCamInject/SimCamWebShim.js`）を追加し、`getUserMedia` の映像を Mac から届いたフレームに置き換えます。
- シミュレータのアプリは、中身は Mac 上で動くプロセスです。そのため localhost（127.0.0.1）で Mac アプリとつながります。
- 注入ライブラリは入口役（`SimCamLoader.dylib`）と本体（`SimCamInject.dylib`）の2つに分かれています。入口役は、ユーザーがインストールしたアプリにだけ本体を読み込みます。シミュレータのシステムプロセスには本体を読み込みません。
- どちらのライブラリも、アプリの `Contents/Resources/SimCamInject/` に同梱されています。

---

## 動作環境

- macOS 14 以降（macOS 27.0 で確認）
- Xcode 16 以降（Xcode 27.0 で確認）
  - Xcode 27 ではシミュレータの画面が Device Hub に変わっています（`Xcode.app/Contents/Applications/DeviceHub.app`）。
- iOS シミュレータ：iOS 18.5（iPhone 16 Pro）と Expo Go 57.0.9 で確認済み
- ソースからビルドする場合は、次のものも必要です。
  - [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
  - BLUECODE,INC. チームに所属する Apple Developer アカウント

---

## セットアップ

### A. 配布用 DMG から入れる

配布用 DMG を受け取った人は、[INSTALL.md](INSTALL.md) の手順に沿って入れてください（DMG は準備中です。下の「開発者向け情報」を参照）。

1. DMG を開き、`SimulatorCameraEx.app` を **/Applications** にコピーする
2. アプリを起動する

### B. ソースからビルドする

```bash
git clone https://github.com/bluecode-jp/SimulatorCameraEx.git
cd SimulatorCameraEx
xcodegen generate
xcodebuild -project SimulatorCamera.xcodeproj -scheme SimulatorCamera \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM=C5TUJ8526Z build
```

- `-allowProvisioningDeviceRegistration` は、その Mac を初めてチームに登録するときだけ必要です。
- ビルドの途中で、注入ライブラリ（`SimCamInject/build.sh`）も自動で作られ、アプリに同梱されます。

できたアプリを `/Applications` にコピーして起動します。

```bash
rm -rf /Applications/SimulatorCameraEx.app
ditto build/dd/Build/Products/Debug/SimulatorCameraEx.app /Applications/SimulatorCameraEx.app
open /Applications/SimulatorCameraEx.app
```

### 初回の設定

- **シミュレータ用の設定は不要です。** アプリが起動している間は、起動済みのシミュレータと、あとから起動したシミュレータに、注入が自動で有効になります。画面の「iOS Simulator」欄にある最初のスイッチで、オン・オフを切り替えられます。
- **Mac Camera を使う場合**：初回にカメラへのアクセス許可を求められます。許可してください。
- **Android エミュレータや Mac の仮想カメラも使う場合**：
  1. アプリの **Activate** を押す
  2. 「システム設定 → 一般 → ログイン項目と機能拡張」でカメラ拡張を許可する（Mac ごとに初回のみ）
  - iOS シミュレータで使うだけなら、この手順は要りません。

---

## 使い方（UI）

### 1. 映像ソースを選ぶ（Source 欄）

| ソース | 操作 | 内容 |
|---|---|---|
| **Test Pattern (Color Bar)** | 行をクリック | 動くカラーバー。映像が届いているかの確認用 |
| **Mac Camera** | 行をクリック。右のメニューでカメラを選ぶ | Mac のカメラ映像。「Automatic」は内蔵やディスプレイのカメラを優先する。選んだカメラは次回起動時も使われる |
| **QR Code** | 文字を入力して **Generate** | QR コードを生成（初期値 `https://www.bluecode.co.jp`） |
| **Code 128** | 文字（ASCII）を入力して **Generate** | Code 128 を生成（初期値 `123456789`） |
| **EAN-13** | 数字を入力して **Generate** | EAN-13 を生成（初期値 `1234567890128`）。入力欄の下に、実際に描かれる13桁を表示する |
| **Video File** | **Browse…** で選んで **Use** | 動画を繰り返し再生する。iPhone で縦向きに撮った動画も正しい向きで映る |
| **Static Image** | **Browse…** で選んで **Use** | 静止画（バーコード画像など） |

EAN-13 の入力ルールは次のとおりです。
- 1〜12桁を入れた場合：先頭を0で埋めて12桁にし、チェックデジットを自動で付けます。
- 13桁を入れた場合：チェックデジットが正しいかを確かめます。正しくなければ赤字で知らせ、**Generate** を押せなくします。

### 2. シミュレータのアプリでカメラを開く

- 選んだ映像が、アプリのカメラ映像として映ります。
- 映像にバーコードが写っていれば、アプリの読み取り処理がそのまま動きます。
  - 読める種類：QR、EAN-13、EAN-8、UPC-E、Code 128、Code 39、Code 93、ITF、DataMatrix、PDF417、Aztec
- 画面下の「iOS Simulator apps: N」は、今つながっているシミュレータ内のアプリの数です。

### 3. iOS Simulator 欄

- **Device ＋ Launch**：選んだシミュレータを起動し、画面（Simulator.app、Xcode 27 以降は DeviceHub.app）を開きます。起動済みの機種には「— booted」と付きます。カメラは下の自動注入で入るので、起動したらアプリを開くだけです。
- **Enable the camera in iOS Simulators automatically when they boot**：起動したシミュレータへの自動注入のオン・オフです。
- **Frame orientation**：シミュレータに送る映像の向きです。
  - **Portrait 720×1280**（既定）：縦画面のカメラ表示向けです。画像・QR・動画は全体が収まるように、Mac カメラは中央を縦長に切り抜いて送ります。
  - **Landscape 1280×720**：カメラを横向きで扱うアプリ向けです。
- **Camera enabled in: …**：注入を有効にしたシミュレータの一覧です。

---

## 使い方（CLI）

`simcamctl` はアプリの中にあります。PATH は通していないので、フルパスで実行します。

```bash
SIMCAMCTL=/Applications/SimulatorCameraEx.app/Contents/MacOS/simcamctl
$SIMCAMCTL help
```

PATH を通したい場合は、`ln -sf /Applications/SimulatorCameraEx.app/Contents/MacOS/simcamctl ~/.local/bin/simcamctl` を実行します（`~/.local/bin` が PATH に入っている場合。詳しくは [INSTALL.md](INSTALL.md) を参照）。

### 映像ソースを切り替える

アプリが起動していれば、アプリ経由でシミュレータと仮想カメラの両方に届きます。アプリの画面表示も一緒に切り替わります。

```bash
$SIMCAMCTL set-source --pattern                       # テストパターン（カラーバー）
$SIMCAMCTL set-source --camera                        # Mac カメラ（アプリで選択中のもの）
$SIMCAMCTL set-source --camera "USB"                  # 名前の一部か ID でカメラを指定
$SIMCAMCTL list-cameras                               # カメラの一覧（* が選択中）
$SIMCAMCTL set-source --qr "https://example.com"      # QR コード
$SIMCAMCTL set-source --code128 "4570000011"          # Code 128
$SIMCAMCTL set-source --ean 1234567890128             # EAN-13（1〜12桁ならチェックデジットを自動で付ける）
$SIMCAMCTL set-source --image ./barcode.png           # 静止画
$SIMCAMCTL set-source --video ./scan.mov              # 動画
$SIMCAMCTL sim-orientation portrait                   # 映像の向き（portrait / landscape）
$SIMCAMCTL status                                     # 現在のソース・接続数・仮想カメラの状態
$SIMCAMCTL ping                                       # 仮想カメラに届くか
```

アプリが起動していないときの動きは、次のとおりです。
- `--qr` `--code128` `--ean` `--image`：Mac の仮想カメラにだけ1枚送ります。`--pattern` は仮想カメラの表示をテストパターンに切り替えます。どちらもシミュレータには届きません。
- `--camera` `--video` `list-cameras` `sim-orientation`：アプリが必要です。

### シミュレータへの注入を管理する

アプリの自動有効化を使わない場合や、対象のアプリを絞りたい場合に使います。

```bash
$SIMCAMCTL sim-enable                          # 起動中のシミュレータで有効化（インストールしたアプリすべてが対象）
$SIMCAMCTL sim-enable --app host.exp.Exponent  # 対象のアプリを絞る（--app は複数指定可）
$SIMCAMCTL sim-disable                         # 解除（シミュレータを再起動しても解除される）
$SIMCAMCTL sim-status                          # 有効かどうか、対象アプリ、Mac アプリにつながるか
$SIMCAMCTL sim-launch host.exp.Exponent --url exp://127.0.0.1:8081   # 1回の起動だけ注入する
```

- どのコマンドも `--device <UDID>` で対象のシミュレータを指定できます（既定は起動中のシミュレータ）。
- 有効にしたあとに起動したアプリから効きます。すでに起動しているアプリは、一度終了して起動し直してください。

### 自動テストでの使い方の例

手順・待ち時間・終了コード・JSON での操作・Android での流れは [docs/AUTOMATION.md](docs/AUTOMATION.md) を参照してください。

```bash
$SIMCAMCTL set-source --code128 "4570000011"
xcrun simctl launch booted <bundle id>   # テストしたいアプリを起動し、カメラ画面を開く
# … アプリが商品コード 4570000011 を読み取って、画面が移ることを確認する
```

---

## Android エミュレータで使う

Android エミュレータは、Mac のカメラを Android のカメラとして使えます（`webcamN`）。SimulatorCameraEx の仮想カメラ「SimulatorCamera Virtual」もその1台として見えるので、これを背面カメラにして AVD を起動します。Android 側への注入はありません。

- 事前に、アプリの **Activate** で仮想カメラ（CMIO 拡張）を有効にしておきます（「初回の設定」を参照）。
- 映像は、アプリの Source 欄や `simcamctl set-source` で選んだものがそのまま届きます。
- バーコードは Android のアプリ自身（ML Kit、ZXing など）が映像から読み取ります。
- Android Emulator 37.1（API 36）で確認済みです。

### アプリから起動する（Android Emulator 欄）

1. AVD を選ぶ（一覧は Android SDK の `emulator -list-avds`。**Refresh** で読み直す）
2. **Launch** を押す
   - **Front camera too** をオンにすると、前面カメラも同じ映像になります。
3. エミュレータのカメラアプリで**背面カメラ**を選ぶ（前面カメラが開いた場合）

### CLI から起動する

```bash
$SIMCAMCTL android-list                          # AVD の一覧と、仮想カメラの番号（webcamN）
$SIMCAMCTL android-launch Medium_Phone_API_36.0  # 仮想カメラを背面カメラにして起動
$SIMCAMCTL android-launch Medium_Phone_API_36.0 --front   # 前面カメラも同じ映像にする
```

- エミュレータのログは `~/Library/Logs/SimulatorCamera/emulator-<AVD名>.log` に出ます。
- Android SDK は `ANDROID_HOME`、`ANDROID_SDK_ROOT`、`~/Library/Android/sdk` の順に探します。

### Android Studio から起動したい場合

```bash
$SIMCAMCTL android-setup Medium_Phone_API_36.0   # AVD の config.ini の hw.camera.back を webcamN に書き換える
```

`webcamN` の番号は、Mac につながっているカメラ（USB カメラや iPhone の連係カメラ）が増減すると変わります。変わったら `android-setup` をやり直してください。アプリの **Launch** と `android-launch` は、起動のたびに番号を調べ直すので、この問題は起きません。

### 注意
- カメラは**エミュレータの起動時**に決まります。起動中の AVD は、一度終了してから起動し直してください。
- 仮想カメラの映像は横長（1280×720）ですが、エミュレータがアプリに渡すのはその一部です（カメラアプリは中央の 3:4、Chrome は中央より少し右の 9:16）。QR・バーコードはどちらにも収まる大きさで、Chrome で中央に見える位置に描きます。そのため、カメラアプリや Mac の仮想カメラでは少し右寄りに見えます。
- 静止画・動画・Mac カメラは位置を調整しないので、左右が切れて見えます。

---

## 留意事項

### 影響する範囲
- **注入が影響するのは、有効にした iOS シミュレータの中だけ**です。Mac 本体のアプリやシステムには読み込まれません。
- 自動有効化（または `sim-enable`）は、シミュレータの中の環境変数 `DYLD_INSERT_LIBRARIES` に設定を入れます。
  - 設定は、シミュレータを再起動するか `sim-disable` を実行すると消えます。
  - 手動で `sim-disable` した場合、そのシミュレータは次に起動し直すまで自動では有効に戻りません。
- アプリ本体のファイル（Expo Go や開発中のアプリ）は書き換えません。起動中のメモリの中だけで動きを差し替えます。
- Mac アプリは localhost の 47847（映像）と 47848（操作）で待ち受けます。どちらも Mac の中からしか受け付けませんが、Mac 上のほかのプログラムからもソースを切り替えられる点には注意してください。
- シミュレータを操作するため、Mac アプリは App Sandbox の外で動きます。カメラ拡張はサンドボックスの中で動きます。

### 対応していないこと
- **写真撮影**（`AVCapturePhotoOutput`）には対応していません。
  - expo-camera の `takePictureAsync` は、シミュレータでは独自のダミー画像を返します。
  - ほかのライブラリでは失敗する可能性があります。
- フラッシュ・ズーム・フォーカスなどの設定は受け付けますが、映像には反映されません。前後のカメラの切り替えもありません。どちらを選んでも同じ映像です。
- 音声（マイク）には対応していません。
- Web ページ（Safari・WKWebView）の `getUserMedia` は、映像だけ差し替えます。カメラの許可ダイアログは出ません。ズームなどの `applyConstraints` は受け付けますが、映像には反映されません。
- AVFoundation の内部の仕組みに合わせて差し替えているため、iOS シミュレータのバージョンによっては動かない可能性があります。
- ライブラリの中に `#if targetEnvironment(simulator)` でカメラを無効にするコードがあると、映像はアプリまで届きません。元のリポジトリの `patches/` にある、古い expo-camera / react-native-vision-camera 向けのパッチが必要になる場合があります（未確認）。

### よくあるトラブル
| 症状 | 対処 |
|---|---|
| シミュレータのカメラが真っ暗・カメラなし | 注入が効いていません。Mac アプリを起動し（または `sim-enable`）、シミュレータのアプリを一度終了して起動し直してください。`sim-status` で確認できます |
| Mac Camera を選んでもカラーバーのまま | macOS 側でカメラからの映像が止まっていることがあります。Photo Booth を一度開くか、Mac Camera を選び直してください。直らなければ Mac を再起動してください |
| 「Extension not reachable」と表示される | カメラ拡張が準備中か、入れ替えの直後です。拡張を入れ替えたあとはアプリが自動で再起動するので、少し待ってください。シミュレータへの映像はこのエラーとは関係なく届きます |
| `simcamctl: command not found` | PATH を通していません。フルパスで実行してください |
| EAN-13 の **Generate** が押せない | チェックデジットが合っていません。12桁までで入力すると、自動で付けます |
| Android エミュレータにドット絵の風景が映る | 前面カメラ（エミュレータの内蔵ダミー）が開いています。カメラアプリで背面カメラに切り替えてください |
| Android Emulator 欄に「does not list 'SimulatorCamera Virtual'」と出る | 仮想カメラが有効になっていません。**Activate** を押してください |

---

## 開発者向け情報

### ディレクトリ構成（主なもの）

| パス | 内容 |
|---|---|
| `SimulatorCamera/` | Mac アプリ（SwiftUI）。映像ソース、`SimulatorFeed`（映像の配信）、`ControlServer`（CLI からの操作）、`SimulatorAutoEnabler`（注入の自動有効化）、`AndroidEmulatorCard` / `SimulatorLaunchRow`（エミュレータ・シミュレータの起動） |
| `SimCamInject/` | iOS シミュレータ用の注入ライブラリ（Objective-C / C）と `build.sh` |
| `SimulatorCameraExtension/` | Mac の仮想カメラ（CMIO 拡張） |
| `simcamctl/` | CLI |
| `Shared/` | アプリ・拡張・CLI で共通のコード（通信の約束事、QR / バーコードの描画、Android エミュレータの起動 `AndroidEmulator.swift`（拡張には含めない）など） |
| `docs/AUTOMATION.md` | 自動テスト・AI エージェント向けの操作手順 |
| `Tests/` | ユニットテスト |
| `scripts/make-icon.swift` | アプリアイコンを描いて生成する |
| `scripts/build-release.sh` | 配布用 DMG を作る（Developer ID で署名し、公証する） |

Xcode プロジェクトは `project.yml` から XcodeGen で作ります。`.xcodeproj` は直接編集しないでください。

### テスト

```bash
xcodebuild -project SimulatorCamera.xcodeproj -scheme SimulatorCamera \
  -derivedDataPath build/dd -allowProvisioningUpdates DEVELOPMENT_TEAM=C5TUJ8526Z test
```

主に次の内容を確かめます。
- 通信の約束事
- EAN-13 のチェックデジット
- 描いたバーコードが Vision で読み取れるか（縦・横の両方）

### カメラ拡張を変更したとき
- `project.yml` の `CURRENT_PROJECT_VERSION` を1つ上げてください。
  - ビルド番号が変わると、アプリの起動時に拡張が自動で入れ替わります。入れ替わったあと、アプリは自動で再起動します。
  - ビルド番号を上げないと、古い拡張が使われ続けます。

### 配布用 DMG（準備中）
DMG の作成に必要なものは次の2つです。
- Developer ID Application 証明書
- 公証用の認証情報（`xcrun notarytool store-credentials SimCamNotary …`）

どちらも揃ったら、次のように実行します。

```bash
KEYCHAIN_PROFILE=SimCamNotary APPLE_TEAM_ID=C5TUJ8526Z \
APPLE_DEVELOPER_ID="Developer ID Application: BLUECODE,INC. (C5TUJ8526Z)" \
VERSION=1.0.0 ./scripts/build-release.sh
```

### CI
GitHub Actions のワークフローは手動実行だけにしています。macOS のランナーは費用がかかるためです。実行する場合は Actions タブを使うか、`gh workflow run CI` を実行してください。

---

## ライセンス

MIT — [LICENSE](LICENSE) を参照してください。元の [SimulatorCamera](https://github.com/dautovri/SimulatorCamera) の著作権表示とライセンスを引き継いでいます。
