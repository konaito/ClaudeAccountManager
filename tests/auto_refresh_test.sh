#!/bin/bash
# cam auto が期限切れのアカウントを cam refresh で更新してから選ぶことの試験（issue #29）。
# HOME を一時ディレクトリに替え、Keychain は CAM_TEST_KEYCHAIN、API は CAM_TEST_API（アカウントごとのファイル）、
# 動いている claude の一覧は CAM_TEST_PS で差し替える。claude は、Keychain の代わりのファイルの expiresAt を
# 延ばす偽物を PATH の先頭に置く。~/.cam/bin のコマンドは、名前と引数と標準入力を出すだけの偽物にする。
# 本物の claude・Keychain・API・起動用コマンドには触らない。
# 走らせる前に、HOME が一時ディレクトリで、command -v claude が偽物を指し、~/.cam/bin が全部偽物であることを
# 確かめ、違えば中断する。
# 使い方: tests/auto_refresh_test.sh   （失敗があれば終了コード 1、中断は 2）
set -u
CAM="$(cd "$(dirname "$0")/.." && pwd)/cam"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
export HOME="$tmp/home"
export CAM_TEST_KEYCHAIN="$tmp/keychain"
export CAM_TEST_API="$tmp/api"
export CAM_TEST_PS="$tmp/ps"
FAKE="$tmp/fakebin"
CALLS="$tmp/calls"
MARK="# cam-test-fake"
mkdir -p "$FAKE"
export PATH="$FAKE:$PATH"
NOW=$(date +%s)

# 偽の claude。呼ばれた名前を $CALLS/<回数>/name に残し、$tmp/mode に従って Keychain の代わりのファイルを書き換える。
#   extend: expiresAt を今から8時間後にする
#   noop:   何もしない
cat >"$FAKE/claude" <<EOF
#!/bin/bash
# cam-test-fake-claude
n=\$(( \$(ls "$CALLS" 2>/dev/null | wc -l) + 1 ))
d="$CALLS/\$n"; mkdir -p "\$d"
name=\${CLAUDE_CONFIG_DIR##*/}
echo "\$name" >"\$d/name"
f="$tmp/keychain/\$name"
case "\$(cat "$tmp/mode")" in
    extend) jq -c --argjson e "\$(( (\$(date +%s) + 8 * 3600) * 1000 ))" '.claudeAiOauth.expiresAt = \$e' "\$f" >"\$f.t" && mv "\$f.t" "\$f" ;;
esac
echo '{"type":"result","subtype":"success","num_turns":0}'
EOF
chmod +x "$FAKE/claude"

