# nobetsu（のべつ）

**日本語で、止まらずに、喋り続けられる音声入力。**

[変更履歴・リリースノート](CHANGELOG.md)

日本語で音声入力をすると、だいたいこうなります。

- 喋っている途中で**固まる**。変換が追いつかなくなる
- AI エージェントのマイクは**数分で切れる**。長文を一息で入れられない
- **キーを押している間しか喋れない。**離した瞬間に終わり、文字はまとめて貼りつく

nobetsu は **⌘ を 1 秒押して、離します。それだけです。**
あとは指をどこにも置かずに、好きなだけ喋り続けられます。**押しっぱなしにする必要はありません。**
止めるときに、もう一度 ⌘ を軽く叩くか ESC を押します。

話した端から、そのとき使っているアプリに文字が入ります。時間制限はありません。
日本語入力（IME）を経由しません。すべて端末内で完結し、音声も文字も外部に送信しません。

![⌘ を長押しして離すと、あとは喋った端から、使っているアプリに文字が入っていく](docs/demo.gif)

[全編を見る（26秒）](docs/nobetsu-demo.mp4)

> **のべつ幕なし** — 芝居で幕を下ろさずに演じ続けること。転じて、絶え間なく続くこと。

*English speakers: see [English](#english) below for what this is and why it exists.*

---

## なぜ日本語だけ、こうなるのか

日本語の入力は IME（日本語入力）を通ります。macOS 標準の音声入力は、認識した「よみ」を
その IME に流し込みます。IME は文脈から漢字を選ぼうとして未確定の文字を書き換え続けるので、
**喋り続けると追いつかなくなって止まります。**

**英語には変換工程がありません。**だからこの問題は英語圏では起きず、
既存の音声入力ツールのほとんどが英語圏の開発者によるものである以上、誰もここを解いていません。

nobetsu は変換工程を丸ごと迂回します。macOS 26 の `DictationTranscriber` は
漢字かな交じりの**変換済みテキスト**を返すので、それを直接打ち込みます。ぶつかる相手がいません。

### 実際に入る文章

このツールで喋って入力したものです。手直ししていません。句読点も自動で入ります。

```
なんか出ましたね。そして話せるようになりましたね。おおすげすげすげえ下にも出て
上にも出るんだ。認識もとても良いね。今 AirPods をつけていてだから多分さっきよりも
マイク入力の感度は高くて、耳元に対してマイク入力されてる感じにはなるんだと思うよね。
見てる感じでも全然何かタイプミスがなさそうな感じでいいなぁ。もうちょっと早く
しゃべってみようかな。どれぐらいで行けるだろうか。結構感動してるね。
```

誤りは 500〜670 字あたり 5〜7 箇所（およそ 1.2〜1.5%）でした。[計測結果](#計測結果)を参照してください。
残る誤変換は[辞書](#辞書で誤変換を直す)で潰していけます。

## 動作環境

| | |
|---|---|
| OS | **macOS 26 (Tahoe) 以降** |
| CPU | **Apple Silicon**（M1 以降）。Intel Mac では動きません |
| Xcode | **不要**。コマンドラインツール同梱の `swiftc` だけでビルドできます |
| コード署名 | **自己署名の証明書が要ります**（[下記](#ソースからビルドする前に1回だけ)）。Apple Developer Program は不要です |
| 依存ライブラリ | なし。すべて OS 標準のフレームワーク |
| 動作確認 | MacBook Air (M4, 2024) / macOS 26.5.2 |

M3 や M4 でなくても構いません。初回だけ日本語の認識モデルを OS がダウンロードします。
以後はオフラインで動きます。

## 入れる

### ソースからビルドする前に（1回だけ）

**自己署名の証明書を1つ作ってください。これが無いと、ビルドは通っても使えません。**

macOS の許可（入力監視・アクセシビリティ）は**署名の同一性**に紐づいて記録されます。
Apple Developer Program に入っていない Mac でそのままビルドするとアドホック署名になり、
同一性が無いため **入力監視は許可のダイアログすら出ずに拒否されます。**
⌘ を長押ししても、うんともすんとも言わないアプリができあがります。

証明書を1枚作れば、これはまるごと消えます。5分で終わる、最初の1回だけの作業です。

1. 「キーチェーンアクセス」を開く
2. メニューの「キーチェーンアクセス」→「証明書アシスタント」→「自分に証明書を作成」
3. 名前 `nobetsu` / 固有名のタイプ「**自己署名ルート**」/ 証明書のタイプ「**コード署名**」
4. できた証明書をダブルクリック →「信頼」→「コード署名」を「**常に信頼**」にする
5. 初回のビルドでキーチェーンのパスワードを聞かれたら「**常に許可**」を選ぶ

できているかは、ビルドせずに確かめられます。

```bash
./build.sh --check
```

`✅ 証明書「nobetsu」で署名できます` と出れば大丈夫です。

証明書が無いとき、`./build.sh` は**設置せずに止まります。**
動かないアプリを `/Applications` に残しても、動かない理由にたどり着けないためです。
コンパイルが通ることだけ確かめたい場合は、それと分かる形で先へ進められます。

```bash
NOBETSU_ALLOW_ADHOC=1 ./build.sh
```

> **配布された .app を使う場合、この証明書は要りません。**
> Developer ID で署名・公証されたものには、既に安定した署名の同一性があるためです。
> ただし**入力監視とアクセシビリティの許可は、どちらにせよ必要です。**
> なお、いまは配布版がありません。署名と公証には Apple Developer Program（年額）が要るためで、
> 当面はソースからビルドしてもらう方針です。

### 入れる

```bash
git clone https://github.com/pochang6/nobetsu.git
cd nobetsu
./build.sh
open /Applications/nobetsu.app
```

`./build.sh` がビルドから `/Applications` への設置までを行います。
`/Applications` に置くのは、システム設定の許可一覧がそこからしかアプリを選べないためです。

メニューバーに波形のアイコンが出ます。ウィンドウも Dock アイコンも出ません。

### 既に入れてあるものを更新する

**育てた個人辞書は、pull・ビルド・更新で上書きも削除もしません。**
公開リポジトリが更新するのはプログラムと見本です。設定と既存の辞書・リンクは引き継ぎます。

既に `update.sh` がある場合、リポジトリで次の1行を実行してください。

```bash
./update.sh
```

署名の確認 → 最新コードの取得（fast-forward のみ）→ ビルド → 辞書の退避 →
アプリの入れ替え → 再起動 → 新しい版のキー監視の確認まで行います。
追跡ファイルに変更がある場合や辞書を退避できない場合は中止します。勝手な reset や stash はしません。
リンク先の消失や引き継ぎ記録の JSON 破損は、残っているデータを退避して更新を続け、起動後のメニューに案内を出します。
新しいアプリの設置・起動確認に失敗したら旧アプリへ戻します（ソースのコミットは戻しません）。
終了や復元ができない場合は旧アプリの退避先を表示して残します。終了を確認してから復旧してください。

旧版から初めて取り込む場合は次の2行です。

```bash
git pull --ff-only
./build.sh --restart
```

`git pull` だけでは動いているアプリは更新されません。
従来の `git pull` → `./build.sh` → `open /Applications/nobetsu.app` も使えますが、
起動確認まで自動で行うには `--restart` を付けてください。
署名の同一性を保つので、同じ証明書を使う限り許可の付け直しは不要です。
更新内容は [変更履歴](CHANGELOG.md) を参照してください。

### 必要な許可

**入力監視とアクセシビリティは、別々の許可です。**片方だけでは動きません。
初回に順番に求められるので、macOS 標準のダイアログでそのまま許可してください。

| 許可 | 何の許可か | 聞かれる場面 |
|---|---|---|
| **入力監視** | **キーを読む**許可。⌘ の長押しを待ち受ける | 起動した直後 |
| **アクセシビリティ** | **他のアプリへ文字を入れる**許可 | 入力監視のあと |
| **マイク・音声認識** | 音声を文字にする | 初めて喋るとき |

順番は必ず 入力監視 → アクセシビリティ です。逆にすると入力監視の要求そのものが通らなくなる、
macOS 側の不具合があるためです。**入力監視が下りない限り、アクセシビリティの要求へは進みません。**

**許可が無い間は、⌘ を長押ししても何も起きません。**そこで許可を聞かれることもありません。
足りていないときはメニューバーのアイコンが**警告の三角**になり、
メニューを開くと「何が足りないのか」「それは何の許可か」「どの設定画面を開けばよいか」が出ます。
ダイアログを閉じてしまった場合も、そこからやり直せます。

許可は「そのパスにあるアプリ」に付きます。設定の一覧で選ぶのは
`/Applications/nobetsu.app` です（リポジトリの中でビルドしたものとは別扱いになります）。

## 使う

| 操作 | 動き |
|---|---|
| **⌘ を長押し**（既定1.0秒） | 認識が始まる。指を離しても続く |
| **もう一度 ⌘ を軽く叩く** | 停止 |
| **ESC** | 停止 |
| 目印の停止ボタンをクリック | 停止 |

開始と終了は音で知らせます。画面を見ていなくても状態が分かります。

⌘ は macOS のあらゆるショートカットの起点ですが、
**⌘ を押している間に他のキーやクリック、ホイールが来たら、それはショートカットだと見なして発火しません。**
⌘Tab や ⌘S でためらっても、⌘＋ホイールで拡大縮小しても暴発しません。
長押し時間は0.5〜2.0秒の範囲で0.1秒ずつ調整できます。
開始に使うキーも、左右・左だけ・右だけから選べます。

### 設定

メニューバーのアイコンから開きます。

| 項目 | 既定 | 何が起きるか |
|---|---|---|
| ログイン時に起動 | **入** | Mac を起動したら自動で常駐します。切ると毎回自分で開くことになります |
| 開始と終了を音で知らせる | **入** | 聞ける状態になった瞬間に開始音、止めた瞬間に終了音。画面を見ていなくても状態が分かります。会議中など、音を出したくないときは切ってください |
| 認識中の目印を出す | **入** | 認識中に小さな目印が浮きます。声の大きさも出るので、マイクが拾えているかが分かります。ドラッグで好きな場所へ動かせます |
| 認識中の文字を画面に流す | 切 | 認識中の文字を画面上に大きく流します。**入力先の文章と重なって読みにくくなる**ので既定は切です |
| 開始までの長押し | **1.0秒** | 0.5〜2.0秒の範囲を0.1秒刻みで調整します。コピーや貼り付けの次のキーを押すまで迷っても発火しにくいよう、以前の0.5秒から既定を延ばしました |
| 開始に使う ⌘ | **左右どちらでも** | 「左だけ」「右だけ」に絞れます。ここで選ぶのは開始キーだけで、停止は左右どちらの⌘でもできます |
| 入力先から離れたら止める | **入** | 別のアプリや別の画面へ移った時点で止まります（[下記](#入力先から離れたら止める)）。切ると、どこへ移っても喋り続けられます |
| 遠距離マイク補正 | **入** | マイクから離れて話す前提で認識します。マイクを口元に近づけて使う場合は切ってください。認識中は変更できません |
| 辞書を編集する | — | 個人辞書をテキストエディタで開きます。無ければ雛形を作ります |

認識中は、目印の「…」からもよく使うものだけ触れます。

| 項目 | 何が起きるか |
|---|---|
| 開始と終了を音で知らせる | 上と同じ |
| 認識中の文字を画面に流す | 上と同じ |
| 入力先から離れたら止める | 上と同じ |
| 開始までの長押し | 上と同じ。スライダーで調整できます |
| 開始に使う ⌘ | 上と同じ。左右・左だけ・右だけから選べます |
| 辞書を編集する | 上と同じ |
| 目印を出す画面 | 既定は入力欄の画面へ自動で移動。「この画面に固定」、または接続中の画面を選んで固定できます |
| この目印の位置を初期状態に戻す | ドラッグで動かした位置を忘れ、既定の場所へ戻します |
| 音声入力を止める（ESC） | 認識を終えて目印を閉じます。ESC でも同じです |

目印そのものには、一時停止（**Ⅱ**）と終了（**×**）のボタンもあります。
一時停止は目印を残したまま認識だけ止めるので、そのまま再開できます。

### 入力先から離れたら止める

既定では、**喋っている途中で別のアプリや別の画面へ移ると、そこで止まります。**

始めたことを忘れたまま席を移ると、独り言がそのまま同僚宛の入力欄へ流れ込みます。
起きたときの代償が大きいので、安全な側に倒しています。

同じアプリの中で別の入力欄へ移っただけなら止まりません。設定を開いている間も止まりません。
**自分で止めたときとは違う音が鳴ります。**押していないのに終わるので、
同じ音では何が起きたのか分からないためです。止まった理由はメニューにも残ります。

一日中つけっぱなしにして、あちこちで喋りたい場合は切ってください。

## 目印と仮想デスクトップ

既定では、目印はフォーカス中の入力欄がある画面へ追従します。画面内の位置は従来どおり、
ドラッグで決めた左下からの距離を保ちます。入力欄の移動やスクロールだけでは位置を変えません。
小さな画面へ移った場合は、画面外にはみ出さないように収めます。
入力欄の座標をアプリが提供しない場合は、前面ウィンドウのある画面、次にマウスのある画面を使います。
Space・フルスクリーンの切り替え後も表示を更新します。目印が入力フォーカスを奪うことはありません。

**出す画面を固定したいとき**は、目印の「…」→「目印を出す画面」で「この画面に固定」を選びます。
接続中の画面を一覧から選ぶこともできます。ドラッグは画面内の位置だけを調整し、固定先は変えません。
固定設定は再起動後も保持します。固定先が未接続の間は自動で入力欄の画面を選び、再接続すると固定先へ戻ります。
解除するには、同じメニューで「入力欄の画面へ自動で移動」を選んでください。
「この目印の位置を初期状態に戻す」は画面内の位置だけを初期化し、固定設定は保ちます。

「入力先から離れたら止める」が有効な場合、Space やアプリの切り替えでは従来どおり音声入力を止めます。
無効にして使い続ける場合、自動選択中は新しい入力先へ目印が追従します。画面固定中は固定先に表示し続けます。

## AirPods で動画を見ながら使うとき

**赤い録音表示が出ている間は、黙っていてもマイクを使い続けています。**
音声を待ち受けるためであり、録音を停止した待機状態とは異なります。

AirPods の耳元操作は、マイク使用中に再生・一時停止ではなくミュート操作として扱われる場合があります。
nobetsu はメディアキーを横取りせず、他アプリの再生操作も行いません。
[Apple の AirPods 向け音声 API の説明](https://developer.apple.com/videos/play/wwdc2023/10233/) にも、
通話中のミュート操作とマイクを必要な間だけ使用する設計が説明されています。
「AirPods Proでマイクをコントロールできません」というバナーは、再生ではなくマイク操作として扱われたことを示します。
**この拒否バナーと、録音中に Netflix の耳元再生操作が効かない問題は未解決です。**
公開 API によるミュート操作の受け付けも試しましたが、実機では耳元操作の通知が届かず、
拒否バナーが残りました。この版に「AirPods で停止できる」機能は含めていません。

耳元の再生操作が効かない場合は、まず **ESC または ⌘ の単独タップで音声入力を停止**して試してください。
アプリ自体を終了する必要があるかを切り分けられます。目印の一時停止ボタンでもマイクを解放します。
録音を続けたまま耳元操作を他アプリの再生操作へ強制的に切り替える方法は、現在対応していません。
録音停止後も再現する場合は、macOS の版・AirPods の機種・利用アプリと、停止前後どちらで起きるかを添えて報告してください。

## 辞書で誤変換を直す

音声認識は「Clone」を「苦労」と書きます。**話し言葉としては正しい**ので、認識器の側では直りません。
打ち込む直前に、こちらで書き換えます。

### 書き方

1行に1組。左が「認識器が書いてしまう文字」、右が「本当に打ちたい文字」です。

```
苦労してくる => Cloneしてくる
クロードコード => Claude Code
プライマリー機 => プライマリーキー
```

- `#` から行末はコメント。空行は無視されます
- 区切りは `=>` のほか `→`（矢印）とタブも使えます
- 左右とも、記号や英数字を含むふつうの文字列でそのまま書けます。引用符もエスケープも要りません

> **なぜ JSON やキー・バリュー形式ではないのか。**
> 左右どちらにも `:` や `"` や空白がそのまま現れるからです。JSON にすると引用符と
> エスケープが必要になり、手で足すときの負担が跳ね上がります。`:` を区切りにしなかったのも
> 同じ理由で、`10:30 => 10時30分` のような規則が書けなくなります。
> **思いついたその場で1行足せること**を最優先にしています。

### 公開サンプルと個人辞書

| | 置き場所 | 反映のしかた |
|---|---|---|
| 同梱辞書 | リポジトリの `dictionary.sample.txt` | `./build.sh` でアプリに焼き込まれます |
| 個人辞書 | `~/Library/Application Support/nobetsu/dictionary.txt` | **保存するだけ** |

同じ言葉が両方にあれば**個人辞書が勝ちます**。
読み込むのは**喋りはじめる瞬間**なので、保存したら次のひと言から効きます。

**普段はこちらだけ触れば足ります。**個人辞書はメニューの「辞書を編集する」から開けます
（無ければ雛形を作ります）。ビルドし直す必要はありません。

同梱するのは公開サンプルだけです。**個人辞書を `.app` に焼き込むことも、公開リポジトリへ送ることもしません。**
リポジトリ直下の `dictionary.txt` は引き続き `.gitignore` の対象です。

### 旧版で育てた辞書の引き継ぎ

- 個人辞書が既にある場合は、空のファイルでも上書きしません。既存のシンボリックリンクも維持します。
- 初めて引き継ぐとき、個人辞書がまだ無ければリポジトリ直下の `dictionary.txt` を個人辞書へコピーします。
  元ファイルは移動しません。以後はメニューから個人辞書を編集してください。
  別の個人辞書が既にあれば両方を読みます。旧版で登録した読み込み先や既存リンクも維持します。
- 元ファイルが無く、旧アプリの中だけに辞書が残っている場合は、ローカルへ回収します。
  既存の個人辞書があるときは `legacy-dictionary-*.txt` として別に保存し、内容を勝手に混ぜません。
- 取り込みは一度だけです。引き継いだファイルを編集・削除した後に、古い同梱内容を再取り込みしません。
- 優先順位は公開サンプル → 引き継いだ旧辞書 → 個人辞書です。同じ左辺は個人辞書が勝ちます。

引き継ぎの記録は `~/Library/Application Support/nobetsu/dictionary-sources.json` に置きます。
旧辞書が複数ある場合はこのファイルの `legacyPaths` が読み込み先です。
メニューの「引き継いだ辞書・バックアップを開く」から保存フォルダを開けます。
通常は「辞書を編集する」を使い、旧辞書の規則を消す場合はその元ファイルを編集してください。
保存後、次の音声入力から反映されます。再ビルドは不要です。

辞書の一部を読めない場合も、読めたファイルの規則は使えます。メニューバーに警告が出るので、
メニュー内の保存先をクリックして、リンク先・権限・UTF-8 の文字コードを確認してください。
`dictionary-sources.json` が壊れている場合は JSON の書式を直し、「辞書を読み直す」で再確認できます。
記録を読めない間は旧辞書の読み込み先が分からないため、同梱辞書と個人辞書だけを使います。

**既存のリンクが作業ツリーを指している場合、`git clean -xdf` でリンク先の辞書が削除されます。**
既存リンクは自動変更しません。整理の前にリンク先の辞書を作業ツリー外へ退避してください。
リンク先が消えても他の辞書は使えますが、消えた語彙はバックアップからの復旧が必要です。

### 更新前のバックアップ

設置前に、既存辞書と旧アプリの同梱辞書を
`~/Library/Application Support/nobetsu/dictionary-backups/` の新しいフォルダへコピーします。
退避に失敗したらアプリを入れ替えません。バックアップは Git の外に置き、**最新5世代まで**保持します。
新しい退避が完成した後に、古い世代を削除します。現行の辞書・既存リンクは削除しません。
各フォルダの `sources.json` は `personal-0.txt`、`personal-1.txt`… の元の保存場所を順に記録します。
`dictionary-sources.json` は引き継ぎ記録の原文、`links.json` はリンクの保存先とリンク先です。
リンク先が消えている場合もリンク自体は変更せず、残っている情報を退避します。
`previous-bundle.txt` は旧アプリ内の辞書です。復旧時は現在の辞書も別に保存し、必要な規則を取り戻してください。
バックアップにも個人の語彙が含まれるので、公開リポジトリや不具合報告へ添付しないでください。

**会社の Mac と個人の Mac の辞書は、自動では同期しません。**
会社固有の語彙は会社の Mac に保持できます。`dictionary.txt` を force-add して公開する運用はしないでください。

### 2つだけ、守ってください

**短い言葉を左に置かない。** 「苦労」を `Clone` にすると、本当に苦労した話が書けなくなります。
「苦労してくる」のように少し長めに取ってください。
長い規則から先に当たるので、短いものと両方書いても長い方が勝ちます。

**左が右の一部になる規則は書けません。**

```
品予約履歴 => 備品予約履歴     ← だめ
```

正しく「備品予約履歴」と認識されたときにも中の「品予約履歴」が引っかかり、
「備備品予約履歴」になります。直すほど壊れるので、読み込み時に捨てています。

## 仕組み

```
マイク
  ↓  AVAudioEngine
SpeechAnalyzer + DictationTranscriber (ja-JP, 端末内)
  ↓  未確定テキスト / 確定テキスト
辞書で置換
  ↓
CGEvent の Unicode 直接入力（IME を経由しない）
  ↓
そのとき使っているアプリ
```

肝は2つです。

**IME を通さない。** `DictationTranscriber` は変換済みのテキストを返すので、
`CGEvent` の Unicode 直接入力で打てば変換工程を丸ごと迂回できます。**これがこのアプリの存在理由です。**

**確定を待たない。** 未確定のテキストを先に打ち込み、認識が書き換わったら、
前回打ち込んだ文字列との共通接頭辞を求めて、食い違った末尾だけを消して打ち直します。
確定を待つ設計にすると、下の計測どおり 20 秒以上も文字が出てきません。

### 辞書はいつ、どう当たっているのか

**AI は関わりません。**アプリがファイルを読んで文字列を置き換えているだけで、
辞書がどこかへ送られることも、ネットワークに出ることもありません。

読むのは**喋りはじめる瞬間の1回だけ**です。ファイルの更新時刻を見て、変わっていなければ読み直しません。
このとき `#` 以降は捨てられ、**文字列の組だけが残ります**（何行コメントを書いても実行時の負担はゼロです）。
公開サンプルに旧辞書・個人辞書を重ね、自滅する規則を捨て、左辺の長い順に並べ替えます。

喋っている間、認識器は「**その区間の全文**」を毎秒4回ほど送ってきます。届くたびに全部の規則を当てます。

```
DictationTranscriber
  ↓  「苦労してくるね」（区間の全文）
辞書を当てる ── 規則の数だけ置換するだけ。前回何をしたかは覚えていない
  ↓  「Cloneしてくるね」
打ち込み ── 前回打った文字列と比べて、変わった末尾だけ打ち直す
  ↓
使っているアプリ
```

状態を持たないのが大事なところです。認識が「くろー」→「クローン」→「Cloneしてくる」と
変わる途中で一瞬おかしな形になっても、**次の更新で正しく打ち直されます。**

### 計測結果

`spike/` に、3つのエンジン構成を実測して比較するアプリを残してあります。
MacBook Air M4 / macOS 26.5.2 / 日本語の自然な発話 80〜105 秒での結果です。

| | Dictation +<br>frequentFinalization | Dictation | SpeechTranscriber |
|---|---|---|---|
| 初回表示まで | 1.63 秒 | 1.33 秒 | **11.79 秒** |
| 途中経過の遅延 平均/最大 | 0.16 / 0.38 秒 | 0.16 / 0.38 秒 | 0.08 / 0.18 秒 |
| 確定の遅延 平均/最大 | 0.42 / 0.86 秒 | 0.32 / 0.52 秒 | **3.78 / 8.34 秒** |
| 誤り | 500字中 7 箇所 | 668字中 5 箇所 | 531字中 5 箇所 |

**SpeechTranscriber は喋りながら見る用途には使えません。** 初回表示に 11.79 秒、
確定は最大 8.34 秒遅れます。精度自体は3構成とも大差ありませんでした。

## 開発するとき

証明書は[上](#ソースからビルドする前に1回だけ)で作ったものをそのまま使います。
`build.sh` が `nobetsu` という名前の証明書を自動で探し、**実際に署名できるか**を試してから進みます。
`security find-identity` の一覧には出ないのに署名は通る、という食い違いが実際にあったためです。

署名が固定されていれば、**ビルドし直しても許可はやり直しになりません。**
ここが崩れると、コードを直すたびに許可を付け直すことになり、それだけで開発が続かなくなります。

### テスト

```bash
./test.sh
```

辞書の置換、打ち込みの差分計算、許可の案内、
開始キーの設定、ログの圧縮——を確かめます。
アプリを起動せずに走ります（数秒）。

入力と出力だけで完結していて、壊れると利用者の文章・起動手順・過去のログへ
影響するところを機械で確かめています。
マイク・イベントタップ・他アプリへの打ち込みは実機でしか確かめられないので、
そちらは実際に動かして見ています。

不具合を調べるときは、推測の前にログを読んでください。

```bash
tail -30 ~/Library/Logs/nobetsu.log
```

**喋った内容そのものは書き出しません。** 残るのは時刻・アプリ名・文字数だけです。
1MB を超えたら圧縮して退避し、いまのファイルを含めて5世代（`nobetsu.log.1.gz` 〜 `.4.gz`）残します。
全部合わせても 1.5MB を超えません。古いものは `gunzip -c` で読めます。

設計上の判断と、その理由は [CLAUDE.md](CLAUDE.md) にまとめてあります。

## これから

- [ ] 誤変換の抑制（`SFSpeechLanguageModel` によるカスタム言語モデル）
- [ ] App Intents 対応（Shortcuts.app から呼べるようにする）

分かっていて直していないことも含めて、[TODO.md](TODO.md) に書いてあります。

## 免責

**趣味で作って、そのまま置いてあるものです。**
MIT ライセンスのとおり**無保証**で、使ったことで何かが起きても責任は負えません。

- 他のアプリへキー入力を送るツールです。**思わぬところへ文字が入る可能性があります**
- 不具合の報告は歓迎しますが、**対応をお約束はできません**
- Pull Request も歓迎しますが、方針に合わないものはお断りすることがあります
- 大事な場面で使う前に、ご自身の環境で十分に試してください

---

## ライセンス

MIT — [LICENSE](LICENSE)

音声認識には Apple の `SpeechAnalyzer` / `DictationTranscriber` を使っています。
モデル本体は OS が管理する Apple の資産であり、このリポジトリには含まれません。

## 作った人

**ぽちょ研究所 / Pochang Lab** — [@pochang6](https://github.com/pochang6)

---

## English

**nobetsu** — dictation for Japanese speakers who want to keep talking, and talking.

**Press ⌘ for one second and let go.** That is it — you can then keep talking for as
long as you like, hands free. **It is not push-to-talk.** Tap ⌘ again, or press ESC, to stop.

Text lands directly in whatever app you are using, as you speak. No time limit.
Everything runs on your Mac; no audio or text leaves the device.

The hold time is adjustable from 0.5 to 2.0 seconds in 0.1-second steps. You can also
choose both Command keys, only the left one, or only the right one for starting dictation.

*Nobetsu maku nashi* (のべつ幕なし) is a Japanese phrase meaning "without ever lowering
the curtain" — going on and on without pause.

### Why this exists

Japanese input goes through an IME. As you speak, macOS dictation feeds the *readings*
into that IME, which keeps rewriting unconfirmed text while trying to pick the right
characters from context. With continuous speech, it can't keep up, and dictation stalls.

English has no conversion step, so this failure mode does not exist for English speakers.
That is why none of the existing open-source dictation tools address it — and why
this one is written in Japanese, for Japanese.

nobetsu sidesteps the problem entirely. macOS 26's `DictationTranscriber` returns
already-converted Japanese text, so the app types it directly with `CGEvent` Unicode
input, bypassing the IME. There is nothing left to collide with.

It also types *before* the recognizer finalizes, diffing against what it typed last
time and rewriting only the tail that changed. Waiting for finalization means waiting
more than 20 seconds for text to appear — measured, not guessed.

### Requirements

macOS 26 (Tahoe) or later, Apple Silicon. No Xcode needed.

**Before you build, create a self-signed code-signing certificate named `nobetsu`**
(Keychain Access → Certificate Assistant → Create a Certificate; Self Signed Root,
Code Signing; then set its trust for Code Signing to *Always Trust*). macOS ties
Input Monitoring and Accessibility to a **stable code signature**. An ad-hoc signature
has none, so Input Monitoring is denied outright — without ever showing a prompt.
`./build.sh --check` tells you whether signing works, and `./build.sh` refuses to
install an ad-hoc build rather than leaving a dead app in `/Applications`.

```bash
git clone https://github.com/pochang6/nobetsu.git
cd nobetsu
./build.sh --check   # certificate in place?
./build.sh
open /Applications/nobetsu.app
```

For subsequent updates, run `./update.sh`. If updating from an older version without this script,
run `git pull --ff-only` followed by `./build.sh --restart`.
Personal dictionaries and existing symlinks are preserved. Only the public sample is bundled in the app;
legacy dictionaries stay local, and backups are created before installation.
Failed installation or startup verification restores the previous app.
See [CHANGELOG.md](CHANGELOG.md) for release notes.

With AirPods, a visible recording indicator means the microphone is still active even while you are silent.
Headphone gestures may be treated as microphone mute controls. Stop dictation with Escape before testing playback controls;
The rejection banner and Netflix playback control conflict during recording remain unresolved.
Pause dictation to release the microphone, then try playback again.
Using the same gesture to force playback in another app while recording is not supported; hardware verification is still needed.

macOS will ask for Input Monitoring first, then Accessibility. They are separate
permissions and both are required — Input Monitoring to read the ⌘ key, Accessibility
to type into other apps. Until they are granted, holding ⌘ does nothing at all.

The UI is Japanese only. The recognizer is Japanese only. This is deliberate —
the problem it solves does not exist outside Japanese.

### License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 pochang6.

Speech recognition uses Apple's `SpeechAnalyzer` / `DictationTranscriber`.
The models belong to the OS and are not part of this repository.

### Disclaimer

**This is a hobby project, published as is.** As stated in the MIT license, it comes
with **no warranty of any kind**, and I cannot take responsibility for what happens
when you use it.

- It sends synthetic key events to other applications. **Text may land somewhere you did not intend.**
- Bug reports are welcome, but **a response is not guaranteed**.
- Pull requests are welcome, but may be declined if they do not fit the direction of the project.
- Try it in your own environment before relying on it for anything that matters.
