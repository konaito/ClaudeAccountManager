#!/bin/bash
# 起動用コマンドの前段（cam trust と cam sync <名前>）の時間を、2つの版の cam で交互に測る（issue #26）。
# 本物の ~/.claude.json とプロファイルの .claude.json は読んで一時 HOME に写すだけで、本物には書かない。
# ~/.claude とプロファイルの中身は、名前と種類（ファイル、フォルダ、リンク）だけを空の実体で写す。
# 使い方: bench/launch_prefix.sh [回数=15] [比べる版=origin/main] [名前=ceo]
#   出力: 1行に「old|new ミリ秒」。最後に版ごとの中央値と範囲。時刻は perl で取るので、1回あたり約10msの起動分を両方に含む。
set -u
N="${1:-15}" REF="${2:-origin/main}" NAME="${3:-ceo}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HOME"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
H="$tmp/home"
tmproot=$(cd "${TMPDIR:-/tmp}" && pwd -P)
if [[ "$H" == "$SRC" || "$H" != "$tmproot"/* ]]; then
    echo "中断: HOME が一時ディレクトリではありません: $H" >&2; exit 2
fi
[[ -d "$SRC/.cam/profiles/$NAME" ]] || { echo "中断: プロファイルがありません: $NAME" >&2; exit 2; }

git -C "$REPO" show "$REF:cam" >"$tmp/cam_old" || exit 2
chmod +x "$tmp/cam_old"
NEW="$REPO/cam" OLD="$tmp/cam_old"

# 本物と同じ形の一時 HOME を作る
copy_shape() {  # copy_shape <元のフォルダ> <先のフォルダ>。.claude.json は中身ごと、ほかは空の実体かリンクで写す
    local s="$1" d="$2" e b t
    mkdir -p "$d"
    for e in "$s"/* "$s"/.[!.]*; do
        [[ -e "$e" || -L "$e" ]] || continue
        b=${e##*/}
        if [[ -L "$e" ]]; then
            t=$(readlink "$e"); ln -s "${t/#$SRC\//$H/}" "$d/$b"
        elif [[ "$b" == .claude.json ]]; then
            cp "$e" "$d/$b"
        elif [[ -d "$e" ]]; then
            mkdir -p "$d/$b"
        else
            : >"$d/$b"
        fi
    done
}
mkdir -p "$H/.cam/profiles" "$H/.cam/bin"
cp "$SRC/.claude.json" "$H/.claude.json"
[[ -f "$SRC/.cam/mcp-distributed.json" ]] && cp "$SRC/.cam/mcp-distributed.json" "$H/.cam/"
copy_shape "$SRC/.claude" "$H/.claude"
for p in "$SRC/.cam/profiles"/*; do copy_shape "$p" "$H/.cam/profiles/${p##*/}"; done
for f in "$SRC/.cam/bin"/*; do
    [[ "${f##*/}" == cam || -L "$f" ]] && continue
    sed "s#$SRC/#$H/#g" "$f" >"$H/.cam/bin/${f##*/}"; chmod 755 "$H/.cam/bin/${f##*/}"
done
ln -s "$NEW" "$H/.cam/bin/cam"

now() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }
run() {
    local s e
    s=$(now)
    HOME="$H" "$1" trust || echo "ERR trust $1" >&2
    HOME="$H" "$1" sync "$NAME" || echo "ERR sync $1" >&2
    e=$(now)
    echo $((e - s))
}
# 1回ずつ空走りして、trust と sync が書くものを書き終えた状態にする
run "$OLD" >/dev/null 2>&1; run "$NEW" >/dev/null 2>&1
for ((i = 0; i < N; i++)); do
    if ((i % 2)); then
        echo "new $(run "$NEW")"; echo "old $(run "$OLD")"
    else
        echo "old $(run "$OLD")"; echo "new $(run "$NEW")"
    fi
done | tee "$tmp/out"
for v in old new; do
    awk -v v="$v" '$1 == v {print $2}' "$tmp/out" | sort -n | awk -v v="$v" '
        {a[NR] = $1}
        END {m = NR % 2 ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2
             printf "%s: %d回 中央値 %s ms（%s〜%s ms）\n", v, NR, m, a[1], a[NR]}'
done
