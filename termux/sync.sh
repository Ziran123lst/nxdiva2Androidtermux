#!/data/data/com.termux/files/usr/bin/bash
# 把 Termux 侧的仓库重新同步进 proot 的 Ubuntu。
# setup.sh 是 cp -a 复制（不是 bind 挂载），所以在 Termux 里 git pull 或改完代码后，
# 必须跑一次本脚本，rootfs 里那份才会更新。
# 用法（Termux 里，仓库根目录）：  bash termux/sync.sh
#
# 注意：不同 proot-distro 版本的 rootfs 实际路径不固定（有的在 installed-rootfs/ubuntu，
# 有的在别处，注册信息还可能残留）。所以这里**不走 rootfs 路径**，而是借 ~/nx.sh 的
# bind：Termux home 被挂到 /termux/home，直接往 /termux/home/<仓库名> 复制即可。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOME_NX="$HOME/nx.sh"

die() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$HOME_NX" ] || die "先跑 bash termux/setup.sh（找不到 $HOME_NX）"

"$HOME_NX" bash -c "rm -rf /root/nxdiva2Androidtermux; cp -a /termux/home/$(basename "$REPO") /root/"
"$HOME_NX" git -C /root/nxdiva2Androidtermux log --oneline -1 || true
echo "同步完成"
