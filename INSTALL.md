# SimulatorCameraEx インストール手順

開発者向けの説明（しくみ、ビルド方法、CLI の全体、留意事項）は [README.md](README.md) を、AI エージェントやスクリプトから操作する場合は [docs/AUTOMATION.md](docs/AUTOMATION.md) を参照してください。

iOS シミュレータと Android エミュレータのアプリにカメラ映像を渡す Mac アプリです。QR コード・バーコード・画像・動画・Mac のカメラを、アプリの「カメラ」として使えます。バーコード読み取り（expo-camera の `onBarcodeScanned` など）もそのまま動きます。

## 動作環境

- macOS 14 以降（Apple silicon・Intel のどちらでも動きます）
- Xcode 16 以降（iOS シミュレータを使う場合）
- Android Studio（Android SDK・Emulator）と AVD（Android エミュレータを使う場合）

## インストール

### Homebrew で入れる（おすすめ）

```bash
brew install --cask bluecode-jp/tap/simulatorcameraex
```

- `/Applications/SimulatorCameraEx.app` と、コマンドラインツール `simcamctl` が入ります（PATH も通ります）。
- 更新：`brew upgrade --cask simulatorcameraex`
  - 更新した直後に、Android エミュレータや Zoom などで仮想カメラが映らなくなることがあります。そのときは Mac を再起動してください（iOS シミュレータには影響しません）。
- アンインストール：下の「アンインストール」の手順1〜3をしてから `brew uninstall --cask simulatorcameraex`（設定ファイルも消す場合は `--zap` を付ける）

### DMG から入れる