guard() {
    local f
    case "$HOME" in "$tmp"/*) ;; *) echo "中断: HOME が一時ディレクトリではない: $HOME"; exit 2 ;; esac
    [[ "$(command -v claude)" == "$FAKE/claude" ]] || { echo "中断: claude が偽物を指していない: $(command -v claude)"; exit 2; }
    grep -qx '# cam-test-fake-claude' "$(command -v claude)" || { echo "中断: 偽の claude の目印が無い"; exit 2; }
    for f in "$HOME/.cam/bin"/*; do
        [[ -x "$f" ]] && grep -qx "$MARK" "$f" || { echo "中断: 偽物ではないコマンドがある: $f"; exit 2; }
    done
}

# setup <名前...> : コマンドとプロファイルを作り直す。コマンドは「launched <名前> <引数>」と標準入力を出す
setup() {
    local n
    rm -rf "$HOME" "$CAM_TEST_KEYCHAIN" "$CAM_TEST_API" "$CALLS"
    mkdir -p "$HOME/.cam/bin" "$HOME/.cam/profiles" "$CAM_TEST_KEYCHAIN" "$CAM_TEST_API" "$CALLS"
    : >"$CAM_TEST_PS"
    echo extend >"$tmp/mode"
    for n in "$@"; do
        mkdir -p "$HOME/.cam/profiles/$n"
        printf '#!/bin/sh\n%s\necho "launched %s $*"\ncat\n' "$MARK" "$n" >"$HOME/.cam/bin/$n"
        chmod +x "$HOME/.cam/bin/$n"
    done
}
# key <名前> <expiresAt の秒> [refreshTokenExpiresAt の秒] : Keychain の代わりのファイルを置く
key() {
    printf '{"claudeAiOauth":{"accessToken":"at","refreshToken":"old","expiresAt":%s,"refreshTokenExpiresAt":%s}}\n' \
        "$(( $2 * 1000 ))" "$(( ${3:-$((NOW + 86400))} * 1000 ))" >"$CAM_TEST_KEYCHAIN/$1"
}
# api <名前> <5時間枠の使用率> : API が 200 で返す本文を置く。api <名前> 429 : 429 で断る
api() {
    if [[ "$2" == 429 ]]; then
        printf '%s\n%s' '{"error":"rate_limited"}' 429 >"$CAM_TEST_API/$1"
    else
        printf '%s\n%s' "{\"five_hour\":{\"utilization\":$2,\"resets_at\":\"2030-01-01T00:00:00+00:00\"},\"seven_day\":{\"utilization\":10.0,\"resets_at\":\"2030-01-05T00:00:00+00:00\"}}" 200 >"$CAM_TEST_API/$1"
    fi
}
# cache <名前> <取った時刻> [5時間枠の使用率] : 使用率の控えを置く（5h は既定で 30%、7d 10%）
cache() {
    mkdir -p "$HOME/.cam/usage-cache"
    echo "${3:-30.0} 10.0 1893456000 1893801600 $2" >"$HOME/.cam/usage-cache/$1"
}
check() {  # check <説明> <実際の値> <期待する値>
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
calls() { ls "$CALLS" | wc -l | tr -d ' '; }
called() { local d; for d in $(ls "$CALLS" | sort -n); do cat "$CALLS/$d/name"; done | tr '\n' ' '; }
# run_auto : Claude Code のセッションから呼ばれたときと同じ変数を立て、標準入力に hello を流して cam auto -p x を走らせる。
# 標準出力を $tmp/out、標準エラーを $tmp/err、終了コードを $tmp/rc に残す
run_auto() {
    guard
    printf 'hello\n' | env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s CLAUDE_CONFIG_DIR="$HOME/.cam/profiles/other" \
        "$CAM" auto -p x >"$tmp/out" 2>"$tmp/err"
    echo $? >"$tmp/rc"
}
launched() { head -1 "$tmp/out"; }
err_lines() { grep -c "$1" "$tmp/err"; }

# 1. fallback のとき: aa は 5h 95% で保護枠を使う候補だけ。bb は期限切れで控えが無い。
#    bb を更新して取り直すと 5h 10% なので、bb を通常候補として選ぶ
setup aa bb
key aa $((NOW + 3600)); api aa 95.0
key bb $((NOW - 60)); api bb 10.0
run_auto
check "fallback: 期限切れの bb を1回更新する" "$(calls) $(called)" "1 bb "
check "fallback: 更新した bb を選ぶ" "$(launched)" "launched bb -p x"
check "fallback: 標準入力は起動先に届く" "$(sed -n 2p "$tmp/out")" "hello"
check "fallback: 標準出力は起動先の出力だけ" "$(wc -l <"$tmp/out" | tr -d ' ')" "2"
check "fallback: 終了コードは起動先のもの" "$(cat "$tmp/rc")" "0"
check "fallback: 更新の行を stderr に1行出す" "$(err_lines 'cam refresh bb')" "1"
check "fallback: 更新の行に結果を書く" "$(err_lines '^cam: .*cam refresh bb.*更新した')" "1"
check "fallback: 判定できないの行は出ない" "$(err_lines '判定できない')" "0"

# 2. unknown のとき: aa は 429 で値が分からず、bb は期限切れで5時間より古い控えしか無い。
#    更新前なら判定できずに aa を起動していた
setup aa bb
key aa $((NOW + 3600)); api aa 429
key bb $((NOW - 60)); api bb 10.0
cache bb $((NOW - 6 * 3600))
run_auto
check "unknown: 古い控えの期限切れも更新する" "$(calls) $(called)" "1 bb "
check "unknown: 更新した bb を選ぶ" "$(launched)" "launched bb -p x"

# 3. 期限切れが2つあれば、コマンド順に1つずつ更新し、取り直した値で選ぶ
setup aa bb cc
key aa $((NOW - 60)); api aa 50.0
key bb $((NOW - 60)); api bb 10.0
key cc $((NOW + 3600)); api cc 429
run_auto
check "2つ: コマンド順に1つずつ更新する" "$(calls) $(called)" "2 aa bb "
check "2つ: 取り直した値で選ぶ" "$(launched)" "launched bb -p x"
check "2つ: 更新の行はアカウントごとに1行" "$(err_lines '^cam: .*cam refresh')" "2"

# 4. 通常候補があるときは、期限切れのアカウントがあっても更新しない（選ぶ結果が変わらないため）
setup aa bb
key aa $((NOW + 3600)); api aa 10.0
key bb $((NOW - 60)); api bb 10.0
run_auto
check "normal: 更新しない" "$(calls)" "0"
check "normal: aa を選ぶ" "$(launched)" "launched aa -p x"
check "normal: stderr に何も出さない" "$(wc -c <"$tmp/err" | tr -d ' ')" "0"

# 5. 期限切れでも5時間以内の控えがあれば、値は分かっているので更新しない。
#    控えの bb も 5h 95% にして、選ぶ結果が fallback になる（更新の経路に入る）形にする
setup aa bb
key aa $((NOW + 3600)); api aa 95.0
key bb $((NOW - 60)); api bb 10.0
cache bb $((NOW - 600)) 95.0
run_auto
check "新しい控えの期限切れは更新しない" "$(calls)" "0"
check "新しい控えの期限切れ: fallback で aa を起動する" "$(launched) $(err_lines '保護枠を使って aa')" "launched aa -p x 1"

# 6. 全部が上限なら、期限切れのアカウントが無いので更新せずに止まる
setup aa
key aa $((NOW + 3600)); api aa 100.0
run_auto
check "none: 更新せずに止まる" "$(calls) $(cat "$tmp/rc")" "0 1"

# 7. 更新に失敗しても止めず、更新しなかったときと同じく選ぶ
setup aa bb
key aa $((NOW + 3600)); api aa 429
key bb $((NOW - 60)); api bb 10.0
echo noop >"$tmp/mode"
run_auto
check "失敗: 1回走らせる" "$(calls)" "1"
check "失敗: 失敗の行を出す" "$(err_lines '^cam: .*cam refresh bb.*更新されなかった')" "1"
check "失敗: 止めずに判定できないときの選び方で起動する" "$(launched) $(cat "$tmp/rc")" "launched aa -p x 0"

# 8. refresh token の期限切れは refresh_one が飛ばす。止めずに選ぶ
setup aa bb
key aa $((NOW + 3600)); api aa 95.0
key bb $((NOW - 60)) $((NOW - 1)); api bb 10.0
run_auto
check "refresh token 切れ: 走らせない" "$(calls)" "0"
check "refresh token 切れ: 飛ばした理由を出す" "$(err_lines '^cam: .*cam refresh bb.*飛ばした')" "1"
check "refresh token 切れ: 止めずに aa を起動する" "$(launched)" "launched aa -p x"

# 9. 更新はできたが取り直しが 429 でも、止めずに選ぶ
setup aa bb
key aa $((NOW + 3600)); api aa 95.0
key bb $((NOW - 60)); api bb 429
run_auto
check "取り直しが 429: 1回走らせる" "$(calls)" "1"
check "取り直しが 429: 止めずに aa を起動する" "$(launched) $(cat "$tmp/rc")" "launched aa -p x 0"

# 10. 10分以内に試したアカウントは refresh_one が飛ばす
setup aa bb
key aa $((NOW + 3600)); api aa 95.0
key bb $((NOW - 60)); api bb 10.0
mkdir -p "$HOME/.cam/refresh-at"; echo $((NOW - 60)) >"$HOME/.cam/refresh-at/bb"
run_auto
check "10分以内: 走らせない" "$(calls) $(err_lines '^cam: .*cam refresh bb.*飛ばした')" "0 1"

# 11. cam usage と cam usage --json では更新しない（CamBar が定期的に呼ぶため）
setup aa bb
key aa $((NOW + 3600)); api aa 95.0
key bb $((NOW - 60)); api bb 10.0
guard
"$CAM" usage >/dev/null 2>&1
"$CAM" usage --json >/dev/null 2>&1
check "cam usage では更新しない" "$(calls)" "0"

exit $fail
