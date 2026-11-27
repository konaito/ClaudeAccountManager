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

# ---- 判定できないとき cam auto が起動するコマンド（issue #18） ----
# cam auto は選んだコマンドを exec する。HOME を一時ディレクトリに替え、~/.cam/bin に名前を出すだけの
# 偽物を置く。本物のコマンドを起動しないよう、走らせる前に HOME と偽物を確かめ、違えば中断する。
export HOME="$tmp/home"
MARK="# cam-test-fake"
setup_bin() {  # setup_bin <--default のコマンド（無ければ -）> <名前...>
    local def="$1" n; shift
    rm -rf "$HOME"
    mkdir -p "$HOME/.cam/bin" "$HOME/.cam/profiles"
    for n in "$@"; do
        printf '#!/bin/sh\n%s\necho "%s"\n' "$MARK" "$n" >"$HOME/.cam/bin/$n"
        chmod +x "$HOME/.cam/bin/$n"
        [[ "$n" == "$def" ]] || mkdir -p "$HOME/.cam/profiles/$n"
    done
}
expect_auto() {  # expect_auto <説明> <今の時刻> <期待する起動先> <入力の行...>
    local desc="$1" now="$2" want="$3" f; shift 3
    case "$HOME" in "$tmp"/*) ;; *) echo "中断: HOME が一時ディレクトリではない: $HOME"; exit 2 ;; esac
    for f in "$HOME/.cam/bin"/*; do
        [[ -x "$f" ]] && grep -qx "$MARK" "$f" || { echo "中断: 偽物ではないコマンドがある: $f"; exit 2; }
    done
    printf '%s\n' "$@" >"$tmp/rows"
    got=$(CAM_TEST_USAGE="$tmp/rows" CAM_TEST_NOW=$now "$CAM" auto 2>/dev/null)
    if [[ "$got" == "$want" ]]; then echo "ok   $desc"; else echo "FAIL $desc"; echo "     want: $want"; echo "     got:  $got"; fail=1; fi
}

# 2026-11-28 1:30 の状況（issue #18 の実例）。agent は値が取れて 5h 100%。
# coo・cto・shared は 11/27 03:22〜03:36 の控えしか無く、トークンも期限切れ。値は 01:52 の cam usage から取った。
# ceo の 1:30 の値は記録が無い。issue の「ほかの4アカウントは5時間より前の控えしか無かった」に合わせ、
# coo と同じ時刻の控えで 7d 45%（01:52 の値）と仮置きした。
T0130=1795797000        # 2026-11-28 01:30 JST
setup_bin - agent ceo coo cto shared
expect_auto "判定できないとき上限のアカウントを選ばない（1:30 の実例）" $T0130 "ceo" \
    "agent ok 100.0 81.0 1795798740 1796180340 $T0130" \
    "ceo cached 0.0 45.0 0 1796126340 1795717353 expired" \
    "coo cached 0.0 49.0 0 1796021940 1795717353 expired" \
    "cto cached 0.0 43.0 0 1796205540 1795717353 expired" \
    "shared cached 0 36.0 0 1796011200 1795718198 expired"

# 値の分からないコマンドの中では、控えの5時間枠のリセット時刻を過ぎたものを先に選ぶ
setup_bin - agent ceo coo
expect_auto "判定できないとき5時間枠が戻った控えのコマンドを先に選ぶ" $T0130 "coo" \
    "agent ok 100.0 81.0 1795798740 1796180340 $T0130" \
    "ceo notoken - - 0 0 0" \
    "coo cached 0.0 49.0 0 1796021940 1795717353 expired"

# 5時間以内の控えで上限のコマンドも、値が分かるものとして外す
setup_bin - agent ceo
expect_auto "判定できないとき新しい控えで上限のコマンドも選ばない" $T0130 "ceo" \
    "agent cached 100.0 81.0 1795798740 1796180340 $((T0130 - 600))" \
    "ceo notoken - - 0 0 0"

# 変わらない場面: 値の分かるコマンドが無いときは、これまでどおり --default、無ければ最初のコマンド
setup_bin ceo agent ceo
expect_auto "判定できないとき控えが無ければ --default のコマンド" $T0130 "ceo" \
    "agent notoken - - 0 0 0" \
    "ceo limited - - 0 0 0"
setup_bin - agent ceo
expect_auto "判定できないとき控えが無ければ最初のコマンド" $T0130 "agent" \
    "agent notoken - - 0 0 0" \
    "ceo limited - - 0 0 0"

# 変わらない場面: 全部が上限と分かっているときは起動しない
setup_bin - agent ceo
expect_auto "全部が上限なら起動しない" $T0130 "" \
    "agent ok 100.0 81.0 1795798740 1796180340 $T0130" \
    "ceo ok 30.0 100.0 1795798740 1796180340 $T0130"

exit $fail
