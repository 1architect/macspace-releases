[English](../../../PRIVACY.md) · [Português](../pt-BR/PRIVACY.md) · [Español](../es/PRIVACY.md) · [Français](../fr/PRIVACY.md) · [Deutsch](../de/PRIVACY.md) · [简体中文](../zh-Hans/PRIVACY.md) · **日本語** · [한국어](../ko/PRIVACY.md)

# プライバシーポリシー — MacSpace

**最終更新：2026年10月19日 · MacSpace 1.0.0以降に適用**

MacSpaceは、使用状況のデータを収集、保存、送信することは一切ありません。解析も、テレメトリも、
クラッシュレポートも、広告もありません。MacSpaceにはアカウントの仕組みがないため、プロファイルを
作成したりサインインしたりする必要はありません。

この文書では、MacSpaceが何を読み取り、それをどこに保存し、ネットワークを使うのがどの場面だけなのかを
正確に説明します。

---

## Macに残るもの

MacSpaceはディスクを計測し、いくつかのシステム設定を読み取り、お使いのMacに小さなファイルをいくつか
書き込みます。そのどれもMacの外には出ません。

| データ | 保存場所 |
|---|---|
| 設定：テーマ、ウインドウの選択、オンのモジュール、モジュールのオプション、自動クリーンアップ、通知の選択、各モジュールが最後に表示したタイル、初回起動のステップ | MacSpaceのmacOS環境設定（`UserDefaults`）、`~/Library/Preferences/com.macspace.app.plist` |
| Sparkle自身の設定：アップデートを自動確認するかどうか、最後に確認した日時 | 同じ環境設定ファイル |
| クリーンアップの履歴：日時、モジュール、解放した容量、開始方法、1行の概要 | `~/Library/Application Support/MacSpace/cleanup-history.json` |
| MacSpaceが解放を依頼したにもかかわらずmacOSが保持した容量 | `~/Library/Application Support/MacSpace/purge-holdouts.json` |
| Debloatのジャーナル：MacSpaceが変更した各設定、変更前後の値、macOSのビルド、日時 | `~/Library/Application Support/MacSpace/debloat-journal.json`、ヘルパーが行った変更は`/Library/Application Support/MacSpace/debloat-journal.json` |
| Debloatの監視：macOSが再びオンにした機能とその日時（直近20件） | `~/Library/Application Support/MacSpace/debloat-watch.json` |
| 承認待ちの状態にあるDebloatのプロファイル | `~/Library/Application Support/MacSpace/Profiles/MacSpace.mobileconfig` |
| Apple Intelligenceがオフの間、MacSpaceが復元できるように保存するSiriの言語と声 | `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` |
| Siri、空間写真、ローカルの通話の文字起こしの元の設定（存在しない値を含む） | `~/Library/Application Support/MacSpace/feature-settings/` |
| 復元のために保存したモデル所有者のリクエスト（声や言語の選択を含む） | `~/Library/Application Support/MacSpace/asset-owners/` |
| システム全体の通話の文字起こしに関する元の上書き設定 | `/Library/Application Support/MacSpace/phone-features.json` |
| Apple Intelligenceの監視（オンにした場合のみ）：最後に確認した状態と変更のログ | `~/Library/Application Support/MacSpace/ai-watch-state.json`と`~/Library/Logs/MacSpace/ai-watch.jsonl` |
| macOSのサブスクリプションデータベースのバックアップ（削除済みアカウントに残ったApple Intelligenceのサブスクリプションを削除した場合のみ） | `/Library/Application Support/MacSpace/backups/` |
| アップデートのダウンロード | Sparkleのキャッシュフォルダ、`~/Library/Caches/com.macspace.app/` |

