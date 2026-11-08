# cam

cam は、1台の Mac で Claude Code をアカウントごとのコマンドで起動するための bash スクリプトです。`ceo` と打つと ceo@fybe.jp で、`claude` と打つと既定のアカウントで起動し、2つは別のターミナルで同時に動かせます。

仕組みは公式ドキュメントの「Log in with multiple accounts」にある `CLAUDE_CONFIG_DIR` です。アカウントの自動切り替えはしません。
https://code.claude.com/docs/en/authentication

## 何が分かれて何が共通か

アカウントごとに分かれるもの:

- ログイン（macOS の Keychain の項目は `CLAUDE_CONFIG_DIR` ごとに別になる）
- `.claude.json`（ログイン中のアカウント情報を含む）
- 組織ごとの値（`policy-limits.json`、`remote-settings.json`）

`~/.claude` へのシンボリックリンクで共通にするもの:

- CLAUDE.md、settings.json、keybindings.json、statusline-command.sh
- skills、commands、agents、rules、hooks、plugins、output-styles
- projects、history.jsonl、file-history、plans、todos（会話履歴と記憶）

ユーザーの MCP サーバーは、起動のたびに `~/.claude.json` の `mcpServers` をプロファイル側へ写します。

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
cam login cto          # cto のアカウントでログインし直して起動する
ceo                    # 2回目からはコマンドだけで起動する
cam add coo --default  # ~/.claude のログインで起動する coo コマンドを作る
cam list               # コマンドとログイン中のアカウント
cam auto               # 5時間枠の使用率がいちばん低いコマンドで起動する
cam sync ceo           # 共有リンクと MCP を同期する（起動時にも自動で行う）
cam remove ceo         # コマンドとプロファイルを消す
```

既存のコマンドと同じ名前（`ls` など）は作れません。

`cam add` と `cam login` は `claude auth login` でブラウザのログインを開き、通ったらそのまま Claude Code を起動します。端末から実行していないときはログインせず、手順だけを表示します。

## cam auto の選び方

`cam auto` は各コマンドの使用率を調べ、5時間枠の使用率がいちばん低いコマンドで起動します。引数はそのまま `claude` に渡します。

- 5時間枠が同じなら、7日枠の使用率が低いほうを選びます
- 5時間枠か7日枠が100%のコマンドは選びません
- 使用率が取れないコマンドは候補から外します。全部取れないときは `--default` のコマンドで起動します

使用率は、Claude Code が Keychain に保存したログインのトークンで `https://api.anthropic.com/api/oauth/usage` を呼んで取ります。この API は公開されていないので、仕様が変わると `cam auto` だけ動かなくなります。トークンの期限が切れているコマンドは、一度そのコマンドを起動すると Claude Code が更新します。

## 注意

- API キーを使わない Claude Console のサインインは、保存先が `CLAUDE_CONFIG_DIR` の外にあるので、アカウントごとに分けられません（公式ドキュメントの記述）
- リモートの MCP サーバーは、プロファイルごとにもう一度認証が要るかもしれません（未確認）
- `cam remove` は Keychain の項目を消しません

共通にするファイルの一覧は [ccd](https://github.com/Nael-Nathanael/ccd)（MIT）を参考にしました。
