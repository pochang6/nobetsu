# nobetsu（のべつ）

**日本語話者のための、のべつ幕なしに喋り続けられる音声入力。**

⌘ を長押しして喋ると、話した端から、そのとき使っているアプリに文字が入っていきます。
時間制限はありません。日本語入力（IME）を経由しません。すべて端末内で完結し、音声も文字も外部に送信しません。

> **のべつ幕なし** — 芝居で幕を下ろさずに演じ続けること。転じて、絶え間なく続くこと。

---

## これは何を解決するのか

AI エージェントに長文を話しかけようとすると、日本語話者は必ずどれかに当たります。

| | 詰まるところ |
|---|---|
| macOS 標準の音声入力 | ライブ変換と衝突して、変換のたびに固まる・止まる |
| Claude Code / Gemini のマイク | 数分で切れる。長文を一息で入れられない |
| ChatGPT | 長文は入るが、**喋っている間に文字が一切見えない** |
| 既存の音声入力アプリ | ほぼ全部が「押す→喋る→離す→一括ペースト」型。つまり上と同じ |

そして最後の行が重要で、既存のものはほぼすべて英語圏の開発者によるものです。
**英語には変換工程が存在しないので、ライブ変換と音声入力がぶつかるという問題自体が起きません。**
だから誰もそこを解こうとしない。ここが構造的に空いています。

nobetsu はそこだけを狙います。

## 実際に入る文章

以下は、このツールで実際に喋って入力されたものです。手直ししていません。
話し言葉のまま、句読点も自動で入ります。

```
なんか出ましたね。そして話せるようになりましたね。おおすげすげすげえ下にも出て
上にも出るんだ。認識もとても良いね。今 AirPods をつけていてだから多分さっきよりも
マイク入力の感度は高くて、耳元に対してマイク入力されてる感じにはなるんだと思うよね。
見てる感じでも全然何かタイプミスがなさそうな感じでいいなぁ。もうちょっと早く
しゃべってみようかな。どれぐらいで行けるだろうか。結構感動してるね。
```