これらはすべて、いつでも削除できます。コマンドは[README.md](README.md#アンインストール)に
載っています。これらのファイルを削除すると、MacSpaceは履歴と設定を忘れます。Debloatのスイッチがオフの
間にDebloatのジャーナルを削除すると、MacSpaceは保存していた元の値を復元できなくなり、代わりにmacOSの
デフォルト値を使います。先に**すべて有効にする**を押してください。

### MacSpaceが読み取るもの

MacSpaceは、その役目を果たすために、Mac上の次のものを読み取ります。それらをどこにも送信しません。

- **ファイルとフォルダの名前とサイズ。** フルディスクアクセスを許可すると、ディスク全体が対象です。書類、
  写真、メール、メッセージの中身は読みません。それらが占める容量を計測します。
- **Appのキャッシュ内のファイルの日付**（`~/Library/Caches`と、フルディスクアクセスがある場合は各Appの
  コンテナ内のキャッシュフォルダ`~/Library/Containers/<app>/Data/Library/Caches`）：それぞれが作成、変更、
  または最初に読み取られた日時と、Spotlightが記録する**各Appが最後に開かれた日時**。どのキャッシュが
  使われていないかを判断するためです。ファイルは開きません。
- **Homebrew自身の見積もり**（Homebrewがインストールされている場合）：MacSpaceは、何も変更しない
  `brew cleanup -n`を、Homebrewの自動アップデートと解析をオフにして、Homebrewにパッケージ一覧がすでに
  あるときだけ実行します。そのためHomebrewがオンラインに接続することはありません。
- **いくつかのシステムファイル：** Apple Intelligenceの利用資格ファイル、macOSのアセットのサブスクリプション
  データベース、インストール済みの構成プロファイルの一覧、Apple Accountのデータベース（Siriの
  iCloud同期がオンかどうかを知るための読み取り専用）。
- **このMacのユーザアカウントの名前。** どのアカウントがApple Intelligenceをオンに保っているかを示すためです。
- **macOSの状態：** バージョンとビルド、システム整合性保護がオンかどうか、Macがデバイス管理に登録されて
  いるかどうか、実行中のプロセスの名前（Debloatのスイッチが反映されたかの確認用）、macOS自身の解析に関する
  判断を記録したシステムログの数行（解析のスイッチが機能したかの確認用）。

---

## MacSpaceがネットワークを使うとき

MacSpaceがネットワークを使う目的は1つだけ、**アップデート**です。解析も、サインインも、他の接続もありません。

### アップデートを確認するとき

MacSpaceは[Sparkle](https://sparkle-project.org)を使ってアップデートを見つけてインストールします。次の
場合にネットワークに接続します：

- MacSpaceメニューの**アップデートを確認…**、または設定の**今すぐ確認**を選んだとき。
- 自動確認がオンの場合、MacSpaceの実行中におよそ1日1回。

自動確認は、設定で**アップデートを自動確認**をオンにするか、2回目の起動以降にSparkleが1度だけ尋ねる
質問に「はい」と答えるまでオフです。それまで、MacSpaceが自分で確認することはありません。ソースから
ビルドしたものにはアップデート用の鍵がなく、確認は一切行いません。

確認では、GitHubから1つのファイルを要求します：

```
https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml
```

一般的なウェブリクエストと同様に、GitHubにはIPアドレスが見えます。リクエストには、通常の`User-Agent`
ヘッダでMacSpaceの名前とバージョン、およびSparkleのバージョンも含まれます。MacSpaceは、システムの
プロファイル、ハードウェア情報、いかなる種類の識別子も送信しません。Sparkleのオプションのシステム
プロファイルはオンにしていません。このリクエストに対するGitHubの取り扱いは、
[GitHubプライバシーステートメント](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement)に
記載されています。

アップデートを承諾すると、SparkleはGitHub Releasesからダウンロードします。すべてのアップデートには署名が
あります。Sparkleは、何かをインストールする前に、MacSpace内の公開鍵で署名を検証します。

### MacSpaceではないもの

Apple Intelligenceを再びオンにすると、macOS（MacSpaceではありません）がそのモデルをダウンロードする
ことがあります。ダウンロードしたAppを開くとき、macOSがAppleに照会することがあります。これらはmacOS
自身の接続です。

---

## MacSpaceが決して行わないこと

- ファイルの一覧、ディスクの数値、設定、クリーンアップの履歴、アカウント名を、どこにも送信しません。
- 書類、写真、メール、メッセージの内容を読み取りません。
- アカウントの作成やサインインを求めません。
- 開発者にも他の誰にも、クラッシュや使用状況を報告しません。

### 権限とヘルパーについて

MacSpaceはいくつかの承認を求めますが、それぞれmacOS自身のダイアログまたはシステム設定で行うため、
パスワードを目にすることはありません：

- **フルディスクアクセス。** ディスク上のすべてを計測し、Apple Intelligenceの状態を読み取るため。
- **特権ヘルパー。** 管理者権限が必要な少数の処理を行う起動デーモン（`com.macspace.helper`）。MacSpaceと
  同じ開発チームが署名したクライアントだけを受け付け、内蔵された処理だけを実行します。
- **構成プロファイル。** Debloatのポリシーを無効にする場合のみ。
- **通知。** 処理が終わったことをお知らせするため。

ヘルパーとプロファイルにできることは、[SECURITY.md](SECURITY.md)に記載されています。

---

## 子ども

MacSpaceはmacOS用のユーティリティであり、子どもを対象としていません。どの年齢の誰からも、個人情報を
収集しません。

## このポリシーの変更

MacSpaceの動作が変わった場合は、この文書も変更され、冒頭の日付も変わります。このファイルの履歴は
このリポジトリで公開されているため、何がいつ変更されたかを正確に確認できます。

## お問い合わせ

プライバシーについて、またはこの文書の内容についてのご質問：

**dev@giomantovani.com.br**
