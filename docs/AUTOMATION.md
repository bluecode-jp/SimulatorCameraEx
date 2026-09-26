# 自動テストでの使い方（AI エージェント・CI 向け）

SimulatorCameraEx を、外部のツール（AI エージェント、テストスクリプト、CI）から操作するための手順です。
人が画面で操作する方法は [README.md](../README.md) を参照してください。

このツールでできることは、**iOS シミュレータ / Android エミュレータのアプリに、指定したカメラ映像（QR・バーコード・画像・動画）を見せること**です。
アプリが正しく読み取ったかどうかの判定（画面遷移、表示内容の確認など）は、テストする側で行ってください。

---

## 0. 前提：人が事前に済ませておくこと

次の作業は、macOS の承認ダイアログが出るため自動化できません。テストを始める前に、人が一度だけ済ませてください。

| 作業 | 必要な場面 | 確認コマンド |
|---|---|---|
| `/Applications/SimulatorCamera.app` を入れる | 常に | `test -x /Applications/SimulatorCamera.app/Contents/MacOS/simcamctl` |
| アプリで **Activate** を押し、「システム設定 → 一般 → ログイン項目と機能拡張」でカメラ拡張を許可 | Android エミュレータを使う場合（iOS だけなら不要） | `simcamctl ping` の終了コードが 0 |
| Xcode と iOS シミュレータ | iOS | `xcrun simctl list devices available` |
| Android Studio（Android SDK・Emulator）と AVD の作成 | Android | `simcamctl android-list` に AVD が出る |

以下では、次の変数を使います。

```bash
SIMCAMCTL=/Applications/SimulatorCamera.app/Contents/MacOS/simcamctl
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
```

---

## 1. 基本ルール

1. **Mac アプリ（SimulatorCamera.app）を起動しておく。** 映像を作っているのはアプリです。アプリが止まっていると、iOS シミュレータには映像が届きません。
2. **映像は `simcamctl set-source` で切り替える。** 戻ってきた時点で、新しい映像が流れ始めています。
3. **切り替えたあと、アプリが読み取るまで 1 秒ほど待つ。** 映像は毎秒 30 コマで届きます。iOS のバーコード検出は 0.1 秒ごとです。
4. **同じバーコードを続けて読ませるときは、間にテストパターンを挟む。** 多くのアプリは、同じ値が続けて見えると読み取りを1回にまとめます。
   ```bash
   $SIMCAMCTL set-source --pattern && sleep 1 && $SIMCAMCTL set-source --code128 "4570000011"
   ```
5. **終了コードで成否を判断する。** 標準出力の文言は、人が読むためのものです。

### アプリの起動と準備完了の確認

```bash
open -g /Applications/SimulatorCamera.app          # -g: 前面に出さずに起動
for i in $(seq 1 30); do
  printf '{"command":"status"}\n' | nc -w 2 127.0.0.1 47848 | grep -q '"ok":true' && break
  sleep 1
done
```

---

## 2. simcamctl リファレンス

### 終了コード

| コード | 意味 |
|---|---|
| 0 | 成功 |
| 1 | 失敗（入力値の誤り、ファイルがない、アプリが起動していない など） |
| 2 | 仮想カメラ（カメラ拡張）に届かない（Activate されていない） |
| 3 | 引数の誤り（使い方が違う） |

失敗したときは、標準エラーに `error: <理由>` が1行出ます。

### 映像の切り替え

| コマンド | 成功時の出力（例） | 補足 |
|---|---|---|
| `set-source --code128 "TEXT"` | `source: Code 128 (via SimulatorCamera.app; 1 simulator app(s) connected)` | ASCII の印字可能文字のみ |
| `set-source --ean DIGITS` | `source: EAN-13 (via …)` | 1〜12桁：先頭を0で埋め、チェックデジットを付ける（`123` → `0000000001236`）。13桁：チェックデジットが違うとエラー |
| `set-source --qr "TEXT"` | `source: QR code (via …)` | |
| `set-source --image PATH` | `source: static image (via …)` | PNG / JPG。相対パス可 |
| `set-source --video PATH` | `source: video file (via …)` | 繰り返し再生。アプリが必要 |
| `set-source --camera [NAME]` | `source: mac camera (via …)` | NAME はカメラ名の一部か ID。アプリが必要 |
| `set-source --pattern` | `source: test pattern (color bar) (via …)` | バーコードなし。「何も読ませない」状態に使う |
| `sim-orientation portrait\|landscape` | `simulator frames: portrait` | iOS シミュレータに送る映像の向き |

