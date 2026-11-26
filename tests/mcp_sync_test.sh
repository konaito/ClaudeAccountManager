#!/bin/bash
# cam sync の MCP と信頼済みフォルダの同期の回帰テスト。HOME を一時ディレクトリに替えて動かすので、本物の設定には触らない。
# 使い方: tests/mcp_sync_test.sh   （失敗があれば終了コード 1）
set -u
CAM="$(cd "$(dirname "$0")/.." && pwd)/cam"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
P="$HOME/.cam/profiles"
mkdir -p "$HOME/.claude" "$P/ceo" "$P/cto" "$P/coo"

write() { printf '%s\n' "$2" >"$1"; }
check() {  # check <説明> <jq の式> <ファイル> <期待値>
    local got
    got=$(jq -c "$2" "$3" 2>/dev/null)
    if [[ "$got" == "$4" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $4"; echo "     got:  $got"; fail=1; fi
}
sync() { "$CAM" sync "$1" >/dev/null 2>&1; }
keys='.mcpServers | keys'

write "$HOME/.claude.json" '{"mcpServers":{"a":{"type":"http","url":"https://a"}},"projects":{}}'
write "$P/ceo/.claude.json" '{"mcpServers":{"a":{"type":"http","url":"https://a"}}}'
write "$P/cto/.claude.json" '{"mcpServers":{"a":{"type":"http","url":"https://a"}}}'
# coo はまだ一度もログインしていない（.claude.json が無い）

# 1. 大元の MCP は、同期したプロファイルだけでなく全プロファイルに行き渡る
sync ceo
check "大元の MCP が同期したプロファイルに入る" "$keys" "$P/ceo/.claude.json" '["a"]'

# 2. プロファイルの中で足した MCP は、大元とほかのプロファイルに行き渡る（消えない）
jq '.mcpServers.b = {"type":"http","url":"https://b"}' "$P/cto/.claude.json" >"$tmp/x" && mv "$tmp/x" "$P/cto/.claude.json"
sync ceo
check "プロファイルで足した MCP が大元に入る" "$keys" "$HOME/.claude.json" '["a","b"]'
check "プロファイルで足した MCP がほかのプロファイルに入る" "$keys" "$P/ceo/.claude.json" '["a","b"]'
check "足したプロファイル自身からも消えない" "$keys" "$P/cto/.claude.json" '["a","b"]'
[[ -f "$P/coo/.claude.json" ]] && { echo "FAIL ログインしていないプロファイルに .claude.json を作らない"; fail=1; } || echo "ok   ログインしていないプロファイルに .claude.json を作らない"

# 3. 大元から消した MCP は全プロファイルから消え、プロファイルから大元へ戻ってこない
jq 'del(.mcpServers.b)' "$HOME/.claude.json" >"$tmp/x" && mv "$tmp/x" "$HOME/.claude.json"
sync cto
check "大元から消した MCP は大元に戻ってこない" "$keys" "$HOME/.claude.json" '["a"]'
check "大元から消した MCP はプロファイルからも消える" "$keys" "$P/ceo/.claude.json" '["a"]'

# 4. 同じ名前で中身が違うときは大元が勝つ
jq '.mcpServers.a.url = "https://changed"' "$P/ceo/.claude.json" >"$tmp/x" && mv "$tmp/x" "$P/ceo/.claude.json"
sync cto
check "同じ名前なら大元の中身が勝つ" '.mcpServers.a.url' "$P/ceo/.claude.json" '"https://a"'
check "大元の中身は変わらない" '.mcpServers.a.url' "$HOME/.claude.json" '"https://a"'

# 5. 信頼済みのフォルダは、同期したときに全プロファイルへ行き渡る
jq '.projects["/work/x"].hasTrustDialogAccepted = true' "$P/cto/.claude.json" >"$tmp/x" && mv "$tmp/x" "$P/cto/.claude.json"
sync cto
check "あるプロファイルで信頼したフォルダが、ほかのプロファイルにも入る" '.projects["/work/x"].hasTrustDialogAccepted' "$P/ceo/.claude.json" 'true'

# 6. 初めて起動するプロファイル（.claude.json が無い）にも MCP と信頼済みフォルダが入る
sync coo
check "初めて起動するプロファイルに MCP が入る" "$keys" "$P/coo/.claude.json" '["a"]'
check "初めて起動するプロファイルに信頼済みフォルダが入る" '.projects["/work/x"].hasTrustDialogAccepted' "$P/coo/.claude.json" 'true'

# 7. 途中で止まった cam が残したロックがあっても、プロファイルで足した MCP を取り込む
mkdir "$HOME/.cam/.sync.lock" && touch -t 202601010000 "$HOME/.cam/.sync.lock"
jq '.mcpServers.c = {"type":"http","url":"https://c"}' "$P/coo/.claude.json" >"$tmp/x" && mv "$tmp/x" "$P/coo/.claude.json"
sync ceo
check "古いロックが残っていても取り込む" "$keys" "$HOME/.claude.json" '["a","c"]'
[[ -d "$HOME/.cam/.sync.lock" ]] && { echo "FAIL 同期のあとにロックを残さない"; fail=1; } || echo "ok   同期のあとにロックを残さない"

# 8. 大元の MCP 以外の項目は書き換えない
check "大元の projects は書き換えない" '.projects' "$HOME/.claude.json" '{}'

exit $fail
