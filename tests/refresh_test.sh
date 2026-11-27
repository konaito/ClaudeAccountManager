#!/bin/bash
# cam refresh の試験（issue #23）。HOME を一時ディレクトリに替え、Keychain は CAM_TEST_KEYCHAIN、
# 動いている claude の一覧は CAM_TEST_PS で差し替える。claude は、Keychain の代わりのファイルの expiresAt を
# 延ばす偽物を PATH の先頭に置く。本物の claude・Keychain・API には触らない。
# 走らせる前に、HOME が一時ディレクトリで、command -v claude が偽物を指すことを確かめ、違えば中断する。
# 使い方: tests/refresh_test.sh   （失敗があれば終了コード 1、中断は 2）
set -u
CAM="$(cd "$(dirname "$0")/.." && pwd)/cam"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
export HOME="$tmp/home"
export CAM_TEST_KEYCHAIN="$tmp/keychain"
export CAM_TEST_PS="$tmp/ps"
FAKE="$tmp/fakebin"
CALLS="$tmp/calls"
mkdir -p "$FAKE"
export PATH="$FAKE:$PATH"
NOW=$(date +%s)

# 偽の claude。呼ばれた引数、作業フォルダ、標準入力、環境変数を $CALLS/<回数>/ に残し、
# $tmp/mode の中身に従って Keychain の代わりのファイルを書き換える。
#   extend: expiresAt を今から8時間後にし、refreshToken を差し替える
#   noop:   何もしない
#   clear:  accessToken を空、expiresAt を 0 にする（invalid_grant で本体が資格情報を消したとき）
# CLAUDE_CONFIG_DIR が無ければ、$tmp/default_name に書いた名前のファイルを書き換える。
cat >"$FAKE/claude" <<EOF
#!/bin/bash
# cam-test-fake-claude
n=\$(( \$(ls "$CALLS" 2>/dev/null | wc -l) + 1 ))
d="$CALLS/\$n"; mkdir -p "\$d"
printf '%s\n' "\$@" >"\$d/args"
pwd -P >"\$d/pwd"
ls -A | wc -l | tr -d ' ' >"\$d/entries"
cat >"\$d/stdin"
env >"\$d/env"
if [[ -n "\${CLAUDE_CONFIG_DIR:-}" ]]; then name=\${CLAUDE_CONFIG_DIR##*/}; else name=\$(cat "$tmp/default_name"); fi
echo "\$name" >"\$d/name"
f="$tmp/keychain/\$name"
case "\$(cat "$tmp/mode")" in
    extend) jq -c --argjson e "\$(( (\$(date +%s) + 8 * 3600) * 1000 ))" '.claudeAiOauth.expiresAt = \$e | .claudeAiOauth.refreshToken = "new"' "\$f" >"\$f.t" && mv "\$f.t" "\$f" ;;
    clear) jq -c '.claudeAiOauth.accessToken = "" | .claudeAiOauth.expiresAt = 0' "\$f" >"\$f.t" && mv "\$f.t" "\$f" ;;
esac
echo '{"type":"result","subtype":"success","num_turns":0}'
exit \$(cat "$tmp/exit" 2>/dev/null || echo 0)
EOF
chmod +x "$FAKE/claude"

