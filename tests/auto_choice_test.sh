#!/bin/bash
# cam auto の選び方の回帰テスト（issue #14）。API と Keychain は使わない。
# 使い方: tests/auto_choice_test.sh   （失敗があれば終了コード 1）
set -u
CAM="$(cd "$(dirname "$0")/.." && pwd)/cam"
NOW=1795671753          # 2026-11-26 14:42 JST
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

expect() {  # expect <説明> <期待する "cam auto:" 行> <入力の行...>
    local desc="$1" want="$2"; shift 2
    printf '%s\n' "$@" >"$tmp/rows"
    got=$(CAM_TEST_USAGE="$tmp/rows" CAM_TEST_NOW=$NOW "$CAM" usage | grep '^cam auto:')
    if [[ "$got" == "$want" ]]; then echo "ok   $desc"; else echo "FAIL $desc"; echo "     want: $want"; echo "     got:  $got"; fail=1; fi
}

# 9時間前の控えの 5h 0% で、上限中の ceo を選ばない（issue #14 の実例）
expect "5時間より前の控えでは選ばない" "cam auto: cto" \
    "ceo cached 0.0 17.0 0 1796126400 1795637731" \
    "cto ok 10.0 10.0 1795678800 1796205600 $NOW"

# 1時間前の控えは、これまでどおり取れた値と同じに扱う
expect "5時間以内の控えは使う" "cam auto: ceo" \
    "ceo cached 0.0 17.0 0 1796126400 $((NOW - 3600))" \
    "cto ok 10.0 10.0 1795678800 1796205600 $NOW"

# 古い控えしか無いときは「判定できない」になる
expect "古い控えだけなら判定できない" "cam auto: （判定できない）" \
    "ceo cached 0.0 17.0 0 1796126400 1795637731"

exit $fail