DMG は [Releases](https://github.com/bluecode-jp/SimulatorCameraEx/releases) からダウンロードできます。

1. `SimulatorCameraEx-<version>.dmg` を開き、`SimulatorCameraEx.app` を **/Applications** にコピーします。
   - アプリは BLUECODE,INC. の Developer ID で署名し、Apple の公証を受けています。ダウンロードしたものでも、警告なしで開けます。
   - カメラ拡張は /Applications にあるアプリからしか有効にできません。必ず /Applications にコピーしてください。
2. `/Applications/SimulatorCameraEx.app` を起動します。
3. （任意）`simcamctl` はアプリの中（`/Applications/SimulatorCameraEx.app/Contents/MacOS/simcamctl`）にあります。`simcamctl` だけで実行できるようにするには、PATH の通った場所にリンクを作ります（`~/.local/bin` が PATH に入っている場合。sudo 不要）。
   ```bash
   mkdir -p ~/.local/bin
   ln -sf /Applications/SimulatorCameraEx.app/Contents/MacOS/simcamctl ~/.local/bin/simcamctl
   ```
   リンクなので、アプリを更新すれば `simcamctl` も新しくなります。以下の例は、このリンクを作った前提で `simcamctl` と書いています（作らない場合はフルパスで実行してください）。

## iOS シミュレータで使う

iOS シミュレータにはカメラの仕組みがないため、SimulatorCameraEx は起動するアプリに小さなライブラリ（SimCamInject）を読み込ませ、そこからカメラ映像を渡します。アプリ本体のファイルは変更しません。影響するのは有効にしたシミュレータの中だけで、Mac 本体には影響しません。

### 有効化

**SimulatorCameraEx アプリを起動しておけば、操作は不要です。** 起動済みのシミュレータと、あとから起動したシミュレータに、自動で有効になります（アプリの「iOS Simulator」欄の最初のスイッチでオン・オフできます）。

- 有効になったあとに起動したアプリから、カメラが使えます。すでに起動しているアプリは、一度終了してから起動し直してください。Expo CLI の `i` キーやホーム画面からの起動でも有効です。
- 「iOS Simulator」欄の **Device** で機種を選んで **Launch** を押すと、そのシミュレータを起動して画面を開けます。
- **Safari** とアプリ内の Web 画面（WKWebView）でも、Web ページの `getUserMedia` でカメラ映像を受け取れます。Safari も、有効になったあとに起動し直してください。カメラの許可ダイアログは出ません。

自動の有効化を使わない場合や、対象のアプリを絞りたい場合は、コマンドで有効にします。

```bash
simcamctl sim-enable                              # インストールしたアプリすべてが対象
simcamctl sim-enable --app host.exp.Exponent      # 対象を絞る場合（--app は複数指定可）
```

- シミュレータが複数起動している場合は `--device <UDID>` で対象を指定します（UDID は `xcrun simctl list devices booted` で確認できます）。

### 使い方

1. Mac の SimulatorCameraEx アプリで映像ソースを選びます。
   - **QR Code**：文字を入力して **Inject**
   - **Code 128**：文字（英数字・記号）を入力して **Inject**
   - **EAN-13**：数字を入力して **Inject**。1〜12桁は先頭を0で埋めてチェックデジットを自動で付けます（例：`123456789` → `0001234567895`）。13桁はチェックデジットが正しいか確認します。
   - QR Code・Code 128・EAN-13 は **Preview** で、シミュレータに届く絵を別ウインドウで確認できます（Inject の前でも使えます）。
   - **Static Image**：**Browse…** で画像（バーコード画像など）を選び **Use**
   - **Video File**：**Browse…** で動画を選び **Use**
   - **Mac Camera**：Mac のカメラ映像。右のメニューで使うカメラを選べます（Automatic は内蔵・ディスプレイのカメラを優先。選択は次回起動時も保持）
   - **Test Pattern (Color Bar)**：動くカラーバー（シミュレータ・Mac の仮想カメラ共通）
2. シミュレータ上のアプリでカメラ画面を開きます。
   - 画面下の「iOS Simulator apps: N」で、つながっているアプリの数を確認できます。
   - 画像・QR にバーコードが写っていれば、アプリの読み取り処理が動きます（QR、EAN-13/8、UPC-E、Code128、Code39、Code93、ITF、DataMatrix、PDF417、Aztec）。

### コマンドで映像を切り替える（自動テスト・CI 向け）

SimulatorCameraEx アプリを起動した状態で実行します。アプリの画面で選んだときと同じく、シミュレータ内のアプリと Mac の仮想カメラの両方に届き、アプリの表示も切り替わります。

```bash
simcamctl set-source --qr "https://example.com"          # QR コード
simcamctl set-source --code128 "123456789"               # Code 128
simcamctl set-source --ean 1234567890128                 # EAN-13（12桁なら検査数字を自動付与）
simcamctl set-source --image ./barcodes/4570000011.png   # 画像（バーコード画像など）
simcamctl set-source --video ./scan.mov                  # 動画（繰り返し再生）
simcamctl set-source --camera                            # Mac のカメラ（アプリで選択中のもの）
simcamctl set-source --camera "USB"                      # 名前の一部（または ID）でカメラを指定
simcamctl list-cameras                                   # カメラの一覧（* が選択中）
simcamctl set-source --pattern                           # テストパターン
simcamctl sim-orientation portrait                       # 縦 / landscape で横
simcamctl status                                         # 現在のソースと接続中のアプリ数
```

- アプリが起動していないと、`--qr` `--code128` `--ean` `--image` `--pattern` は Mac の仮想カメラにだけ届きます（シミュレータには届きません）。`--video` `--camera` `sim-orientation` はアプリが必要です。
- 操作用の窓口は Mac 内（127.0.0.1:47848）からのみ受け付けます。JSON で直接操作することもできます（[docs/AUTOMATION.md](docs/AUTOMATION.md)）。
- 自動テストでの手順・待ち時間・確認方法は [docs/AUTOMATION.md](docs/AUTOMATION.md) にまとめています。

### 状態確認・解除

```bash
simcamctl sim-status     # 有効/無効、対象アプリ、Mac アプリとの接続
simcamctl sim-disable    # 解除（シミュレータを再起動しても解除されます）
```

### 1回だけ使う（設定を残さない）

```bash
simcamctl sim-launch host.exp.Exponent --url exp://127.0.0.1:8081
```

そのとき起動したアプリにだけ読み込まれます。アプリを起動し直すと外れます。

### 制限事項

- シミュレータに送る映像の向きは、アプリの「iOS Simulator」欄の **Frame orientation** で選べます。
  - **Portrait 720×1280**（既定）：縦画面のカメラ表示向けです。画像・QR・動画は全体が収まるように、Mac カメラは中央を縦長に切り抜いて送ります。
  - **Landscape 1280×720**：カメラ映像を横向きで扱うアプリ向けです。
  - Mac の仮想カメラ「SimulatorCamera Virtual」は常に横長です。
- `sim-enable --app` で対象を絞った場合、Safari で使うには `--app com.apple.mobilesafari` も指定してください。
- 写真撮影（`AVCapturePhotoOutput`）には対応していません。expo-camera の `takePictureAsync` はシミュレータでは独自のダミー画像を返しますが、他のライブラリでは失敗する可能性があります。
- フラッシュ・ズーム・フォーカスなどの設定は受け付けますが、映像には反映されません。

## Android エミュレータで使う

Android エミュレータは、Mac の仮想カメラ「SimulatorCamera Virtual」を背面カメラとして使います（エミュレータ標準の VirtualScene の代わり）。

1. 仮想カメラを有効にします（下の「Mac の仮想カメラを有効にする」。Mac ごとに初回のみ）。
2. エミュレータを **SimulatorCameraEx から起動します**。
   - アプリの「Android Emulator」欄で AVD を選んで **Launch**（前面カメラも同じ映像にするなら **Front camera too** をオン）
   - またはコマンドで起動します。
     ```bash
     simcamctl android-list                          # AVD の一覧と、仮想カメラの番号
     simcamctl android-launch Medium_Phone_API_36.0  # --front で前面カメラも同じ映像にする
     ```
3. 映像は、iOS と同じくアプリの Source 欄か `simcamctl set-source` で選びます。

- カメラはエミュレータの起動時に決まります。起動中の AVD は、一度終了してから起動し直してください。
- Android Studio の ▶ で起動すると、VirtualScene のままです。Android Studio から起動したい場合は、`simcamctl android-setup <AVD名>` を実行します（Mac につながるカメラが増減したら、やり直しが必要です）。
- アプリが前面カメラで開くと、ドット絵の風景（エミュレータの内蔵ダミー）が映ります。背面カメラに切り替えてください。

## Mac の仮想カメラを有効にする

Mac の仮想カメラ「SimulatorCamera Virtual」は、Android エミュレータと、Zoom などの Mac アプリで使います（iOS シミュレータには不要です）。

1. SimulatorCameraEx アプリで **Activate** をクリックします。
2. 「システム設定 → 一般 → ログイン項目と機能拡張」でカメラ拡張を許可します（Mac ごとに初回のみ）。
3. 許可したあと、アプリが自動で一度再起動することがあります（仮想カメラにつなぎ直すためです）。
   - 再起動しなかった場合や、`simcamctl status` の `sink open` が `no` のままの場合は、アプリを終了して起動し直してください。

拡張に変更がある新しい版に置き換えたときは、アプリの起動時に拡張も自動で入れ替わります（入れ替わったあと、アプリは自動で再起動します）。

## 起動しっぱなしにする場合

起動したままにしても問題はありません（カウンタが増え続けても上限には達せず、メモリも増えません）。

ただし、**Test Pattern 以外のソースを選んでいる間は、映像を見ているアプリがなくても CPU を使い続けます**（QR・バーコードの場合で、Mac 全体の数%程度）。ノート型の Mac で長時間起動しておく場合は、使わない間はソースを **Test Pattern** にするか、アプリを終了してください。

## アンインストール

1. 仮想カメラを有効にしていた場合は、SimulatorCameraEx アプリで **Deactivate** をクリックします。
2. シミュレータで有効化していた場合は `simcamctl sim-disable` を実行します（またはシミュレータを再起動）。
3. `android-setup` を実行した AVD は、Android Studio の Device Manager でカメラの設定を元に戻します。
4. `/Applications/SimulatorCameraEx.app` と、作成した場合は `~/.local/bin/simcamctl` を削除します（Homebrew で入れた場合は `brew uninstall --cask simulatorcameraex`）。
   - 手順1をせずにアプリを Finder でゴミ箱に入れた場合も、macOS がカメラ拡張を自動で削除します（完全に消えるのは Mac の再起動後です）。
   - アプリを置き換えるだけのとき（更新）は、Deactivate は不要です。ただし古いアプリを Finder でゴミ箱に入れると拡張も消えるので、新しいアプリで **Activate** をやり直してください。
