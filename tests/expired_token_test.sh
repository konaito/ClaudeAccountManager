#!/bin/bash
# 期限切れのトークンの回帰テスト（issue #17）。HOME を一時ディレクトリに替え、Keychain は CAM_TEST_KEYCHAIN、
# API は CAM_TEST_API で差し替えるので、本物の設定・Keychain・API には触らない。
# 使い方: tests/expired_token_test.sh   （失敗があれば終了コード 1）
set -u
CAM="$(cd "$(dirname "$0")/.." && pwd)/cam"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export CAM_TEST_KEYCHAIN="$tmp/keychain"
export CAM_TEST_API="$tmp/api"
NOW=$(date +%s)
PAST_MS=$(( (NOW - 3600) * 1000 ))
FUTURE_MS=$(( (NOW + 3600) * 1000 ))

# setup <名前> <claudeAiOauth の JSON> <API の本文> <API の状態コード>
# コマンドを1つだけにして、Keychain と API の応答を置く。控えは消す。
setup() {
    rm -rf "$HOME" "$CAM_TEST_KEYCHAIN"
    mkdir -p "$HOME/.cam/bin" "$CAM_TEST_KEYCHAIN"
    touch "$HOME/.cam/bin/$1"
    printf '{"claudeAiOauth":%s}\n' "$2" >"$CAM_TEST_KEYCHAIN/$1"
    printf '%s\n%s' "$3" "$4" >"$CAM_TEST_API"
}
check() {  # check <説明> <実際の値> <期待する値>
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
json() { "$CAM" usage --json | jq -r "$1"; }

OK_BODY='{"five_hour":{"utilization":12.0,"resets_at":"2026-11-28T10:00:00.000000+00:00"},"seven_day":{"utilization":40.0,"resets_at":"2026-12-01T00:00:00+00:00"}}'
EXPIRED_REASON="トークンの期限切れ。一度 coo を起動すると更新される"

# 1. 期限切れのトークンは API を呼ばずに notoken になる。期限切れのトークンで API は 429 を返す（2026-11-28 の実例）
setup coo "{\"accessToken\":\"x\",\"expiresAt\":$PAST_MS}" '{"error":"rate_limited"}' 429
check "期限切れは notoken（--json の status）" "$(json '.accounts[0].status')" "notoken"
check "期限切れの理由（--json の reason）" "$(json '.accounts[0].reason')" "$EXPIRED_REASON"
check "期限切れの理由（cam usage）" "$("$CAM" usage | grep -c "coo .*不明（${EXPIRED_REASON}）")" "1"

# 2. 控えがあっても、期限切れなら控えの値ではなく期限切れを出す
mkdir -p "$HOME/.cam/usage-cache"
echo "0.0 49.0 0 1796021999 $((NOW - 600))" >"$HOME/.cam/usage-cache/coo"
check "控えがあっても期限切れは notoken" "$(json '.accounts[0].status')" "notoken"

# 3. 期限内のトークンは、これまでどおり API の値で ok になる
setup ceo "{\"accessToken\":\"x\",\"expiresAt\":$FUTURE_MS}" "$OK_BODY" 200
check "期限内は ok" "$(json '.accounts[0] | "\(.status) \(.five_hour == 12) \(.seven_day == 40)"')" "ok true true"

# 4. expiresAt が無いトークンは期限切れとみなさず API を呼ぶ
setup ceo '{"accessToken":"x"}' "$OK_BODY" 200
check "expiresAt が無ければ API を呼ぶ" "$(json '.accounts[0].status')" "ok"

# 5. 期限内でも API が 429 なら、これまでどおり limited
setup ceo "{\"accessToken\":\"x\",\"expiresAt\":$FUTURE_MS}" '{"error":"rate_limited"}' 429
check "期限内の 429 は limited" "$(json '.accounts[0].status')" "limited"

# 6. トークンが無いときは、これまでどおり notoken で、理由は期限切れとは分ける
setup ceo 'null' '' 000
check "トークンが無ければ notoken" "$(json '.accounts[0] | "\(.status) \(.reason)"')" \
    "notoken トークンが無いか期限切れ。一度 ceo を起動すると更新される"

exit $fail