# 中断の確かめ。HOME が一時ディレクトリで、claude が偽物でなければ何も走らせない
guard() {
    case "$HOME" in "$tmp"/*) ;; *) echo "中断: HOME が一時ディレクトリではない: $HOME"; exit 2 ;; esac
    [[ "$(command -v claude)" == "$FAKE/claude" ]] || { echo "中断: claude が偽物を指していない: $(command -v claude)"; exit 2; }
    grep -qx '# cam-test-fake-claude' "$(command -v claude)" || { echo "中断: 偽の claude の目印が無い"; exit 2; }
}
guard

# key <名前> <expiresAt の秒> <refreshTokenExpiresAt の秒> : Keychain の代わりのファイルを置く
key() {
    printf '{"claudeAiOauth":{"accessToken":"at","refreshToken":"old","expiresAt":%s,"refreshTokenExpiresAt":%s}}\n' \
        "$(( $2 * 1000 ))" "$(( $3 * 1000 ))" >"$CAM_TEST_KEYCHAIN/$1"
}
# setup <名前...> : コマンドとプロファイルを作り直す。名前の前に = を付けると ~/.claude のログインのコマンドにする
setup() {
    local n
    rm -rf "$HOME" "$CAM_TEST_KEYCHAIN" "$CALLS"
    mkdir -p "$HOME/.cam/bin" "$HOME/.cam/profiles" "$HOME/.claude" "$CAM_TEST_KEYCHAIN" "$CALLS"
    : >"$CAM_TEST_PS"
    echo extend >"$tmp/mode"; echo 0 >"$tmp/exit"
    for n in "$@"; do
        if [[ "$n" == =* ]]; then
            n=${n#=}; echo "$n" >"$tmp/default_name"
        else
            mkdir -p "$HOME/.cam/profiles/$n"
        fi
        touch "$HOME/.cam/bin/$n"
    done
}
check() {  # check <説明> <実際の値> <期待する値>
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
calls() { ls "$CALLS" | wc -l | tr -d ' '; }
exp_of() { jq -r '.claudeAiOauth.expiresAt / 1000 | floor' "$CAM_TEST_KEYCHAIN/$1"; }
# run <引数...> : cam refresh を走らせ、出力を $tmp/out、終了コードを $tmp/rc に残す。
# Claude Code のセッションから呼ばれたときと同じ変数を立て、標準入力に文字を流す
run() {
    guard
    printf 'stdin-should-not-reach-claude\n' | env CLAUDE_CODE_OAUTH_TOKEN=x ANTHROPIC_API_KEY=x ANTHROPIC_AUTH_TOKEN=x \
        CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_CHILD_SESSION=1 \
        CLAUDE_PID=1 CLAUDE_CODE_MESSAGING_SOCKET=/x CLAUDE_EFFORT=low CLAUDE_PLUGIN_DATA=/x \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CONFIG_DIR="$HOME/.cam/profiles/other" \
        "$CAM" refresh "$@" >"$tmp/out" 2>&1
    echo $? >"$tmp/rc"
}
out() { cat "$tmp/out"; }
rc() { cat "$tmp/rc"; }

EXPECTED_ARGS=$(printf '%s\n' -p /usage --output-format json --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence)

# 1. 期限切れのアカウントを名前で指定すると、偽の claude を1回走らせ、expiresAt が延びたので成功と出す
setup coo
key coo $((NOW - 60)) $((NOW + 86400))
run coo
check "1回だけ走らせる" "$(calls)" "1"
check "成功の行" "$(out | grep -c '^coo  *更新した')" "1"
check "終了コード 0" "$(rc)" "0"
check "expiresAt が延びた" "$(( $(exp_of coo) > NOW + 7 * 3600 ))" "1"
check "引数（--debug-file より前）" "$(sed '/^--debug-file$/,$d' "$CALLS/1/args")" "$EXPECTED_ARGS"
check "--debug-file は ~/.cam/refresh-log/coo の下" "$(sed -n '/^--debug-file$/{n;p;}' "$CALLS/1/args")" "$HOME/.cam/refresh-log/coo/debug.log"
check "CLAUDE_CONFIG_DIR はそのプロファイル" "$(grep '^CLAUDE_CONFIG_DIR=' "$CALLS/1/env")" "CLAUDE_CONFIG_DIR=$HOME/.cam/profiles/coo"
check "作業フォルダは空の一時フォルダ" "$(cat "$CALLS/1/entries") $([[ "$(cat "$CALLS/1/pwd")" != "$HOME"* ]] && echo outside-home)" "0 outside-home"
check "作業フォルダは終わった後に消す" "$([[ -e "$(cat "$CALLS/1/pwd")" ]] && echo left || echo gone)" "gone"
check "標準入力は渡さない" "$(wc -c <"$CALLS/1/stdin" | tr -d ' ')" "0"
check "セッションから継いだ変数を消す" \
    "$(grep -cE '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDECODE|CLAUDE_CODE_SESSION_ID|CLAUDE_CODE_ENTRYPOINT|CLAUDE_CODE_CHILD_SESSION|CLAUDE_PID|CLAUDE_CODE_MESSAGING_SOCKET|CLAUDE_EFFORT|CLAUDE_PLUGIN_DATA|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)=' "$CALLS/1/env")" "0"
check "試した時刻を残す" "$([[ -f "$HOME/.cam/refresh-at/coo" ]] && echo yes)" "yes"

# 2. 10分以内にもう一度呼ぶと、期限切れに戻しても走らせない
key coo $((NOW - 60)) $((NOW + 86400))
run coo
check "10分以内は走らせない" "$(calls) $(out | grep -c '^coo  *飛ばした.*10分')" "1 1"
check "飛ばしたときの終了コードは 0" "$(rc)" "0"

# 3. 前に試したのが10分より前なら走らせる
echo $((NOW - 601)) >"$HOME/.cam/refresh-at/coo"
run coo
check "10分より前なら走らせる" "$(calls)" "2"

# 4. 期限まで5分より先なら走らせない
setup coo
key coo $((NOW + 3600)) $((NOW + 86400))
run coo
check "期限内は走らせない" "$(calls) $(out | grep -c '^coo  *飛ばした.*期限内')" "0 1"

# 5. 期限まで5分以内なら走らせる
setup coo
key coo $((NOW + 120)) $((NOW + 86400))
run coo
check "期限5分以内は走らせる" "$(calls) $(out | grep -c '^coo  *更新した')" "1 1"

# 6. refreshTokenExpiresAt を過ぎていたら走らせず、/login を案内する
setup coo
key coo $((NOW - 60)) $((NOW - 1))
run coo
check "refresh token の期限切れは走らせない" "$(calls) $(out | grep -c '^coo  *飛ばした.*/login')" "0 1"

# 7. そのアカウントの claude が動いていたら走らせない。別のプロファイルや、引数の文字だけの一致では飛ばさない
setup coo cto
key coo $((NOW - 60)) $((NOW + 86400))
key cto $((NOW - 60)) $((NOW + 86400))
printf '%s\n' \
    "111 claude -p hello PATH=/bin CLAUDE_CONFIG_DIR=$HOME/.cam/profiles/coo TERM=x" \
    "222 claude --resume CLAUDE_CONFIG_DIR=$HOME/.cam/profiles/cto-old" \
    "333 claude 文中の CLAUDE_CONFIG_DIR=<プロファイル> PATH=/bin CLAUDE_CONFIG_DIR=$HOME/.cam/profiles/ceo" >"$CAM_TEST_PS"
run coo
check "coo の claude が動いていれば走らせない" "$(calls) $(out | grep -c '^coo  *飛ばした.*動いている.*111')" "0 1"
run cto
check "cto-old の claude では cto を飛ばさない" "$(calls) $(cat "$CALLS/1/name")" "1 cto"

# 8. ロックがあれば走らせない
setup coo
key coo $((NOW - 60)) $((NOW + 86400))
mkdir "$HOME/.cam/profiles/coo/.oauth_refresh.lock"
run coo
check ".oauth_refresh.lock があれば走らせない" "$(calls) $(out | grep -c '^coo  *飛ばした.*ロック')" "0 1"

# 9. 走らせても expiresAt が延びなければ失敗と出し、終了コード 1
setup coo
key coo $((NOW - 60)) $((NOW + 86400))
echo noop >"$tmp/mode"; echo 3 >"$tmp/exit"
run coo
check "延びなければ失敗" "$(calls) $(out | grep -c '^coo  *更新されなかった.*終了コード 3')" "1 1"
check "失敗の終了コードは 1" "$(rc)" "1"

# 10. 資格情報が空になったら、そう出して /login を案内する
setup coo
key coo $((NOW - 60)) $((NOW + 86400))
echo clear >"$tmp/mode"
run coo
check "資格情報が空になった" "$(out | grep -c '^coo  *資格情報が空になった.*/login')" "1"
check "空になったときの終了コードは 1" "$(rc)" "1"

# 11. 名前を省くと、期限切れか5分以内で refresh token が生きているアカウントだけを順に走らせる
setup aa bb cc dd
key aa $((NOW - 60)) $((NOW + 86400))
key bb $((NOW + 3600)) $((NOW + 86400))
key cc $((NOW - 60)) $((NOW - 1))
key dd $((NOW + 60)) $((NOW + 86400))
run
check "名前を省くと対象だけ走らせる" "$(calls) $(cat "$CALLS/1/name") $(cat "$CALLS/2/name")" "2 aa dd"
check "名前を省くと全アカウントを1行ずつ出す" "$(out | awk '{print $1}' | tr '\n' ' ')" "aa bb cc dd "
check "名前を省いたときの終了コード" "$(rc)" "0"

# 12. ~/.claude のログインのコマンドは、CLAUDE_CONFIG_DIR を付けずに走らせる。ロックは ~/.claude を見る
setup '=main'
key main $((NOW - 60)) $((NOW + 86400))
run main
check "~/.claude のコマンドは CLAUDE_CONFIG_DIR なし" "$(calls) $(grep -c '^CLAUDE_CONFIG_DIR=' "$CALLS/1/env") $(out | grep -c '^main  *更新した')" "1 0 1"
setup '=main'
key main $((NOW - 60)) $((NOW + 86400))
mkdir "$HOME/.claude/.oauth_refresh.lock"
run main
check "~/.claude のロックで飛ばす" "$(calls)" "0"
setup '=main'
key main $((NOW - 60)) $((NOW + 86400))
printf '%s\n' "444 claude PATH=/bin CLAUDE_CONFIG_DIR=$HOME/.cam/profiles/coo" >"$CAM_TEST_PS"
run main
check "プロファイルの claude では ~/.claude を飛ばさない" "$(calls)" "1"
setup '=main'
key main $((NOW - 60)) $((NOW + 86400))
printf '%s\n' "555 claude PATH=/bin TERM=x" >"$CAM_TEST_PS"
run main
check "CLAUDE_CONFIG_DIR の無い claude が動いていれば ~/.claude を飛ばす" "$(calls) $(out | grep -c '動いている.*555')" "0 1"

# 13. 無いコマンドの名前は断る
setup coo
run nosuch
check "無い名前は断る" "$(calls) $(rc)" "0 1"

# 15. expiresAt が無いトークンは、期限が分からないので走らせない（cam usage も期限切れとみなさない）
setup coo
printf '{"claudeAiOauth":{"accessToken":"at","refreshTokenExpiresAt":%s}}\n' "$(( (NOW + 86400) * 1000 ))" >"$CAM_TEST_KEYCHAIN/coo"
run coo
check "expiresAt が無ければ走らせない" "$(calls) $(out | grep -c '^coo  *飛ばした.*分からない')" "0 1"

# 16. 試した時刻を書けないときは走らせず、失敗にする（10分に1回の決まりが働かないため）
setup coo
key coo $((NOW - 60)) $((NOW + 86400))
touch "$HOME/.cam/refresh-at"
run coo
check "時刻を書けなければ走らせない" "$(calls) $(rc) $(out | grep -c '^coo  *走らせなかった')" "0 1 1"

# 14. cam usage の期限切れの理由に cam refresh を案内する
setup coo
key coo $((NOW - 60)) $((NOW + 86400))
check "cam usage の期限切れの理由に cam refresh" "$("$CAM" usage | grep -c 'cam refresh coo')" "1"

exit $fail
