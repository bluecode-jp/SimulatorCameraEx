# SimulatorCamera インストール手順

iOS シミュレータ上のアプリにカメラ映像を渡す Mac アプリです。QR コード・バーコード画像・動画・Mac のカメラを、シミュレータ内アプリの「カメラ」として使えます。バーコード読み取り（expo-camera の `onBarcodeScanned` など）もそのまま動きます。

## 動作環境

- macOS 14 以降
- Xcode 16 以降（iOS シミュレータを使うため）

## インストール

1. `SimulatorCamera-<version>.dmg` を開き、`SimulatorCamera.app` を **/Applications** にコピーします。
2. `/Applications/SimulatorCamera.app` を起動します。
3. （任意）`simcamctl` をパスの通った場所に置くと、コマンドが短く書けます。
   ```bash
   sudo ln -s /Applications/SimulatorCamera.app/Contents/MacOS/simcamctl /usr/local/bin/simcamctl
   ```
   以下の例は、このリンクを作った前提で `simcamctl` と書いています。

## iOS シミュレータで使う

iOS シミュレータにはカメラの仕組みがないため、SimulatorCamera は起動するアプリに小さなライブラリ（SimCamInject）を読み込ませ、そこからカメラ映像を渡します。アプリ本体のファイルは変更しません。影響するのは有効にしたシミュレータの中だけで、Mac 本体には影響しません。

### 有効化（シミュレータを起動するたびに1回）

シミュレータを起動した状態で、ターミナルで実行します。

```bash
simcamctl sim-enable                              # インストールしたアプリすべてが対象
simcamctl sim-enable --app host.exp.Exponent      # 対象を絞る場合（--app は複数指定可）
```

- 実行後に起動したアプリから有効になります。すでに起動しているアプリは、一度終了してから起動し直してください。Expo CLI の `i` キーやホーム画面からの起動でも有効です。
- シミュレータが複数起動している場合は `--device <UDID>` で対象を指定します（UDID は `xcrun simctl list devices booted` で確認できます）。

### 使い方

1. Mac の SimulatorCamera アプリで映像ソースを選びます。
   - **QR Code**：文字を入力して **Generate**
   - **Static Image**：**Browse…** で画像（バーコード画像など）を選び **Use**
   - **Video File**：**Browse…** で動画を選び **Use**
   - **Mac Camera**：Mac のカメラ映像
   - **Test Pattern**：シミュレータ側ではカラーバーが表示されます
2. シミュレータ上のアプリでカメラ画面を開きます。
   - 画面下の「iOS Simulator apps: N」で、つながっているアプリの数を確認できます。
   - 画像・QR にバーコードが写っていれば、アプリの読み取り処理が動きます（QR、EAN-13/8、UPC-E、Code128、Code39、Code93、ITF、DataMatrix、PDF417、Aztec）。

### コマンドで映像を切り替える（自動テスト・CI 向け）

SimulatorCamera アプリを起動した状態で実行します。アプリの画面で選んだときと同じく、シミュレータ内のアプリと Mac の仮想カメラの両方に届き、アプリの表示も切り替わります。

```bash
simcamctl set-source --qr "https://example.com"          # QR コード
simcamctl set-source --image ./barcodes/4570000011.png   # 画像（バーコード画像など）
simcamctl set-source --video ./scan.mov                  # 動画（繰り返し再生）
simcamctl set-source --camera                            # Mac のカメラ
simcamctl set-source --pattern                           # テストパターン
simcamctl sim-orientation portrait                       # 縦 / landscape で横
simcamctl status                                         # 現在のソースと接続中のアプリ数
```

- アプリが起動していないと、`--qr` `--image` `--pattern` は Mac の仮想カメラにだけ届きます（シミュレータには届きません）。`--video` `--camera` `sim-orientation` はアプリが必要です。
- 操作用の窓口は Mac 内（127.0.0.1:47848）からのみ受け付けます。

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
- 写真撮影（`AVCapturePhotoOutput`）には対応していません。expo-camera の `takePictureAsync` はシミュレータでは独自のダミー画像を返しますが、他のライブラリでは失敗する可能性があります。
- フラッシュ・ズーム・フォーカスなどの設定は受け付けますが、映像には反映されません。

## Mac のアプリで使う（任意）

Mac の仮想カメラ「SimulatorCamera Virtual」としても使えます（Zoom などの Mac アプリ向け。iOS シミュレータには不要です）。

1. SimulatorCamera アプリで **Activate** をクリックします。
2. 「システム設定 → 一般 → ログイン項目と機能拡張」でカメラ拡張を許可します（Mac ごとに初回のみ）。

## アンインストール

1. 仮想カメラを有効にしていた場合は、SimulatorCamera アプリで **Deactivate** をクリックします。
2. シミュレータで有効化していた場合は `simcamctl sim-disable` を実行します（またはシミュレータを再起動）。
3. `/Applications/SimulatorCamera.app` と、作成した場合は `/usr/local/bin/simcamctl` を削除します。
