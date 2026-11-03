#!/data/data/com.termux/files/usr/bin/bash
# 把 Termux 侧的仓库重新同步进 proot 的 Ubuntu。
# setup.sh 是 cp -a 复制（不是 bind 挂载），所以在 Termux 里 git pull 或改完代码后，
# 必须跑一次本脚本，rootfs 里那份才会更新。
# 用法（Termux 里，仓库根目录）：  bash termux/sync.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="/data/data/com.termux/files/usr"
ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$PREFIX" ] || die "这个脚本要在 Termux 里跑（找不到 $PREFIX）"
[ -d "$ROOTFS" ] || die "Ubuntu 没装上：找不到 $ROOTFS（先跑 bash termux/setup.sh）"

step "1/2 同步仓库"
rm -rf "$ROOTFS/root/nxdiva2Androidtermux"
cp -a "$REPO" "$ROOTFS/root/nxdiva2Androidtermux"
info "$REPO -> $ROOTFS/root/nxdiva2Androidtermux"

step "2/2 报告 rootfs 里的版本"
if [ -d "$ROOTFS/root/nxdiva2Androidtermux/.git" ]; then
    git -C "$ROOTFS/root/nxdiva2Androidtermux" log --oneline -1 || true
else
    info "（没有 .git，可能是源码包而非 clone）"
fi
printf '\n\033[1m同步完成。\033[0m 在 Ubuntu 里继续：\n'
printf '  ~/nx.sh bash -c "cd /root/nxdiva2Androidtermux && bash termux/build.sh ..."\n'
