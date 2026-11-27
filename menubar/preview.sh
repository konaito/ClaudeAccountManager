#!/bin/bash
# CamBar のメニューの中身を、決まった状況の `cam usage --json` で PNG に描く（見た目の確かめ用）。
# JSON は cam 自身に作らせる。HOME を一時ディレクトリに替え、使用率は CAM_TEST_USAGE、今の時刻は CAM_TEST_NOW で
# 差し替えるので、本物の設定・Keychain・API・控えには触らない。メニューバーにも何も出さない。
# 使い方: menubar/preview.sh [書き出し先のディレクトリ]   （既定は menubar/.build/preview）
# 書き出すもの: <状況>.json と <状況>.png。メニューバーのタイトルは標準出力に出す。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cam="$here/../cam"
out="${1:-$here/.build/preview}"
mkdir -p "$out"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

(cd "$here" && swift build -q)
bin="$(cd "$here" && swift build --show-bin-path)/CamBar"

at() { date -j -f "%Y-%m-%d %H:%M:%S" "$1:00" +%s; }

# scenario <名前> <今の時刻> : 標準入力の行（usage_row の形）で JSON を作って描く
scenario() {
    local name="$1" now
    now=$(at "$2")
    cat >"$tmp/rows"
    HOME="$tmp/home" CAM_TEST_USAGE="$tmp/rows" CAM_TEST_NOW="$now" "$cam" usage --json \
        | jq --argjson now "$now" '.fetched_at = $now | .accounts |= map(.email = "\(.name)@example.com")' \
        >"$out/$name.json"
    echo "$name: $("$bin" --render "$out/$name.json" "$out/$name.png" "$now")"
}

# 2026-11-28 1:30 の状況（issue #21）。agent は5時間枠が上限、ほかは前日 3:22・3:36 の控えでトークンが期限切れ。
# 控えは5時間より古いので cam auto では使わず、choice は unknown になる。
# 控えの5時間枠はリセット時刻を過ぎているので、usage_row と同じく 0% とリセット時刻 0 にしてある。
scenario unknown "2026-11-28 01:30" <<EOF
agent ok 100.0 62.0 $(at "2026-11-28 03:00") $(at "2026-12-02 10:00") $(at "2026-11-28 01:30")
ceo cached 0 55.0 0 $(at "2026-12-01 09:00") $(at "2026-11-27 03:36") expired
coo cached 0 20.0 0 $(at "2026-12-03 18:00") $(at "2026-11-27 03:22") expired
cto cached 0 31.0 0 $(at "2026-12-02 21:00") $(at "2026-11-27 03:36") expired
shared cached 0 44.0 0 $(at "2026-12-04 08:00") $(at "2026-11-27 03:22") expired
EOF

# 全部が上限の状況。当日の控え（ceo）には日付を付けない。choice は none になる
scenario none "2026-11-28 14:00" <<EOF
agent ok 100.0 62.0 $(at "2026-11-28 15:00") $(at "2026-12-02 10:00") $(at "2026-11-28 14:00")
ceo cached 100.0 55.0 $(at "2026-11-28 16:30") $(at "2026-12-01 09:00") $(at "2026-11-28 12:10") expired
coo ok 40.0 100.0 $(at "2026-11-28 18:00") $(at "2026-11-30 09:00") $(at "2026-11-28 14:00")
EOF

# 選べる状況。控えも無い期限切れ（coo）は、これまでどおり「不明」と理由を行の中に出す
scenario normal "2026-11-28 14:00" <<EOF2
agent ok 20.0 30.0 $(at "2026-11-28 15:00") $(at "2026-12-02 10:00") $(at "2026-11-28 14:00")
coo notoken - - 0 0 0 expired
EOF2
