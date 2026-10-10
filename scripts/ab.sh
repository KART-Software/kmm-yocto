#!/bin/bash
# ab.sh — PC から機体の A/B を操作する (機体側の ab コマンドの前段)
#
#   ./scripts/ab.sh --host <機体> status
#   ./scripts/ab.sh --host <機体> linux try <image.wic.bz2> [--authkey <鍵>] [--no-reboot]
#   ./scripts/ab.sh --host <機体> linux commit [--force]
#   ./scripts/ab.sh --host <機体> linux rollback [--no-reboot]
#   ./scripts/ab.sh --host <機体> mcore update <m7-fw.img> [--no-reboot]
#   ./scripts/ab.sh --host <機体> mcore rollback [--no-reboot]
#   ./scripts/ab.sh --host <機体> spl update <imx-boot> [--no-reboot]
#   ./scripts/ab.sh --host <機体> spl rollback [--no-reboot]
#   (status / linux status / mcore status / spl status も同様)
#
#   --host <機体>     SSH の宛先 (LAN の IP か Tailscale の名前。root でパスワード無し)
#   --authkey <鍵>    linux try のとき、新しい面の BOOT に Tailscale の auth key を置く
#                     (tailscale-autoconnect が接続後に消す)
#   --no-reboot       書き込みと試行の予約だけして、再起動しない
#   --force           linux commit の健全性の確認を飛ばす / linux try の機種の照合を飛ばす
#
# ファイルを渡す操作は、ファイルを機体の /tmp へ送ってから機体の ab を呼ぶ。
# linux try だけはイメージが 1.5GB あって機体に置けないので、rootfs を gzip で流し込み、
# 機体側で読み戻して sha256 を照合する。書き込みの前に、試行中でないこと・書き込み先が
# マウントされていないこと・イメージの機種が機体と同じことを確かめる。
#
# Linux の試行は確定しない限り、次の再起動で元の面に戻る。確かめて ab linux commit。
# M コアは試した結果が良ければ機体が自動で確定する。SPL は書いた時点で使われ始める。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

HOST=""; AUTHKEY=""; NO_REBOOT=""; FORCE=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --host)      HOST="${2:-}"; shift 2 ;;
        --host=*)    HOST="${1#*=}"; shift ;;
        --authkey)   AUTHKEY="${2:-}"; shift 2 ;;
        --authkey=*) AUTHKEY="${1#*=}"; shift ;;
        --no-reboot) NO_REBOOT="--no-reboot"; shift ;;
        --force)     FORCE="--force"; shift ;;
        -h|--help)   sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          echo "ERROR: unknown option: $1" >&2; exit 1 ;;
        *)           ARGS+=("$1"); shift ;;
    esac