- 出力の `N simulator app(s) connected` は、**今カメラを開いている iOS シミュレータのアプリの数**です。
- エラーの例（どれも終了コード 1）
  - `error: ean13 needs 1–12 digits (check digit added) or 13 digits with a valid check digit`
  - `error: cannot read /path/to/file.png`
  - `error: no camera matches "X" (available: …)`

### 状態の確認

| コマンド | 内容 |
|---|---|
| `status` | 1行目が `app source: …` ならアプリは起動中、`app: SimulatorCamera.app not running` なら停止中。続けてカメラ拡張の状態を出す。**カメラ拡張が有効でないと、アプリが起動していても終了コード 2** になるので、iOS だけで使う場合は JSON の `status`（3章）で確認する |
| `ping` | 仮想カメラに届けば終了コード 0 |
| `sim-status [--device UDID]` | iOS シミュレータへの注入が有効か |
| `android-list` | `virtual camera: webcam3` のように、Android エミュレータから見た仮想カメラの番号と AVD の一覧 |
| `list-cameras` | Mac のカメラの一覧（アプリが必要） |

---

## 3. JSON で操作する（127.0.0.1:47848）

`simcamctl` を使わずに、TCP で直接操作することもできます。出力を解析しやすいので、プログラムから使う場合はこちらが便利です。

- 1回の接続で1つの要求を送ります。JSON を1行、改行で終えて送ると、JSON が1行返ってきて接続が閉じます。
- Mac の中（127.0.0.1）からだけ受け付けます。
- アプリが起動していないと接続できません。

```bash
printf '{"command":"status"}\n' | nc -w 5 127.0.0.1 47848
# {"ok":true,"source":"test pattern (color bar)","simulatorApps":1,"orientation":"portrait","framesPushed":0,"lastError":null}
```

| 要求 | 返り値 |
|---|---|
| `{"command":"status"}` | `source`、`simulatorApps`（カメラを開いている iOS アプリの数）、`orientation`、`framesPushed`、`lastError` |
| `{"command":"set-source","kind":"code128","payload":"4570000011"}` | `{"ok":true,"source":"Code 128","simulatorApps":1}` |
| `{"command":"set-source","kind":"ean13","payload":"4901234567894"}` | 同上 |
| `{"command":"set-source","kind":"qr","payload":"https://example.com"}` | 同上 |
| `{"command":"set-source","kind":"image","path":"/abs/path.png"}` | `path` は絶対パス |
| `{"command":"set-source","kind":"video","path":"/abs/path.mov"}` | 同上 |
| `{"command":"set-source","kind":"camera","device":"USB"}` | `device` は省略可 |
| `{"command":"set-source","kind":"pattern"}` | テストパターン |
| `{"command":"set-orientation","orientation":"landscape"}` | `portrait` / `landscape` |
| `{"command":"list-cameras"}` | `cameras: [{id, name, selected}]` |

失敗すると `{"ok":false,"error":"…"}` が返ります。
iOS シミュレータへの注入（`sim-*`）と Android（`android-*`）は、`simcamctl` でだけ操作できます。

---

## 4. iOS シミュレータでの手順

アプリが起動していれば、起動したシミュレータには注入が自動で有効になります。そのあとに起動したアプリでは、カメラが SimulatorCameraEx の映像になります。

```bash
open -g /Applications/SimulatorCamera.app            # 1. アプリを起動（「1. 基本ルール」の待ち方も参照）
xcrun simctl boot <UDID>                             # 2. シミュレータを起動（起動済みなら不要）
$SIMCAMCTL sim-status --device <UDID>                # 3. "injection: enabled" を確認（数秒かかることがある）
$SIMCAMCTL set-source --code128 "4570000011"         # 4. 読ませたい映像を選ぶ
xcrun simctl launch <UDID> <bundle id>               # 5. テストするアプリを起動し、カメラ画面を開く
# 6. アプリの画面や状態で、4570000011 を読み取ったかを確認する
```

- 自動有効化より前に起動していたアプリには効きません。`xcrun simctl terminate <UDID> <bundle id>` で終了してから起動し直してください。
- 自動有効化に頼らない場合は、`$SIMCAMCTL sim-enable --device <UDID>` で有効にします（シミュレータを再起動すると解除されます）。1回の起動だけで使うなら `$SIMCAMCTL sim-launch <bundle id> [--url URL] --device <UDID>` です。
- **カメラが開いたことの確認**：`status` の `simulatorApps` が 1 以上になれば、アプリがカメラを開いています。
- 映像の切り替えは、アプリがカメラを開く前でも後でも構いません。
- 縦画面のアプリは `portrait`（既定）、カメラを横向きで扱うアプリは `landscape` にします（`sim-orientation`）。

