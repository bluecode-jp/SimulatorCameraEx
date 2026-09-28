# リリース手順（SimulatorCameraEx）

Mac アプリ（カメラ拡張・`simcamctl`・SimCamInject 同梱）を、Developer ID で署名・公証した DMG にするまでの手順です。

署名には **クラウド管理の Developer ID 証明書** を使います。手元の Mac に Developer ID 証明書は要りません。署名と公証は Xcode の Organizer で行います。

## 前提（Mac ごとに1回）

- Xcode 16 以降（Xcode 27.0 で確認）と XcodeGen（`brew install xcodegen`）
- Xcode の Settings → Accounts に、BLUECODE,INC.（`C5TUJ8526Z`）に所属する Apple ID でサインインしていること
- App Store Connect の「ユーザとアクセス」で、その Apple ID に次の権限があること
  - 役割：管理者（Admin）
  - その他のリソース：**クラウド管理デベロッパID証明書へのアクセス**
- Developer ポータルに次の App ID があること（Xcode の自動署名で作られます）
  - `jp.co.bluecode.SimulatorCameraEx`（System Extension の権限つき）
  - `jp.co.bluecode.SimulatorCameraEx.Extension`
  - App Group `C5TUJ8526Z.jp.co.bluecode.SimulatorCameraEx` はチーム ID で始まるため、ポータルへの登録は不要です

## 1. バージョンを決める

- `project.yml` の `MARKETING_VERSION`（表示用のバージョン、例 `1.0.0`）を更新します。
- **カメラ拡張（`SimulatorCameraExtension/` や `Shared/` の拡張が使うコード）を変えたときは、`CURRENT_PROJECT_VERSION`（ビルド番号）も1つ上げます。**
  - ビルド番号が同じだと、配布先の Mac で古い拡張が使われ続けます。
  - 上げておくと、アプリの起動時に拡張が入れ替わり、アプリが自動で再起動します。
- `CHANGELOG.md` の `[Unreleased]` を `[X.Y.Z] — YYYY-MM-DD` に移します。

## 2. アーカイブを作る

```bash
./scripts/archive-release.sh
```

- Release 構成でアーカイブを作り、`~/Library/Developer/Xcode/Archives/` に置いて Organizer で開きます。
- Organizer の右側で **Type が「macOS App Archive」** になっていることを確認します。
  - 「Generic Xcode Archive」になっていると、配布方法が選べません。アプリ以外の成果物（`SKIP_INSTALL: NO` のターゲットなど）がアーカイブに入っていないか確認してください。

## 3. 署名・公証する（Organizer）

1. Organizer で今回のアーカイブを選び、**Distribute App** を押します。
2. **Direct Distribution** を選んで **Distribute** を押します。
   - クラウドの Developer ID 証明書で、アプリ・拡張・`simcamctl`・SimCamInject の dylib がすべて署名し直されます。
   - そのまま Apple に公証を申請します。数分かかります。
3. アーカイブの Status が **Ready to distribute** になれば完了です。
   - 公証済みのアプリは `<アーカイブ>/Submissions/<UUID>/SimulatorCameraEx.app` に保存されます。
   - 公証のログは同じ場所の `notarization-log.json` です。

## 4. DMG を作る

```bash
./scripts/package-dmg.sh
```

- 最新のアーカイブの公証済みアプリを使います。別のアプリを使う場合はパスを引数で渡します。
- すべての実行ファイルが Developer ID で署名されていること、公証チケットが付いていること、Gatekeeper が許可することを確認してから、次のファイルを `dist/` に作ります。
  - `SimulatorCameraEx-X.Y.Z.dmg`（アプリと /Applications へのリンク）
  - `SimulatorCameraEx-X.Y.Z.zip`
  - `SimulatorCameraEx-X.Y.Z.sha256`
- DMG 自体は署名していません（手元に Developer ID 証明書がないため）。中のアプリは公証済みなので、ダウンロードした Mac でもそのまま開けます。

## 5. 確認する

できれば、開発に使っていない Mac で確認します。

1. DMG をその Mac に渡します（AirDrop やダウンロードで渡すと、実際の配布と同じ条件になります）。
2. `SimulatorCameraEx.app` を /Applications にコピーして起動し、警告なしで開くことを確認します。
3. **Activate** を押し、「システム設定 → 一般 → ログイン項目と機能拡張」でカメラ拡張を許可します。許可するとアプリが自動で再起動します。
4. 次のコマンドで、映像が届いているか確認します。
   ```bash
   S=/Applications/SimulatorCameraEx.app/Contents/MacOS/simcamctl
   $S set-source --qr "https://www.bluecode.co.jp"
   $S status        # sink open: yes、frames received が増えていれば OK
   ```
5. iOS シミュレータでカメラを使うアプリを開き、映像とバーコード読み取りを確認します。

## 6. タグを付けて公開する

```bash
git tag -a vX.Y.Z -m "SimulatorCameraEx vX.Y.Z"
git push origin main vX.Y.Z
```

DMG・ZIP・sha256 は、GitHub の Releases（`bluecode-jp/SimulatorCameraEx`）などに置きます。

## うまくいかないとき

- **Organizer に配布方法が出ない／`exportOptionsPlist error for key "method"`**：アーカイブが macOS App Archive になっていません（手順2を参照）。
- **`No certificate for team 'C5TUJ8526Z' matching 'Developer ID Application'`**：`xcodebuild -exportArchive` をコマンドラインで実行すると、クラウド証明書が使えずにこのエラーになります。Organizer から配布してください。
- **公証が失敗した**：`notarization-log.json` の `issues` に原因が書かれています。
- **配布先で映像が届かない**：`simcamctl status` の `sink open` を確認します。`no` のままなら、アプリを一度終了して起動し直してください。

## 手元に Developer ID 証明書がある場合

Account Holder など、手元に Developer ID Application 証明書と `notarytool` の認証情報がある場合は、`scripts/build-release.sh` で、アーカイブから公証・DMG 作成までをまとめて実行できます（DMG の署名・公証も行います）。

```bash
KEYCHAIN_PROFILE=<notarytool のプロファイル名> APPLE_TEAM_ID=C5TUJ8526Z \
APPLE_DEVELOPER_ID="Developer ID Application: BLUECODE,INC. (C5TUJ8526Z)" \
VERSION=X.Y.Z ./scripts/build-release.sh
```
