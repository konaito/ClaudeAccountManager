#!/bin/bash
# cam sync が、変わっていないときは何も書かず、入力が変わったときは同期し直す試験（issue #26）。
# HOME を一時ディレクトリに替えて動かすので、本物の設定には触らない。
# 使い方: tests/sync_unchanged_test.sh   （失敗があれば終了コード 1）
set -u
CAM="$(cd "$(dirname "$0")/.." && pwd)/cam"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
real_home="$HOME"
export HOME="$tmp/home"
mkdir -p "$HOME"
# HOME が一時ディレクトリでなければ、本物を書き換えないよう中断する
tmproot=$(cd "${TMPDIR:-/tmp}" && pwd -P)
if [[ "$HOME" == "$real_home" || "$HOME" != "$tmproot"/* ]]; then
    echo "中断: HOME が一時ディレクトリではありません: $HOME" >&2; exit 2
fi
P="$HOME/.cam/profiles"
B="$HOME/.cam/bin"
# PATH から本物の ~/.cam/bin を外す（残すと cam add が本物の起動用コマンドと同じ名前だとして断る）
jqdir=$(dirname "$(command -v jq)")
export PATH="$B:$jqdir:/usr/bin:/bin:/usr/sbin:/sbin"
case ":$PATH:" in *":$real_home/.cam/bin:"*) echo "中断: PATH に本物の ~/.cam/bin が残っています" >&2; exit 2 ;; esac
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/agents"
: >"$HOME/.claude/settings.json"

check() {  # check <説明> <jq の式> <ファイル> <期待値>
    local got
    got=$(jq -c "$2" "$3" 2>/dev/null)
    if [[ "$got" == "$4" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $4"; echo "     got:  $got"; fail=1; fi
}
ok() { echo "ok   $1"; }
ng() { echo "FAIL $1"; fail=1; }
sync() { "$CAM" sync "$1" >"$tmp/out" 2>&1; }
# 書き込みがあったかを、inode と変更時刻（ナノ秒）で見る。mv で置き換えても、同じ場所に書いても変わる
stamps() {
    local f
    for f in "$HOME/.claude.json" "$P"/*/.claude.json "$HOME/.cam/mcp-distributed.json" "$B"/*; do
        [[ -e "$f" ]] && stat -f '%N %i %Fm' "$f"
    done
}
trusted() { printf '.projects[%s].hasTrustDialogAccepted' "$(jq -Rn --arg p "$1" '$p')"; }

printf '%s\n' '{"mcpServers":{"a":{"type":"http","url":"https://a"}},"projects":{"/w/m":{"hasTrustDialogAccepted":true}},"numStartups":3}' >"$HOME/.claude.json"
"$CAM" add ceo --no-login >/dev/null 2>&1
"$CAM" add cto --no-login >/dev/null 2>&1
"$CAM" add main --default >/dev/null 2>&1
printf '%s\n' '{"projects":{"/w/c":{"hasTrustDialogAccepted":true}},"oauthAccount":{"emailAddress":"cto@example.com"}}' >"$P/cto/.claude.json"
[[ -x "$B/ceo" && -x "$B/cto" && -x "$B/main" ]] || { echo "中断: 起動用コマンドを作れませんでした" >&2; exit 2; }
sync ceo
sync ceo

# 1. 変わっていなければ、どの .claude.json も台帳も起動用コマンドも書かない
before=$(stamps)
sync ceo
sync cto
if [[ "$(stamps)" == "$before" ]]; then ok "変わっていない sync は何も書かない"; else ng "変わっていない sync は何も書かない"; diff <(echo "$before") <(stamps) | sed 's/^/     /'; fi
[[ -s "$tmp/out" ]] && { ng "変わっていない sync は何も言わない（$(cat "$tmp/out")）"; } || ok "変わっていない sync は何も言わない"

# 2. Claude Code が同期と関係のない項目を書き換えても、cam は書かない
jq '.numStartups = 99 | .projects["/w/c"].lastCost = 1' "$P/cto/.claude.json" >"$tmp/x" && mv "$tmp/x" "$P/cto/.claude.json"
before=$(stamps)
sync ceo
if [[ "$(stamps)" == "$before" ]]; then ok "同期と関係のない項目の変更では何も書かない"; else ng "同期と関係のない項目の変更では何も書かない"; fi

# 3. 何も書かない sync の後でも、大元の MCP が変われば全プロファイルに写す
jq '.mcpServers.b = {"type":"http","url":"https://b"}' "$HOME/.claude.json" >"$tmp/x" && mv "$tmp/x" "$HOME/.claude.json"
sync ceo
check "大元に足した MCP が起動したプロファイルに入る" '.mcpServers | keys' "$P/ceo/.claude.json" '["a","b"]'
check "大元に足した MCP がほかのプロファイルにも入る" '.mcpServers | keys' "$P/cto/.claude.json" '["a","b"]'
check "台帳が大元の名前にそろう" '.' "$HOME/.cam/mcp-distributed.json" '["a","b"]'
check "同期と関係のない項目は残る" '.numStartups' "$P/cto/.claude.json" '99'

# 4. MCP の中身だけが変わっても写す
jq '.mcpServers.a.url = "https://a2"' "$HOME/.claude.json" >"$tmp/x" && mv "$tmp/x" "$HOME/.claude.json"
sync cto
check "大元で中身を変えた MCP がほかのプロファイルに入る" '.mcpServers.a.url' "$P/ceo/.claude.json" '"https://a2"'

# 5. どれかのプロファイルで信頼したフォルダは、全部に写す
jq '.projects["/w/new"].hasTrustDialogAccepted = true' "$P/cto/.claude.json" >"$tmp/x" && mv "$tmp/x" "$P/cto/.claude.json"
sync ceo
check "プロファイルで信頼したフォルダが、ほかのプロファイルに入る" "$(trusted /w/new)" "$P/ceo/.claude.json" 'true'

# 6. 信頼済みの印が false に戻されたプロファイルには、true を書き直す
jq '.projects["/w/m"].hasTrustDialogAccepted = false' "$P/ceo/.claude.json" >"$tmp/x" && mv "$tmp/x" "$P/ceo/.claude.json"
sync cto
check "false に戻された信頼済みフォルダを true に戻す" "$(trusted /w/m)" "$P/ceo/.claude.json" 'true'

# 7. プロファイルで足した MCP は、何も書かない sync の後でも大元とほかのプロファイルに入る
sync ceo
jq '.mcpServers.c = {"type":"http","url":"https://c"}' "$P/cto/.claude.json" >"$tmp/x" && mv "$tmp/x" "$P/cto/.claude.json"
sync ceo
check "プロファイルで足した MCP が大元に入る" '.mcpServers | keys' "$HOME/.claude.json" '["a","b","c"]'
check "プロファイルで足した MCP がほかのプロファイルに入る" '.mcpServers | keys' "$P/ceo/.claude.json" '["a","b","c"]'
check "取り込んだ MCP が台帳に入る" '.' "$HOME/.cam/mcp-distributed.json" '["a","b","c"]'

# 8. 読めない .claude.json があっても、ほかのプロファイルは同期し、読めないファイルは書かない
"$CAM" add coo --no-login >/dev/null 2>&1
printf '{"broken":' >"$P/coo/.claude.json"
jq '.mcpServers.d = {"type":"http","url":"https://d"}' "$HOME/.claude.json" >"$tmp/x" && mv "$tmp/x" "$HOME/.claude.json"
sync ceo
check "読めないファイルがあっても、起動したプロファイルは同期する" '.mcpServers | keys' "$P/ceo/.claude.json" '["a","b","c","d"]'
check "読めないファイルがあっても、ほかのプロファイルは同期する" '.mcpServers | keys' "$P/cto/.claude.json" '["a","b","c","d"]'
if [[ "$(cat "$P/coo/.claude.json")" == '{"broken":' ]]; then ok "読めないファイルは書き換えない"; else ng "読めないファイルは書き換えない"; fi
grep -q 'coo/.claude.json を読めないので' "$tmp/out" && ok "読めないファイルを知らせる" || ng "読めないファイルを知らせる（$(cat "$tmp/out")）"
rm "$P/coo/.claude.json"

# 9. 初めて起動するプロファイル（.claude.json が無い）には、ほかが変わっていなくても作る
sync ceo
sync coo
check "初めて起動するプロファイルに MCP が入る" '.mcpServers | keys' "$P/coo/.claude.json" '["a","b","c","d"]'
check "初めて起動するプロファイルに信頼済みフォルダが入る" "$(trusted /w/new)" "$P/coo/.claude.json" 'true'

# 10. 前の版の起動用コマンドは、ほかが変わっていなくても作り直す
sed -i '' 's/|| true/|| :/' "$B/cto"
sync ceo
grep -q '起動用コマンド cto を今の形に作り直しました' "$tmp/out" && ok "前の版の起動用コマンドを作り直す" || ng "前の版の起動用コマンドを作り直す（$(cat "$tmp/out")）"
grep -q '|| :' "$B/cto" && ng "作り直した起動用コマンドが今の形" || ok "作り直した起動用コマンドが今の形"

exit $fail