### iOS で対応していないこと
- 写真撮影（`AVCapturePhotoOutput`）。expo-camera の `takePictureAsync` は、シミュレータでは独自のダミー画像を返します。
- 前面と背面の区別。どちらのカメラを選んでも同じ映像です。
- ズーム・フォーカス・フラッシュの反映。

---

## 5. Android エミュレータでの手順

Android エミュレータは、Mac の仮想カメラ「SimulatorCamera Virtual」を背面カメラとして使います。Android 側への注入はありません。バーコードは、テストするアプリ自身（ML Kit、ZXing など）が映像から読み取ります。

```bash
open -g /Applications/SimulatorCamera.app                        # 1. アプリを起動
$SIMCAMCTL android-launch <AVD名>                                 # 2. 仮想カメラを背面カメラにして起動
SERIAL=emulator-5554                                             #    ポートを変えていなければこの名前（`$ADB devices` で確認）
$ADB -s $SERIAL wait-for-device
until [ "$($ADB -s $SERIAL shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 2; done   # 3. 起動完了を待つ
$SIMCAMCTL set-source --code128 "4570000011"                     # 4. 読ませたい映像を選ぶ
$ADB -s $SERIAL shell am start -n <package>/<activity>           # 5. テストするアプリを起動し、カメラ画面を開く
# 6. アプリの画面や状態で、4570000011 を読み取ったかを確認する
```

- **カメラは、エミュレータの起動時に決まります。** すでに起動している AVD は `$ADB -s $SERIAL emu kill` で終了し、終了を待ってから `android-launch` し直してください。起動中の AVD に `android-launch` すると、`error: '<AVD名>' is already running. …`（終了コード 1）になります。
- Android Studio の ▶ や `emulator` コマンドで直接起動すると、カメラはエミュレータ標準の VirtualScene になります。必ず `android-launch` で起動してください。
- Android の実機がつながっていると、`adb` は `-s` で対象を指定しないと失敗します。
- エミュレータのログは `~/Library/Logs/SimulatorCamera/emulator-<AVD名>.log` に出ます。
- **カメラが開いたことの確認**：`$ADB -s $SERIAL shell dumpsys media.camera | grep "Camera ID"` で、開いているカメラが表示されます。
- 前面カメラはエミュレータの内蔵ダミー（ドット絵の風景）です。前面カメラを使うアプリでは `android-launch <AVD名> --front` で起動します。
- 仮想カメラ向けの QR・バーコードは、Android のアプリに届く範囲（横長の映像の中央 3:4）に収まる大きさで描かれます。

---

## 6. 読み取り結果の確認のしかた

- このツールは、読み取った結果をテストする側には返しません。アプリの画面遷移や表示内容、ログで確認してください。
- 期待どおりにならないときは、次の順で切り分けます。
  1. `set-source` の終了コードが 0 か
  2. アプリがカメラを開いているか（iOS：`simulatorApps` が 1 以上、Android：`dumpsys media.camera`）
  3. 画面にバーコードが映っているか（`xcrun simctl io <UDID> screenshot shot.png`、`$ADB -s $SERIAL exec-out screencap -p > shot.png`）
  4. 同じ値を続けて読ませていないか（「1. 基本ルール」の 4）

---

## 7. つまずきやすい点

| 症状 | 原因と対処 |
|---|---|
| iOS アプリのカメラが真っ黒・カメラなし | 注入が効いていません。アプリを起動した状態で、テストするアプリを終了してから起動し直してください。`sim-status` で確認できます |
| iOS で、選んだ映像ではなくカラーバーが映る | Mac アプリから映像が届いていません。アプリが起動しているか、`status` で確認してください |
| Android にドット絵の風景が映る | 前面カメラが開いています。アプリで背面カメラを使うか、`--front` 付きで起動し直してください |
| Android に VirtualScene（3D の部屋）が映る | `android-launch` 以外の方法で起動しています |
| `android-list` が `virtual camera: not found` | カメラ拡張が有効になっていません（「0. 前提」） |
| `set-source --ean` が終了コード 1 | 13桁のチェックデジットが違います。12桁で渡すと自動で付きます |
| 1回目は読めるが、同じ値の2回目が読めない | アプリ側で重複をまとめています。間に `--pattern` を挟んでください |
