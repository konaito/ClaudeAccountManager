#!/bin/bash
# 起動用コマンドが、claude を起動する前に起動したフォルダを信頼済みにする試験（issue #24）。
# HOME を一時ディレクトリに替え、PATH の先頭に偽の claude を置いて動かすので、本物の設定と Claude Code には触らない。
# 使い方: tests/trust_on_launch_test.sh   （失敗があれば終了コード 1）
set -u
CAM="$(cd "$(dirname "$0")/.." && pwd)/cam"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
real_home="$HOME"
# 親の Claude Code から受け継いだプロファイルを外す（--default の起動を確かめるため）
unset CLAUDE_CONFIG_DIR
export HOME="$tmp/home"
mkdir -p "$HOME"
# HOME が一時ディレクトリでなければ、本物を書き換えないよう中断する
tmproot=$(cd "${TMPDIR:-/tmp}" && pwd -P)
if [[ "$HOME" == "$real_home" || "$HOME" != "$tmproot"/* ]]; then
    echo "中断: HOME が一時ディレクトリではありません: $HOME" >&2; exit 2
fi

# 偽の claude。起動したフォルダと CLAUDE_CONFIG_DIR と引数を書き出すだけ
mkdir -p "$tmp/fakebin"
cat >"$tmp/fakebin/claude" <<EOF
#!/bin/bash
echo "\$(pwd -P)|\${CLAUDE_CONFIG_DIR:-}|\$*" >"$tmp/launched"
EOF
chmod +x "$tmp/fakebin/claude"
# PATH から本物の ~/.cam/bin を外す（残すと本物の起動用コマンドを呼びうる）。jq と git は今の場所のものを使う
jqdir=$(dirname "$(command -v jq)"); gitdir=$(dirname "$(command -v git)")
export PATH="$tmp/fakebin:$HOME/.cam/bin:$jqdir:$gitdir:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ "$(command -v claude)" != "$tmp/fakebin/claude" ]]; then
    echo "中断: claude が偽物を指していません: $(command -v claude)" >&2; exit 2
fi
case ":$PATH:" in *":$real_home/.cam/bin:"*) echo "中断: PATH に本物の ~/.cam/bin が残っています" >&2; exit 2 ;; esac

B="$HOME/.cam/bin"
P="$HOME/.cam/profiles"
W="$tmp/work"
mkdir -p "$B" "$HOME/.claude" "$W"
ln -s "$CAM" "$B/cam"

check() {  # check <説明> <jq の式> <ファイル> <期待値>
    local got
    got=$(jq -c "$2" "$3" 2>/dev/null)
    if [[ "$got" == "$4" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $4"; echo "     got:  $got"; fail=1; fi
}
ok() { echo "ok   $1"; }
ng() { echo "FAIL $1"; fail=1; }
trusted() { printf '.projects[%s].hasTrustDialogAccepted' "$(jq -Rn --arg p "$1" '$p')"; }
launch() {  # launch <フォルダ> <起動用コマンドの名前> [引数...]。一時 HOME の起動用コマンドを絶対パスで呼ぶ
    local dir="$1" name="$2"; shift 2
    rm -f "$tmp/launched"
    (cd "$dir" && "$B/$name" "$@") >"$tmp/out" 2>&1
}
sums() { cksum "$HOME/.claude.json" "$P"/*/.claude.json 2>/dev/null; }

# ~/Documents に当たるフォルダ（$W）は全アカウントで信頼済み
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$W" >"$HOME/.claude.json"
mkdir -p "$P/ceo" "$P/cto"
cp "$HOME/.claude.json" "$P/ceo/.claude.json"
cp "$HOME/.claude.json" "$P/cto/.claude.json"
"$CAM" add ceo --no-login >/dev/null 2>&1
"$CAM" add cto --no-login >/dev/null 2>&1
"$CAM" add main --default >/dev/null 2>&1
[[ -x "$B/ceo" && -x "$B/main" ]] || { echo "中断: 起動用コマンドを作れませんでした" >&2; exit 2; }

git_init() { git init -q "$1" && git -C "$1" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init; }

# 1. 信頼済みのフォルダの下にある git リポジトリのサブフォルダで起動すると、リポジトリのいちばん上が全部の .claude.json で信頼済みになる
git_init "$W/repo"; mkdir -p "$W/repo/src/a"
launch "$W/repo/src/a" ceo --resume x
check "大元にリポジトリのいちばん上が入る" "$(trusted "$W/repo")" "$HOME/.claude.json" true
check "起動したプロファイルに入る" "$(trusted "$W/repo")" "$P/ceo/.claude.json" true
check "ほかのプロファイルにも入る" "$(trusted "$W/repo")" "$P/cto/.claude.json" true
check "サブフォルダそのものは書かない" "$(trusted "$W/repo/src/a")" "$P/ceo/.claude.json" null
if [[ "$(cat "$tmp/launched" 2>/dev/null)" == "$W/repo/src/a|$P/ceo|--resume x" ]]; then ok "そのあと claude を同じフォルダ・プロファイル・引数で起動する"; else ng "そのあと claude を同じフォルダ・プロファイル・引数で起動する（$(cat "$tmp/launched" 2>/dev/null)）"; fi

# 2. すでに信頼済みなら、どのファイルも書き換えない
before=$(sums)
launch "$W/repo/src" cto
[[ "$(sums)" == "$before" ]] && ok "信頼済みのリポジトリでは何も書き換えない" || ng "信頼済みのリポジトリでは何も書き換えない"

# 3. シンボリックリンク越しに起動しても、実体のパスを書く（Claude Code は実体のパスで探す）
git_init "$W/real"; ln -s "$W/real" "$tmp/link"
launch "$tmp/link" ceo
check "リンク越しの起動で実体のパスが入る" "$(trusted "$W/real")" "$P/ceo/.claude.json" true
check "リンクのパスは書かない" "$(trusted "$tmp/link")" "$P/ceo/.claude.json" null

# 4. git worktree の中では worktree のいちばん上を書く
git -C "$W/repo" worktree add -q "$W/wt" 2>/dev/null; mkdir -p "$W/wt/sub"
launch "$W/wt/sub" ceo
check "worktree のいちばん上が入る" "$(trusted "$W/wt")" "$P/ceo/.claude.json" true

# 5. .git がファイルのフォルダ（サブモジュールの形）では、そのフォルダをいちばん上とみなす
mkdir -p "$W/repo/mod/x"; echo "gitdir: ../.git/modules/mod" >"$W/repo/mod/.git"
launch "$W/repo/mod/x" ceo
check "サブモジュールの形のフォルダが入る" "$(trusted "$W/repo/mod")" "$P/ceo/.claude.json" true

# 6. git の外で、親が信頼済みなら何も書かない
mkdir -p "$W/plain/sub"
before=$(sums)
launch "$W/plain/sub" ceo
[[ "$(sums)" == "$before" ]] && ok "親が信頼済みの git の外のフォルダでは何も書き換えない" || ng "親が信頼済みの git の外のフォルダでは何も書き換えない"

# 7. git の外で、親も信頼されていなければ、起動したフォルダを書く
mkdir -p "$tmp/outside/d"
launch "$tmp/outside/d" ceo
check "信頼されていない git の外のフォルダが入る" "$(trusted "$tmp/outside/d")" "$P/cto/.claude.json" true

# 8. ホームフォルダでは書かない（Claude Code はホームの信頼を記録しない）
launch "$HOME" ceo
check "ホームフォルダは書かない" "$(trusted "$HOME")" "$P/ceo/.claude.json" null
# ホームが git リポジトリでも、その下の git の外のフォルダでホームを書かない
mkdir -p "$HOME/.git" "$HOME/Downloads"
launch "$HOME/Downloads" ceo
check "ホームが git リポジトリでもホームを書かない" "$(trusted "$HOME")" "$P/ceo/.claude.json" null
rmdir "$HOME/.git"

# 9. --default のコマンドでも、全部の .claude.json に書いてから ~/.claude のまま起動する
git_init "$W/repo2"
launch "$W/repo2" main
check "--default でも大元に入る" "$(trusted "$W/repo2")" "$HOME/.claude.json" true
check "--default でもプロファイルに入る" "$(trusted "$W/repo2")" "$P/cto/.claude.json" true
if [[ "$(cat "$tmp/launched" 2>/dev/null)" == "$W/repo2||" ]]; then ok "--default は CLAUDE_CONFIG_DIR を付けずに起動する"; else ng "--default は CLAUDE_CONFIG_DIR を付けずに起動する（$(cat "$tmp/launched" 2>/dev/null)）"; fi

# 10. 読めない .claude.json は書かず、ほかのファイルには書き、起動は止めない
echo '{broken' >"$P/cto/.claude.json"
git_init "$W/repo3"
launch "$W/repo3" ceo
[[ "$(cat "$P/cto/.claude.json")" == '{broken' ]] && ok "読めない .claude.json は書き換えない" || ng "読めない .claude.json は書き換えない"
check "読めないファイルがあってもほかには入る" "$(trusted "$W/repo3")" "$P/ceo/.claude.json" true
[[ -f "$tmp/launched" ]] && ok "読めないファイルがあっても起動する" || ng "読めないファイルがあっても起動する"
cp "$P/ceo/.claude.json" "$P/cto/.claude.json"

# 11. 前の版の cam が作った起動用コマンドは、cam sync で今の形に作り直され、次の起動から信頼済みにする
cat >"$B/cto" <<EOF
#!/bin/bash
# cam: cto は ~/.cam/profiles/cto で起動する
"$B/cam" sync "cto" || true
CLAUDE_CONFIG_DIR="$P/cto" exec claude "\$@"
EOF
chmod +x "$B/cto"
# 前の版の起動用コマンドで起動すると、その中の cam sync が自分自身を作り直す。それでも最後まで動いて claude を起動する
launch "$W/plain" cto
[[ -f "$tmp/launched" ]] && ok "作り直されている最中の起動用コマンドも claude を起動する" || ng "作り直されている最中の起動用コマンドも claude を起動する"
grep -q ' trust' "$B/cto" && ok "前の版の起動用コマンドを cam sync で作り直す" || ng "前の版の起動用コマンドを cam sync で作り直す"
[[ -x "$B/cto" ]] && ok "作り直した起動用コマンドは実行できる" || ng "作り直した起動用コマンドは実行できる"
git_init "$W/repo4"
launch "$W/repo4" cto
check "作り直した起動用コマンドで信頼済みになる" "$(trusted "$W/repo4")" "$P/cto/.claude.json" true

# 12. cam が作ったものでない同名のファイルは作り直さない
printf '#!/bin/bash\n# 手で書いたもの\nexec claude "$@"\n' >"$B/ceo"
"$CAM" sync ceo >/dev/null 2>&1
grep -q '手で書いたもの' "$B/ceo" && ok "cam が作ったものでない起動用コマンドは作り直さない" || ng "cam が作ったものでない起動用コマンドは作り直さない"

exit $fail