誤りは 500〜670 字あたり 5〜7 箇所（およそ 1.2〜1.5%）でした。詳しくは[計測結果](#計測結果)を参照してください。

## 使い方

macOS 26 (Tahoe) 以降、Apple Silicon の Mac が必要です。

```bash
git clone https://github.com/pochang6/nobetsu.git
cd nobetsu
./build.sh
open /Applications/nobetsu.app
```

`./build.sh` はビルドして `/Applications` に置くところまで行います。Xcode は不要で、
コマンドラインツールに入っている `swiftc` だけでビルドできます。

メニューバーに波形のアイコンが出ます。Dock には出ません。

| 操作 | 動き |
|---|---|
| **⌘ を長押し**（0.5秒） | 認識が始まる。指を離しても続く |
| **もう一度 ⌘ を軽く叩く** | 停止 |
| **ESC** | 停止 |
| 左上の目印をクリック | 停止 |

開始と終了は音で知らせます。画面を見ていなくても状態が分かります。

⌘ は macOS のあらゆるショートカットの起点なので、
**⌘ を押している間に他のキーやクリックが来たら、それはショートカットだと見なして発火しません。**
⌘Tab や ⌘S を打とうとしてためらっても暴発しません。
それでも気になる場合は、メニューから「右の ⌘ だけで開始する」に切り替えられます。

### 必要な許可

初回に2つ求められます。どちらも macOS 標準のダイアログが出るので、そこで許可してください。

| 許可 | 何に使うか | 聞かれる場面 |
|---|---|---|
| **入力監視** | ⌘ の長押しを待ち受ける | 起動した直後 |
| **アクセシビリティ** | 文字を他のアプリへ入力する | 初めて ⌘ を長押ししたとき |
| **マイク・音声認識** | 音声を文字にする | 初めて喋るとき |

許可のダイアログを閉じてしまった場合は、メニューバーのアイコンからやり直せます。

### 設定

メニューバーのアイコンから切り替えられます。

- **ログイン時に起動** — 既定で有効
- **開始と終了を音で知らせる**
- **左上に認識中の目印を出す**
- **認識中の文字を画面に流す** — 既定で無効。入力先の文章と重なるため
- **右の ⌘ だけで開始する**
- **遠距離マイク補正** — マイクから離れて話すとき

## 仕組み

```
マイク
  ↓  AVAudioEngine
SpeechAnalyzer + DictationTranscriber (ja-JP, 端末内)
  ↓  未確定テキスト / 確定テキスト
CGEvent の Unicode 直接入力（IME を経由しない）
  ↓
そのとき使っているアプリ
```

肝は2つあります。

**IME を通さないこと。** macOS 標準の音声入力は認識した「よみ」を日本語入力に流し込むため、
ライブ変換が未確定文節を書き換え続けるのと衝突して固まります。
`DictationTranscriber` は漢字かな交じりの確定済みテキストを返すので、
`CGEvent` の Unicode 直接入力を使えば変換工程を丸ごと迂回できます。ぶつかる相手がいなくなります。

**確定を待たずに入力すること。** 未確定のテキストを先に打ち込んでおき、
認識が書き換わったら、前回打ち込んだ文字列との共通接頭辞を求めて、
食い違った末尾だけを消して打ち直します。
確定を待つ設計にすると、下の計測どおり 20 秒以上も文字が出てきません。

## 計測結果

`spike/` に、3つのエンジン構成を実測して比較するアプリを残してあります。
MacBook Air M4 / macOS 26.5.2 / 日本語の自然な発話 80〜105 秒での結果です。

| | Dictation +<br>frequentFinalization | Dictation | SpeechTranscriber |
|---|---|---|---|
| 初回表示まで | 1.63 秒 | 1.33 秒 | **11.79 秒** |
| 途中経過の遅延 平均/最大 | 0.16 / 0.38 秒 | 0.16 / 0.38 秒 | 0.08 / 0.18 秒 |
| 確定の遅延 平均/最大 | 0.42 / 0.86 秒 | 0.32 / 0.52 秒 | **3.78 / 8.34 秒** |
| 誤り | 500字中 7 箇所 | 668字中 5 箇所 | 531字中 5 箇所 |

**SpeechTranscriber は喋りながら見る用途には使えません。** 初回表示に 11.79 秒かかり、
確定は最大 8.34 秒遅れます。実際に「文字が出ないと思ったらいきなり出てきた」という挙動になります。
精度自体は3構成とも大差ありませんでした。

## 開発するとき

コードを変更してビルドし直すと、アドホック署名のハッシュが変わるため、
macOS からは別のアプリに見えて許可をやり直すことになります。
頻繁にビルドするなら、自己署名の証明書を1つ作っておくと固定されます。

キーチェーンアクセス →「証明書アシスタント」→「自分に証明書を作成」→
名前 `nobetsu` / 固有名のタイプ「自己署名ルート」/ 証明書のタイプ「コード署名」。

`build.sh` がこの名前の証明書を自動で探して使います。**使うだけなら不要です。**

ログは `~/Library/Logs/nobetsu.log` に出ます。

## これから

- [ ] 誤変換の抑制（`SFSpeechLanguageModel` によるカスタム言語モデル）
- [ ] ホットキーの変更に対応する
- [ ] App Intents 対応（Shortcuts.app から呼べるようにする）
- [ ] 挿入先ごとの挙動差の検証（ターミナル / ブラウザ / Electron）

不具合の報告も、プルリクエストも歓迎します。

---

## English

**nobetsu** — dictation for Japanese speakers who want to keep talking, and talking.

Hold ⌘ and speak. Text lands directly in whatever app you are using, as you speak.
No time limit. Everything runs on your Mac; no audio or text leaves the device.

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

macOS 26 (Tahoe) or later, Apple Silicon.

```bash
git clone https://github.com/pochang6/nobetsu.git
cd nobetsu
./build.sh
open /Applications/nobetsu.app
```

No Xcode required — it builds with the `swiftc` that ships with the Command Line Tools.

Hold ⌘ for half a second to start. Tap ⌘ again, or press ESC, to stop.
macOS will ask for Input Monitoring and Accessibility the first time each is needed.

The UI is Japanese only. The recognizer is Japanese only. This is deliberate.

---

## ライセンス

MIT — [LICENSE](LICENSE)

音声認識には Apple の `SpeechAnalyzer` / `DictationTranscriber` を使っています。
モデル本体は OS が管理する Apple の資産であり、このリポジトリには含まれません。

## 作った人

**ぽちょ研究所 / Pochang Lab** — [@pochang6](https://github.com/pochang6)
