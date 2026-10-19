[English](SECURITY.md) · [Português](SECURITY.pt-BR.md) · [Español](SECURITY.es.md) · [Français](SECURITY.fr.md) · [Deutsch](SECURITY.de.md) · [简体中文](SECURITY.zh-Hans.md) · **日本語** · [한국어](SECURITY.ko.md)

# セキュリティポリシー

MacSpaceは、macOS用の無料のオープンソース（MIT）Appです。通常のユーザアカウントで動作します。管理者権限が
必要な少数の処理には、1回承認するだけの特権ヘルパーを使います。あなたに関するデータは一切収集しません。
この文書では、MacSpaceがMac上の何に触れるのか、そして問題をどう報告するのかを正確に説明します。

## 脆弱性の報告

GitHubのプライベートな脆弱性報告を使ってください：
[脆弱性を報告](https://github.com/1architect/macspace-releases/security/advisories/new)。
または、詳細と再現手順を添えて **dev@giomantovani.com.br** にメールしてください。セキュリティに関する報告のために
公開のissueを作成しないでください。数日以内に受領の連絡をします。

対象となるもの：他のプログラムがヘルパーに意図しない操作をさせられること、MacSpaceが削除または変更すべきでない
ものを削除または変更してしまうこと、リリースの署名なしでアップデートがインストールされてしまうこと。

## サポート対象のバージョン

セキュリティ修正は最新のリリースにのみ反映されます。常に[Releases](https://github.com/1architect/macspace-releases/releases/latest)
の最新バージョンに、**アップデートを確認…**、または`brew upgrade --cask macspace`（Homebrewがスキップする場合は
`--greedy`を付けてください。MacSpaceは自身でアップデートするためです）でアップデートしてください。

## MacSpaceがMac上で行うこと

### ネットワーク

MacSpaceがネットワークに接続する目的は、アップデートだけです。**アップデートを確認…**（または設定の**今すぐ確認**）を
選んだとき、および**アップデートを自動確認**をオンにしている場合は実行中におよそ1日1回、GitHub上のリリースと一緒に
ホストされているアップデートフィード（`appcast.xml`）を読み取ります。アップデートを承諾すると、GitHub Releasesから
新しいバージョンをダウンロードします。あなたに関する情報は何も送信されず、Sparkleのオプションのシステム
プロファイルもオンになっていません。

解析も、テレメトリも、クラッシュレポートもありません。詳細は[プライバシーポリシー](PRIVACY.ja.md)をご覧ください。

### データの保存場所

すべてMacの中にとどまります。MacSpaceのファイルは、`~/Library/Application Support/MacSpace/`、
`~/Library/Logs/MacSpace/`、環境設定ファイル`~/Library/Preferences/com.macspace.app.plist`、そしてヘルパーが
書き込むものについては`/Library/Application Support/MacSpace/`にあります。[プライバシーポリシー](PRIVACY.ja.md)に
各ファイルが載っています。どれもどこにもアップロードされません。

### MacSpaceが削除するもの

| 対象 | 場所 | 実行者 |
|---|---|---|
| 終了しているAppのキャッシュ | ユーザごとのシステムキャッシュフォルダ（`/var/folders/…/C`）。Apple自身のものは除く。`~/Library/Application Support`内のChromiumまたはElectronのプロファイルにある`Cache`、`Code Cache`、`GPUCache`、`DawnCache`、`DawnGraphiteCache`、`DawnWebGPUCache`、`GrShaderCache`、`ShaderCache`、`CachedData`の各フォルダ。 | App（あなたとして） |
| 7日より古い診断レポートとクラッシュレポート | `/Library/Logs/DiagnosticReports`と`~/Library/Logs/DiagnosticReports`。削除する権限のないファイルはスキップされます。 | App（あなたとして） |
| 未使用のシステムアセット、解放されたApple Intelligenceのモデル、Appが消去可能とマークしたファイル | macOS自身の消去サービス（CacheDelete）。MacSpaceは短時間だけ存在する子プロセスで依頼するため、そこでの失敗でAppが落ちることはありません。 | macOS |
| クラウドファイルのローカルコピー | 一度に1つのクラウドフォルダ（`~/Library/CloudStorage/…`またはiCloud Drive）。アップロード済みで競合のないファイルのみ。ファイルはクラウドに残ります。 | App（あなたとして） |
| 書類のバージョン履歴 | `/System/Volumes/Data/.DocumentRevisions-V100` | ヘルパー |
| macOSアップデートの残りファイル | `/System/Volumes/Data/macOS Install Data`。インストール済みのシステムより古い場合のみ。`Locked Files`フォルダは残ります。 | ヘルパー |
| 未完了の壁紙とスクリーンセーバーのダウンロード | `/private/var/folders/*/*/T/com.apple.idleassetsd`の直下にある、3日間変更されていない`CFNetworkDownload_*.tmp`ファイル。通常のファイルのみ：リンクとサブフォルダは拒否されます。 | ヘルパー |
| macOSがAppを検証したときに作ったコピー | `/var/folders/…/X/<app>.code_sign_clone`。独自の容量（古いバージョンのもの）を占めていて、Appが終了しており、そこから何も実行されていない場合のみ。 | App（あなたとして） |
| システムログ | `/private/var/db/diagnostics`と`/private/var/db/uuidtext`。Apple自身の`log erase --all`と`log erase --uuidtext`を使用。 | ヘルパー |
| クラッシュレポートのシンボル | `/System/Library/Caches/com.apple.coresymbolicationd`の中身すべて（フォルダは残ります）。その後、容量が戻るように`coresymbolicationd`を停止します。macOSがキャッシュを再構築します。 | ヘルパー |
| ゴミ箱 | `~/.Trash`の中身すべて。ロックされた項目や他のアカウントの項目は残ります。 | App（あなたとして） |
| Time Machineのローカルスナップショット | `tmutil deletelocalsnapshots <date>`を1つの日付ずつ：最新のものと、最新のバックアップのものを除くすべて。バックアップの実行中は行いません。 | App（あなたとして） |
| Time Machineのバックアップディスク上のバックアップ | `tmutil delete`。あなたが選んだもので、最新のものは対象外。Time Machineが使用している接続中のディスク上のもの。バックアップの実行中は行いません。 | ヘルパー |

ゴミ箱に移されるものはありません。キャッシュ、システムアセット、消去可能なファイルは、必要になれば再構築または
再ダウンロードされ、クラウドのコピーはファイルを開くと再ダウンロードされます。レポート、バージョン履歴、アップデートの
残りファイル、システムログ、ゴミ箱の項目、スナップショット、バックアップは元に戻りません。これらはすべて、
個々のAppのキャッシュの**解放**ボタンを除き、先に確認を求めます。

### MacSpaceが変更するもの（Debloat）

各変更はまずジャーナルに書き込まれるため、**すべて有効にする**か、機能を再びオンにすることで元に戻せます。

| スイッチ | 変更内容 | 実行者 |
|---|---|---|
| パーソナライズされた広告 | `com.apple.AdLib`、キー`allowApplePersonalizedAdvertising` | App（あなたとして） |
| Siriと音声入力の改善 | `com.apple.assistant.support`、キー`Siri Data Sharing Opt-In Status` | App（あなたとして） |
| クラッシュレポートのダイアログ | `com.apple.DiagnosticsReporter`と`com.apple.ReportGPURestart`のlaunchd上書き | App（あなたとして） |
| 解析をAppleと共有（macOSのリリース版） | `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`、キー`AutoSubmit`と`ThirdPartyDataSubmit` | ヘルパー |
| Siri AI、ビジュアルインテリジェンス | `/Library/Preferences/FeatureFlags/Domain/`内の機能フラグの上書き | ヘルパー |
| ハングの追跡（tailspin） | `tailspin disable`、元に戻すときは`tailspin enable` | ヘルパー |
| ポリシー（5つ。macOSのベータ版では6つ） | 1つの構成プロファイル`com.macspace.policies`（下記参照） | システム設定であなたが承認 |

Appをスイッチを戻さずに削除すると、これらの変更はそのまま残ります。

### Apple Intelligence

**Apple Intelligence**のスイッチは、`com.apple.assistant.backedup`のキー`Session Language`、つまりSiriの
言語を変更します。オフにすると、Siriにはシステムとは別の言語が設定され、Siriの声（`Output Voice`）はそのままです。
MacSpaceは両方を`~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json`に保存し、Apple
Intelligenceをオンにしたとき、または変更が反映されなかったときに復元します。スイッチをオフにした後もmacOSが
モデルを保持している場合、MacSpaceはmacOSに解放させるため、言語をシステムの言語に設定してから元に戻すことが
あります。これには約1分かかります。SiriのiCloud同期がオンの場合、これらの変更は同じApple Accountの他の
デバイスにも反映されます。MacSpaceはその同期をオフにできません。オフにする場所を案内します。

### 通話の文字起こし

SiriとApple Intelligenceにある通話の文字起こしのスイッチは、`/Library/Preferences/FeatureFlags/Domain/TelephonyUtilities.plist`
にある5つの固定のTelephonyUtilities上書きを使います：通話の録音、通話スクリーニング、FaceTimeの字幕の配信、および
Macでの音声／ビデオ翻訳のゲートです。認証されたヘルパーは、変更を書き込む前に元のエントリを
`/Library/Application Support/MacSpace/phone-features.json`に保存します。変更は再起動後に反映され、動作中のゲートは
別途確認されます。再び有効にすると、関係のない上書きを保ったまま、それらの元のエントリを復元します。ヘルパーは、
MacSpaceの外で変更されたエントリを上書きせずに拒否します。このコントロールは構成プロファイルをインストールせず、
SiriのSession Languageも変更しません。そのヘルパー操作は、オン／オフの指示だけを受け付け、任意のパス、ドメイン、
キーは受け付けません。

### 機能のモデル

Siriと空間写真のスイッチは、機能を無効にする前に元の設定を保存します。Siriの保存済みの声は、Siriがオフの間は
クリアされ、そのSession Languageは保持されます。通話の文字起こしは、ローカルの録音、スクリーニング、字幕の
設定も無効にします。元の設定は`~/Library/Application Support/MacSpace/feature-settings/`に保存されます。

モデルのリクエストは、それを所有するAppleのフレームワークを通じて、あなたとして動作する別のMacSpaceプロセスで
解放され、Appやヘルパーの中で行われることはありません。そのプロセスは、各メソッドを呼び出す前に、MacSpaceが
確認したメソッドと照合し、違いがあれば停止します。ロールバック用のオブジェクトは、あなただけが読み取れる形で
`~/Library/Application Support/MacSpace/asset-owners/`に保存されます。これらの機能と言語モデルのクリーンアップは、
稼働中のサブスクリプションデータベースを編集したり、モデルの実体を直接削除したりすることは決してありません。
物理的なクリーンアップには、既存の保護付きmacOSクリーンアップサービスを使います。Apple Intelligenceの状態が
読み取れない間、およびApple IntelligenceがオンのときにmacOSがシステムアセットをダウンロードしている間は待機し、
音声入力が有効な間は他のアカウントのリクエストと共有の音声モデルを残します。未使用の言語データは、Apple
Intelligenceがオフのときにだけ解放されます。

MacSpaceが開いている間、明示的に無効にされた機能は5分ごとに確認され、macOSが再びモデルを要求した場合は未使用の
モデルが再度クリーンアップされます。機能を再び有効にするか、MacSpaceのアンインストーラを使うと、保存された設定と
モデルのリクエストが復元され、macOSはモデルを再ダウンロードすることがあります。中断された、または競合する所有者の
操作は、再リクエストの前に確認されます。これらのコントロールはmacOS 27のすべてのリリースで動作します。各リクエストの前に、
別プロセスが呼び出すAppleのメソッドを確認します。システムデータの未使用の言語アセットは1回限りのクリーンアップを
使い、その操作でスペルチェックや辞書が無効になることはありません。

### 権限

各プロンプトはmacOSが処理するため、MacSpaceがパスワードを目にすることはありません。

| 権限 | 場所 | MacSpaceの用途 |
|---|---|---|
| フルディスクアクセス | システム設定 > プライバシーとセキュリティ | macOSが保護するフォルダの計測と、Apple Intelligenceの状態の読み取り |
| 特権ヘルパー | システム設定 > 一般 > ログイン項目と機能拡張 | 以下の処理 |
| 構成プロファイル | システム設定 > 一般 > デバイス管理 | Debloatのポリシーを無効にするときのみ |
| 通知 | macOSが確認します | 処理が終わったことをお知らせするため |

### 特権ヘルパー

ヘルパーは起動デーモン`com.macspace.helper`で、Appの内部からmacOSに登録されます。MacSpaceが何かを依頼すると、
launchdが起動します。rootとして動作し、次のコード署名要件を満たすプログラムからの接続だけを受け付けます。
この要件はmacOSが確認します：

```
anchor apple generic and (identifier "com.macspace.app" or identifier "com.macspace.cli")
and certificate leaf[subject.OU] = "<the developer's team ID>"
```

要件がない場合は起動を拒否します。内蔵された名前付きの処理だけを実行します。呼び出し元がコマンドを送ることは
できません。Appがアップデートで置き換えられると、ヘルパーはそれに気づいて終了し、新しいものが起動できるようにします。

| 処理 | 内容 | 制限 |
|---|---|---|
| `systemdata.measure` | フォルダのサイズ | 読み取り専用。`/private/var`、`/private/tmp`、`/Library`、`/System/Library`、Dataボリュームのルート、`/opt`の下のみで、ホームフォルダは対象外。サイズのみで、内容は読みません。 |
| `systemdata.versions.delete` | 書類のバージョン履歴を削除 | 最初に`revisiond`を停止し、macOSが拒否した場合は一時停止します。フォルダではなくストアの中身を削除し、その後`revisiond`を再び起動します。停止できなければ何も削除しません。 |
| `systemdata.staged-update.delete` | アップデートの残りファイルを削除 | フォルダがインストール済みのシステムより古い場合のみ。`Locked Files`は残します。 |
| `systemdata.wallpaper-downloads.delete` | 未完了の壁紙とスクリーンセーバーのダウンロードを削除 | パスを受け取りません：`/private/var/folders/*/*/T/com.apple.idleassetsd`を自分で見つけ、リンクをたどりません。その直下にある、3日間変更されていない`CFNetworkDownload_*.tmp`という名前の通常のファイルだけを削除します。 |
| `systemdata.unified-log.erase` | システムログを消去 | 引数を受け取りません。Appleの`/usr/bin/log erase --all`を実行し、その後`log erase --uuidtext`を実行するだけです。 |
| `systemdata.symbolication-cache.delete` | クラッシュレポートのシンボルを削除 | 引数を受け取りません。`/System/Library/Caches/com.apple.coresymbolicationd`のみで、リンクをたどらずに開き、中身を削除し、フォルダは決して削除しません。その後`coresymbolicationd`を停止します（`kill -TERM`、5秒後に`-KILL`）。 |
| `timemachine.backups.delete` | Time Machineのバックアップディスクからバックアップを削除 | Time Machineが接続中として挙げるディスクのみ、そこで自分で見つけた日付のみ、最新のバックアップは対象外、バックアップの実行中や不明な間は行いません。`/usr/bin/tmutil delete`を実行します。 |
| `debloat.status`、`.apply`、`.revert` | Debloatの項目の読み取り、オフ、オン | 内蔵カタログのコントロール識別子のみ。ほかには何もしません。 |
| `debloat.removeProfile` | MacSpaceのプロファイルを削除 | 識別子`com.macspace.policies`と`com.macspace.policies.…`のみ。他のプロファイルは拒否されます。 |
| `siri.orphan-subscriptions.plan`、`.execute` | 存在しなくなったアカウントのApple Intelligenceのサブスクリプションを検出して削除 | 最初にデータベースを`/Library/Application Support/MacSpace/backups/`にバックアップし、1回のトランザクションで変更し、ローカルのどのアカウントにも一致しない行にだけ触れ、アカウント一覧がおかしく見える場合は拒否します。Appにはまだこのためのボタンがありません。 |
| `helper.ping` | 応答して、ヘルパーが動いていることをAppに知らせる | なし |

Appバンドル内のコマンドラインツール`MacSpaceCli`も、ヘルパーと通信できます。同じチームで署名されています。

### 構成プロファイル

Debloatのポリシーは、構成プロファイルでしか強制できない設定です。MacSpaceは、オフにしたすべてのポリシーを含む
プロファイル`com.macspace.policies`（**MacSpace: policies**として表示、組織は「MacSpace」）を1つ作成します。
プロファイルを開くと、システム設定 > 一般 > デバイス管理であなたが承認します。承認すると、以前のものが置き換えられます。
削除できないようには設定されていません。最後のポリシーを再びオンにすると、承認の必要なしに、ヘルパーを通じて
削除されます。システム設定で自分で削除することもできます。

### コード署名とアップデート

MacSpaceはApple Developer IDで署名され、ハードンドランタイムが有効で、Appleによって公証されています。
公証チケットはAppにステープルされているため、オフラインでも開けます。Sparkle自身のコンポーネントも
同じIDで署名されています。

アップデートもEdDSA鍵で署名されます。その公開鍵はMacSpaceの内部（`SUPublicEDKey`）にあり、Sparkleは
インストールの前にすべてのダウンロードをそれと照合します。その鍵の秘密鍵と署名IDは、このリポジトリには
ありません。公開鍵なしでビルドされたMacSpaceは、アップデートを確認しません。

## ダウンロードの検証

`MacSpace-x.y.z.dmg`と`MacSpace-x.y.z.dmg.sha256`を同じフォルダに置きます：

```bash
shasum -a 256 -c MacSpace-x.y.z.dmg.sha256
```

その後、MacSpaceを「アプリケーション」にドラッグしたら：

```bash
codesign -dv --verbose=4 /Applications/MacSpace.app
codesign --verify --deep --strict --verbose=2 /Applications/MacSpace.app
spctl -a -vv /Applications/MacSpace.app
xcrun stapler validate /Applications/MacSpace.app
```

`Authority=Developer ID Application`、`TeamIdentifier=J45ZXS2ZF6`、`runtime`フラグ、
`Notarization Ticket=stapled`が表示され、`spctl`が`accepted`と`source=Notarized Developer ID`を示すはずです。

## 完全にアンインストール

MacSpaceにはアンインストーラがあります：メニューバーで**MacSpace** > **MacSpaceについて**を選び、**アンインストール…**を
選びます。各モジュールの設定を復元し、ヘルパーを削除して、MacSpaceをゴミ箱に移動します。手動で行う場合の
完全な手順は[README](README.ja.md#アンインストール)にあります。要点は次のとおりです：

1. **Debloat**で**すべて有効にする**を押します。これで上書き設定と、それが作成したプロファイルが削除されます。
2. プロファイル**MacSpace: policies**がシステム設定 > 一般 > デバイス管理にまだ残っている場合は、削除します。
3. MacSpaceを終了します。システム設定 > 一般 > ログイン項目と機能拡張でオフにするか、
   `/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --unregister`を実行します。
4. Appを削除します：`brew uninstall --cask macspace`、または**MacSpace**をゴミ箱にドラッグします。
5. データと設定を削除します：
   ```bash
   rm -rf ~/Library/Application\ Support/MacSpace ~/Library/Logs/MacSpace ~/Library/Caches/com.macspace.app
   defaults delete com.macspace.app
   sudo rm -rf /Library/Application\ Support/MacSpace
   ```
6. システム設定 > プライバシーとセキュリティ > フルディスクアクセスからMacSpaceを削除します。
