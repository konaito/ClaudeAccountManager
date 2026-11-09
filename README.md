# Claude Account Manager (cam)

cam は、1台の Mac で Claude Code をアカウントごとのコマンドで起動するための bash スクリプトです。`ceo` と打つと ceo@fybe.jp で、`claude` と打つと既定のアカウントで起動し、2つは別のターミナルで同時に動かせます。

仕組みは公式ドキュメントの「Log in with multiple accounts」にある `CLAUDE_CONFIG_DIR` です。アカウントの自動切り替えはしません。
https://code.claude.com/docs/en/authentication

## 何が分かれて何が共通か

アカウントごとに分かれるもの:

- ログイン（macOS の Keychain の項目は `CLAUDE_CONFIG_DIR` ごとに別になる）
- `.claude.json`（ログイン中のアカウント情報を含む）と、その控えの `backups`
- 組織ごとの値（`policy-limits.json`、`remote-settings.json`）
- MCP の認証状態（`mcp-needs-auth-cache.json`）

それ以外の `~/.claude` の中身は、全部シンボリックリンクで共通にします。設定、スキル、会話履歴に加えて、`sessions` も共通です。そのため、どのアカウントで起動したセッションからも、`ListAgents` と `SendMessage` でほかのセッションが見えます。

Claude Code が起動後に作るフォルダ（`sessions`、`session-env`、`teams`、`tasks` など）は、`~/.claude` に先に作ってからリンクを張ります。プロファイルにすでに実体があるときは、中身を `~/.claude` に移してからリンクにします。`~/.claude` に同じ名前のものがあれば、捨てずにプロファイルの `.cam-replaced/<時刻>/` に残します。

ユーザーの MCP サーバーは、起動のたびに `~/.claude.json` の `mcpServers` をプロファイル側へ写します。

フォルダを開いたときの「Yes, I trust this folder」の記録は `.claude.json` に入るので、そのままではアカウントごとに聞かれます。cam は起動のたびに、`~/.claude.json` と全プロファイルの `.claude.json` から信頼済みのフォルダを集め、起動するプロファイルの `.claude.json` に写します。どれか1つのアカウントで信頼したフォルダは、次に別のアカウントを cam で起動したときには聞かれません。`--default` で作ったコマンド（`~/.claude`）の `~/.claude.json` には書き込みません。

## 置き場所

- このリポジトリ: `cam` 本体
- `~/.cam/bin/`: `cam` 本体へのリンクと、`cam add` で作った起動用コマンド（PATH に入れる）
- `~/.cam/profiles/<名前>/`: 各アカウントの `CLAUDE_CONFIG_DIR`。ログイン情報が入るので git には入れない

## 入れ方

```bash
mkdir -p ~/.cam/bin
ln -s ~/Documents/cam/cam ~/.cam/bin/cam
echo 'export PATH="$HOME/.cam/bin:$PATH"' >> ~/.zshrc
```

## 使い方

```bash
cam add ceo            # ~/.cam/profiles/ceo と ceo コマンドを作り、ログインして起動する
cam add cto --no-login # 作るだけで、ログインと起動はしない
cam add cto            # 既にあるコマンドなら、そのアカウントでログインし直して起動する
ceo                    # 2回目からはコマンドだけで起動する
cam add coo --default  # ~/.claude のログインで起動する coo コマンドを作る
cam list               # コマンドとログイン中のアカウント
cam auto               # 5時間枠の使用率がいちばん低いコマンドで起動する
cam usage              # 各コマンドの使用率と、cam auto が選ぶコマンド（--json でメニューバー用）
cam sync ceo           # 共有リンクと MCP を同期する（起動時にも自動で行う）
cam remove ceo         # コマンドとプロファイルを消す
```

既存のコマンドと同じ名前（`ls` など）は作れません。

`cam add` は `claude auth login` でブラウザのログインを開き、通ったらそのまま Claude Code を起動します。端末から実行していないときはログインせず、手順だけを表示します。

## cam auto の選び方

`cam auto` は各コマンドの使用率を調べ、5時間枠の使用率がいちばん低いコマンドで起動します。引数はそのまま `claude` に渡します。

使用率は全コマンドぶんを同時に調べます。表示はせず、選んだコマンドをそのまま起動します。使用率を判定できないときだけ、どのコマンドで起動するかを表示します。

- 5時間枠が同じなら、7日枠の使用率が低いほうを選びます
- 5時間枠か7日枠が100%のコマンドは選びません
- 使用率が取れないコマンドは、前回取れた値（控え）で比べます
- 使用率が取れず控えも無いコマンドは候補から外します。全部が外れたときは、`--default` のコマンドで起動し、各コマンドが取れなかった理由を表示します

使用率は、Claude Code が Keychain に保存したログインのトークンで `https://api.anthropic.com/api/oauth/usage` を呼んで取ります。この API は公開されていないので、仕様が変わると `cam auto` だけ動かなくなります。トークンの期限が切れているコマンドは、一度そのコマンドを起動すると Claude Code が更新します。

この API は、低い頻度で呼んでも 429（Rate limited）を返すことがあります。そのため、取れた値はコマンドごとに `~/.cam/usage-cache/<名前>` に控えておき、取れないときは控えを使います。`cam usage` では、控えの値に「◯時◯分時点の値」と付けます。控えのリセット時刻を過ぎた枠は、使用率を 0% として扱います。

## メニューバー

`menubar/` の CamBar は、`cam usage --json` の結果をメニューバーに出すアプリです。メニューバーには `cam auto` が選ぶコマンドとその5時間枠の使用率を出し、開くと各コマンドの5時間枠と週次の使用率、リセット時刻を出し、`cam auto` が選ぶコマンドには `*` を付けます。控えの値を出しているコマンドには、名前の下に「◯時◯分時点の値」と出します。使用率が出せないコマンドには、429・トークン切れなどの理由を出します。アカウントの切り替えはしません。

```bash
menubar/install.sh   # ビルドして ~/Applications/CamBar.app に置き、ログイン時に起動するようにする
```

使用率は5分ごとに取り直します。ログイン時の起動には `~/Library/LaunchAgents/jp.fybe.cam.menubar.plist` を使います。

## 注意

- API キーを使わない Claude Console のサインインは、保存先が `CLAUDE_CONFIG_DIR` の外にあるので、アカウントごとに分けられません（公式ドキュメントの記述）
- リモートの MCP サーバーは、プロファイルごとにもう一度認証が要るかもしれません（未確認）
- `cam remove` は Keychain の項目を消しません

共通にするファイルの一覧は [ccd](https://github.com/Nael-Nathanael/ccd)（MIT）を参考にしました。
