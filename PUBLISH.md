# 公開の計画

nobetsu を OSS として出すまでの手順と、そのときに決めておくこと。
**まだ公開していません。**（リポジトリは private / バージョンは 1.0.0 未満）

実際に使い込んでから判断する、という方針です。
使っていて出てきた不満は [TODO.md](TODO.md) へ。ここには**公開そのもの**に関することだけを書きます。

---

## 1. 辞書を「テンプレート」と「個人のもの」に分ける ← 最重要

**これが公開前に必ず片付ける唯一の危険物です。**

辞書は誤変換を拾って育てる仕組みなので、中身は仕事の固有名詞・社内用語・取引先、
そのとき考えごとにしていた話題がそのまま溜まります。
**技術的な機密ではなく、生活の記録に近いものです。**公開リポジトリに置くものではありません。

| ファイル | 扱い | 中身 |
|---|---|---|
| `dictionary.sample.txt` | 追跡する（公開） | 誰にでも当てはまる開発語彙だけ。書き方の見本 |
| `~/Library/Application Support/nobetsu/dictionary.txt` | 追跡しない | その人の辞書 |
| `/dictionary.txt`（リポジトリ直下） | **.gitignore 済み** | いまの個人辞書の実体。公開前にここから引っ越す |

作業:

- [ ] いまの `dictionary.txt` から、一般的な語彙だけを抜いて `dictionary.sample.txt` を作る
- [ ] 個人の分は `~/Library/Application Support/nobetsu/dictionary.txt` へ実体として移す
      （いまはリポジトリ内のファイルへのシンボリックリンクになっている）
- [ ] `build.sh` が焼き込む対象を `dictionary.sample.txt` に変える
- [ ] `.claude/skills/dictionary/` の書き込み先も合わせて直す

**git の履歴にも残さないこと。**
幸い `dictionary.txt` は一度もコミットされていないので、履歴の書き換えは要りません。
この状態のまま公開すれば、過去を掘られても何も出てきません。
`git add -A` の一発で入ってしまうので、.gitignore に入れてあります。

## 2. 2台の Mac で個人辞書をどう同期するか

リポジトリで共有していたものが使えなくなるので、代わりを決める必要があります。

| 案 | よいところ | 気になるところ |
|---|---|---|
| iCloud Drive のファイルへシンボリックリンク | 道具が増えない。書いた瞬間に両方へ | 同期の遅延。競合したときに気づきにくい |
| 個人の private リポジトリ | 履歴が残る。競合を自分で解ける | 毎回 pull / push が要る |
| 同期しない | 何もしなくていい | 同じ誤変換を2回登録することになる |

→ **決めたらここに書く。**

## 3. 見せ方

- [x] **動画。** `docs/demo.gif`（README の頭・14秒・無音）と
      `docs/nobetsu-demo.mp4`（全編 26 秒・音あり）。
      GitHub の README は `<video>` タグを消すので、**インラインで動くのは GIF だけ**。
      mp4 は相対リンクで置くと GitHub のファイル表示で再生される。
      作り直すときは元の画面収録から:

      ```bash
      # 配布用（HEVC のままだと Chrome / Firefox で再生できない）
      ffmpeg -i 元.mp4 -c:v libx264 -preset slow -crf 24 -vf "scale=1920:-2" \
             -c:a aac -b:a 96k -movflags +faststart docs/nobetsu-demo.mp4
      # README 用（2秒目から14秒ぶん。1.2MB に収まる）
      ffmpeg -ss 2 -t 14 -i 元.mp4 -vf "fps=10,scale=900:-1:flags=lanczos,palettegen=stats_mode=diff" palette.png
      ffmpeg -ss 2 -t 14 -i 元.mp4 -i palette.png \
             -lavfi "fps=10,scale=900:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" docs/demo.gif
      ```

- [ ] **公開前に動画をもう一度見直す。** 画面の端に他の作業が映り込んでいないか、
      音声に余計なものが入っていないか。一度出したら取り消せない
- [ ] スクリーンショット（メニューバー、目印）
- [ ] README は既にあります。動画を頭に置く
- [ ] 告知記事はリポジトリへ誘導するだけの短いもので足ります。
      説明の本体は README に置く（二重に書くと必ず片方が腐ります）

## 4. ライセンス — MIT のままでよい

`LICENSE` は MIT（Copyright (c) 2026 pochang6）。**変える理由はありません。**

- お金にしない・広く使ってほしい・自分の技術の証明にしたい、という目的に最短で合う
- Apache-2.0 は特許条項があるぶん企業に安心されるが、このアプリに特許の懸念はほぼ無く、
  ファイルごとの手当てが増えるだけ
- GPL は「みんなが便利に使ってくれたらうれしい」と相性が悪い。使う側に制約が乗る

## 5. 公開の瞬間の作法

- [ ] Description と Topics（`macos` `dictation` `japanese` `speech-recognition` `swift` `accessibility`）
- [ ] **Releases に .app を置くかどうか。**
      署名と公証（Notarization）が無いと Gatekeeper に止められ、
      「開発元を確認できません」で終わります。Apple Developer Program（年間費用）が要る話なので、
      当面は**ソースからビルドしてもらう**方針。README にその理由を書く
- [ ] Issues / Pull Request の受け方（方針は CLAUDE.md の「運用」にある）
- [ ] v1.0.0 を付けるのはいつか。「1週間使って直したいところが出なくなったら」が目安
- [ ] `AGENTS.md`（CLAUDE.md の写し）を一緒に出すか決める

## 6. 公開しないもの

- 個人辞書（上記）
- `CLAUDE.local.md` / `.claude/settings.local.json`（既に .gitignore 済み）
- ログ（`~/Library/Logs/nobetsu.log`。そもそもリポジトリの外）

公開前に、この検索で何も出ないことを確かめる。

```bash
git ls-files | xargs grep -l "個人の固有名詞やメールアドレス" 2>/dev/null
```
