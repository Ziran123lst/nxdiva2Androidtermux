#!/bin/bash
# 阶段 7-8（指南第 8-9 节）：porter port → 重编宿主 → mkapk 内包 shader 与 mods。
# 在 Ubuntu 的仓库目录里执行：
#   cd /root/nxdiva2Androidtermux
#   bash termux/build.sh "/root/rom" -k "/root/rom/prod.keys" --experimental
# 第一个不以 - 开头的参数是游戏目录，其余参数原样交给 porter port。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
source /root/nx-env.sh
cd "$REPO"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

ROM=""
for a in "$@"; do case "$a" in -*) ;; *) [ -z "$ROM" ] && ROM="$a" ;; esac; done
[ -n "$ROM" ] || die '用法: bash termux/build.sh <游戏目录> [-k prod.keys] [--experimental]'
[ -d "$ROM" ] || die "游戏目录不存在：$ROM"

step "1/3 porter port"
python3 -m porter port "$@" 2>&1 | tee /root/port.log
grep -q '\[8/8\]' /root/port.log || info "日志里没有 [8/8]，请翻 /root/port.log 确认打包是否完整"

BUILD="$(ls -dt "$ROM"/*_build 2>/dev/null | head -1 || true)"
[ -n "$BUILD" ] || die "没找到 <游戏目录>/<TitleID>_build —— porter 没跑完？看 /root/port.log"
TID="$(basename "$BUILD" _build)"
case "$TID" in
    [0-9a-fA-F]*) info "title ID $TID" ;;
    *) die "从 $BUILD 推不出 title ID（得到 $TID）" ;;
esac

# STEM 优先从数据包目录推，避免第二次运行误选 -termux.apk（那样 STEM 变 X-termux、
# DATA 不存在、mods 一个都不内包，且输出名会变成 X-termux-termux.apk）。
# 多个 *-data 时取 mtime 最新的那个（-t 按 mtime 降序，-d 只列目录本身）。
DATA="$(ls -t -d "$ROM"/*-data 2>/dev/null | head -1 || true)"
if [ -n "$DATA" ]; then
    STEM="$(basename "$DATA" -data)"
else
    APK0="$(ls -t "$ROM"/*.apk 2>/dev/null | grep -v -- '-termux\.apk$' | head -1 || true)"
    [ -n "$APK0" ] || die "porter 没产出 APK，也没生成 *-data 目录"
    STEM="$(basename "$APK0" .apk)"
    DATA="$ROM/$STEM-data"
fi
[ -d "$DATA" ] || die "数据包目录不存在：$DATA"
SHADERS="$BUILD/android/shaders.dmsv"
[ -f "$SHADERS" ] || die "没有 shader 包 $SHADERS（[4/8]/[5/8] 阶段失败？）"

step "2/3 重编宿主（改了 C 必须重编，否则 APK 里还是旧逻辑）"
# 版本未注册时 porter 会把 profile 放到 profile-derived/，两种都要试
if [ -d "$BUILD/profile/$TID" ]; then
    export DM_GAMES_DIR="$BUILD/profile"
elif [ -d "$BUILD/profile-derived/$TID" ]; then
    export DM_GAMES_DIR="$BUILD/profile-derived"
else
    die "找不到 $TID 的 profile（profile/ 与 profile-derived/ 都没有）"
fi
export ANDROID_NDK_HOME=/root/android-ndk-r27c
python3 nxnative/dm/android/build.py --game "$TID" --release --lib
SO="$REPO/nxnative/dm/android/out/$TID-release/libdmhost.so"
[ -f "$SO" ] || die "build.py 没产出 $SO"
strings "$SO" | grep -q 'copied from the APK assets' \
    || die "宿主库里没有 6.5 的日志串 —— mods 内包补丁没进这个库"
info "$SO ($(stat -c %s "$SO") bytes)"

step "3/3 mkapk 重打 APK（内包 shader 与 mods）"
ARGS=()
if [ -d "$DATA/mods" ]; then
    for f in "$DATA"/mods/*; do
        [ -f "$f" ] && ARGS+=(--asset "mods/$(basename "$f")=$f")
    done
fi
OUT="$ROM/$STEM-termux.apk"
python3 nxnative/dm/android/apk/mkapk.py \
    "$SO" "$OUT" /root/.config/nx2android/signing-key.json \
    --package "org.nx2a.t${TID,,}" --label "$STEM" --lib dmhost \
    --version-code "${NX_VERCODE:-1000040}" --version-name "${NX_VERNAME:-1.0.9}" \
    --landscape --release \
    --asset "shaders.dmsv=$SHADERS" \
    "${ARGS[@]}"

unzip -l "$OUT" | grep -q 'assets/shaders.dmsv' || die "APK 里没有 assets/shaders.dmsv"
SH_MB=$(( $(stat -c %s "$SHADERS") / 1048576 ))
MB=$(( $(stat -c %s "$OUT") / 1048576 ))
[ "$MB" -ge $(( SH_MB - 1 )) ] || die "APK ${MB} MB 小于 shader 包 ${SH_MB} MB —— shader 没打进去"

printf '\n\033[1m完成。\033[0m\n'
printf '  APK   %s (%s MB)\n' "$OUT" "$MB"
printf '  mods  %d 个内包\n' "${#ARGS[@]}"
printf '  数据包 %s（用 MT 或 adb push 送进 Android/data/<包名>/files/）\n' "$DATA"