done
[ -n "$HOST" ] || { echo "ERROR: --host が必要" >&2; exit 1; }
[ ${#ARGS[@]} -ge 1 ] || { echo "ERROR: 操作が無い (--help)" >&2; exit 1; }
if [ -n "$AUTHKEY" ] && [ ! -f "$AUTHKEY" ]; then
    echo "ERROR: authkey が見つからない: $AUTHKEY" >&2; exit 1
fi

# -n: リモートに自分の標準入力を吸わせない。SSH_PIPE はデータを流す用 (-n を付けない)
SSH=(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@$HOST")
SSH_PIPE=(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$HOST")

remote_ab() { "${SSH[@]}" ab "$@"; }

# 再起動を伴う操作。機体が再起動して接続が切れるのは成功 (ssh の終了コード 255)
remote_ab_reboot() {
    local r=0
    "${SSH[@]}" ab "$@" || r=$?
    [ $r -eq 0 ] || [ $r -eq 255 ] || exit $r
}

wait_back() {
    echo "==> 機体の再起動を待っています..."
    sleep 15
    local n=0
    until "${SSH[@]}" true 2>/dev/null; do
        n=$((n + 1))
        [ $n -lt 60 ] || { echo "TIMEOUT: 機体が戻ってこない" >&2; exit 1; }
        sleep 3
    done
}

send_file() {   # send_file <ローカル> <機体のパス>
    gzip -c "$1" | "${SSH_PIPE[@]}" "gzip -dc > '$2'"
}

target="${ARGS[0]}"; op="${ARGS[1]:-}"; file="${ARGS[2]:-}"

linux_try() {
    local image="$1"
    [ -n "$image" ] && [ -f "$image" ] || { echo "ERROR: イメージが無い: ${image:-(未指定)}" >&2; exit 1; }
    local missing=""
    for cmd in bunzip2 fdisk gzip e2label tune2fs sha256sum; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] || { echo "ERROR: 必要なコマンドが無い:$missing" >&2; exit 1; }

    # 機種の取り違え防止: イメージ名に機体のホスト名 (= Yocto の MACHINE) が入っていること
    local hostname
    hostname=$("${SSH[@]}" hostname)
    case "$(basename "$image")" in
        *"$hostname"*) ;;
        *) if [ -z "$FORCE" ]; then
               echo "ERROR: イメージ $(basename "$image") は機体 $hostname 向けではないように見える (--force で続行)" >&2
               exit 1
           fi ;;
    esac

    local work
    work=$(mktemp -d /tmp/ab.XXXXXX)
    # 関数を抜けた後の EXIT でも消せるよう、値を埋め込んで登録する
    trap "rm -rf '$work'" EXIT

    echo "==> [1/5] イメージからパーティションを取り出しています ($(basename "$image"))"
    bunzip2 -kc "$image" > "$work/image.wic"
    # fdisk の Sectors 列はブートフラグ '*' の有無で位置がずれるので補正して読む
    wic_sectors() { fdisk -l "$work/image.wic" | awk -v p="wic$1 " 'index($0,p){ if ($2=="*") print $5; else print $4; exit }'; }
    wic_start()   { fdisk -l "$work/image.wic" | awk -v p="wic$1 " 'index($0,p){ if ($2=="*") print $3; else print $2; exit }'; }
    local bs bn rs rn
    bs=$(wic_start 1); bn=$(wic_sectors 1); rs=$(wic_start 5); rn=$(wic_sectors 5)
    [ -n "$bs" ] && [ -n "$rs" ] && [ "$bn" -gt 16384 ] || { echo "ERROR: i.MX の A/B レイアウトのイメージではない" >&2; exit 1; }
    dd if="$work/image.wic" of="$work/boot.img" bs=512 skip="$bs" count="$bn" status=none
    dd if="$work/image.wic" of="$work/root.img" bs=512 skip="$rs" count="$rn" status=none
    rm -f "$work/image.wic"

    echo "==> [2/5] 機体の状態を確認しています"
    local info tgt
    info=$(remote_ab linux try begin)
    echo "$info" | sed 's/^/    /'
    tgt=$(echo "$info" | sed -n 's/^TARGET=//p')
    [ -n "$tgt" ] || { echo "ERROR: 書き込み先の面が分からない" >&2; exit 1; }

    echo "==> [3/5] rootfs を面 $tgt へ書いています (読み戻して sha256 を照合)"
    # 面ごとのラベルと新しい UUID (機体に e2fsprogs が無いので PC で付ける)
    e2label "$work/root.img" "root$tgt"
    tune2fs -U random "$work/root.img" >/dev/null 2>&1 || true
    local size sum
    size=$(stat -c %s "$work/root.img")
    sum=$(sha256sum "$work/root.img" | cut -d' ' -f1)
    gzip -c "$work/root.img" | "${SSH_PIPE[@]}" "ab linux try root $size $sum"

    echo "==> [4/5] boot を面 $tgt へ書いています"
    send_file "$work/boot.img" /tmp/ab-boot.img
    local keyarg=""
    if [ -n "$AUTHKEY" ]; then
        "${SSH_PIPE[@]}" "cat > /tmp/ab-tskey" < "$AUTHKEY"
        keyarg=/tmp/ab-tskey
    fi
    "${SSH[@]}" "ab linux try boot /tmp/ab-boot.img $keyarg; r=\$?; rm -f /tmp/ab-boot.img /tmp/ab-tskey; exit \$r"

    echo "==> [5/5] 試行を予約しています"
    remote_ab_reboot linux try arm $NO_REBOOT
    [ -z "$NO_REBOOT" ] || return 0
    wait_back
    echo "==> 起動した面:"
    remote_ab linux status | sed 's/^/    /'
    echo "    確かめて問題なければ: ./scripts/ab.sh --host $HOST linux commit"
    echo "    確定せずに再起動すれば元の面に戻ります"
}

push_and_run() {   # push_and_run <対象> <ローカルのファイル>
    local t="$1" f="$2" remote="/tmp/ab-$1.img"
    [ -n "$f" ] && [ -f "$f" ] || { echo "ERROR: ファイルが無い: ${f:-(未指定)}" >&2; exit 1; }
    send_file "$f" "$remote"
    "${SSH[@]}" "ab $t update $remote $NO_REBOOT; r=\$?; rm -f $remote; exit \$r" || {
        r=$?
        # 再起動で接続が切れたのは成功 (255 = ssh の切断)
        [ $r -eq 255 ] || exit $r
    }
    [ -z "$NO_REBOOT" ] || return 0
    wait_back
    if [ "$t" = mcore ]; then
        echo "==> M コアの自動確定を待っています (最大 60 秒)"
        sleep 45
    fi
    remote_ab "$t" status | sed 's/^/    /'
}

case "$target $op" in
    "status ") remote_ab status ;;
    "linux try") linux_try "$file" ;;
    "linux commit") remote_ab linux commit $FORCE ;;
    "mcore update"|"spl update") push_and_run "$target" "$file" ;;
    "linux rollback"|"mcore rollback"|"spl rollback")
        remote_ab_reboot "$target" rollback $NO_REBOOT
        [ -n "$NO_REBOOT" ] || { wait_back; remote_ab "$target" status | sed 's/^/    /'; } ;;
    "linux status"|"mcore status"|"spl status") remote_ab "$target" status ;;
    *) echo "ERROR: 不明な操作: ${ARGS[*]} (--help)" >&2; exit 1 ;;
esac
