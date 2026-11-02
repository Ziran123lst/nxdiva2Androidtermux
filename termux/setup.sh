#!/data/data/com.termux/files/usr/bin/bash
# 阶段 0-1（指南第 1-2 节）：Termux 侧准备，装 Ubuntu，把仓库和环境脚本放进 proot。
# 在本仓库里执行：  bash termux/setup.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="/data/data/com.termux/files/usr"
ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$PREFIX" ] || die "这个脚本要在 Termux 里跑（找不到 $PREFIX）"

step "1/5 更新 Termux 并安装基础包"
pkg update -y
pkg upgrade -y || true
pkg install -y proot-distro clang lld llvm binutils git curl || die "pkg install 失败"
pkg install -y shaderc || info "shaderc 装不上，先继续；后面会检查 \$PREFIX/bin/glslc"

step "2/5 存储权限"
termux-setup-storage || true
[ -d /sdcard ] || info "还没拿到存储权限（弹窗里点允许）。只影响把 APK 拷出去，不影响构建。"

step "3/5 安装 Ubuntu 24.04"
proot-distro install ubuntu 2>/dev/null || proot-distro install ubuntu:24.04 || true
[ -d "$ROOTFS" ] || die "Ubuntu 没装上：找不到 $ROOTFS"

step "4/5 写入 ~/nx.sh（带两个 bind）"
cat > "$HOME/nx.sh" <<'EOS_NX'
#!/data/data/com.termux/files/usr/bin/bash
exec proot-distro login ubuntu \
  --bind /sdcard:/sdcard \
  --bind /data/data/com.termux/files/usr:/data/data/com.termux/files/usr \
  -- "$@"
EOS_NX
chmod +x "$HOME/nx.sh"
"$HOME/nx.sh" bash -c '. /etc/os-release; echo "  Ubuntu $VERSION_ID"'
"$HOME/nx.sh" test -x "$PREFIX/bin/clang" || die "proot 里看不到 Termux 的 clang，nx.sh 的 bind 有问题"
info "clang: $("$HOME/nx.sh" "$PREFIX/bin/clang" --version | head -1)"

step "5/5 把仓库与 setup-env.sh 放进 Ubuntu"
rm -rf "$ROOTFS/root/nxdiva2Androidtermux"
cp -a "$REPO" "$ROOTFS/root/nxdiva2Androidtermux"

cat > "$ROOTFS/root/setup-env.sh" <<'EOS_ENV'
#!/bin/bash
# 阶段 1-4（指南第 2-5 节）：Ubuntu 依赖 / .NET 10 / NDK r27c / 用 Termux clang 顶替 NDK clang。
# 在 Ubuntu 里执行：  bash /root/setup-env.sh
set -euo pipefail

P=/data/data/com.termux/files/usr            # Termux 的 clang 通过 nx.sh 的 bind 挂在这里
TC=/root/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64
# aarch64 的 libunwind.a / libclang_rt.builtins 必须显式匹配 aarch64 目录，两点都不要踩：
#   * 不要写死 clang 主版本号（NDK r28 起 18→19/20），否则目录不存在，链接报
#     unable to find library -l:libunwind.a。
#   * 不要用 find ... | head -1 去找：find 返回顺序里 i386-unknown-linux-gnu、
#     x86_64-unknown-linux-gnu 都可能排在 aarch64 前面，取第一个会命中错架构。
# 正确做法：按 aarch64 前缀 glob（不写死版本号），并对两个库做存在性断言。
LIB=$(ls -d "$TC"/lib/clang/*/lib/linux/aarch64 2>/dev/null | tail -1)
# 这一行在 die() 定义之前执行，不能调 die，用内联的 printf+exit 保证错误信息不丢
[ -n "$LIB" ] || { printf '\033[31m[FAIL]\033[0m 在 %s 下找不到 aarch64 目录\n' "$TC/lib/clang/*/lib/linux/" >&2; exit 1; }

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$P/bin/clang" ] || die "看不到 Termux 的 clang（$P/bin/clang）。用 ~/nx.sh 进 Ubuntu 了吗？"

step "1/4 Ubuntu 依赖"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y python3 python3-pip python3-venv git curl unzip xz-utils ca-certificates file adb libicu74
pip3 install --break-system-packages --upgrade pip
pip3 install --break-system-packages lz4 capstone pillow fonttools pyyaml pycryptodome
pip3 install --break-system-packages backports.zstd || info "backports.zstd 装不上，只影响 NSZ/XCZ 压缩格式"

step "2/4 .NET SDK 10"
curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh
bash /tmp/di.sh --channel 10.0 --install-dir /root/dotnet
/root/dotnet/dotnet --list-sdks | grep -q '^10\.' || die "没装出 .NET 10：$(/root/dotnet/dotnet --list-sdks)"
info "$(/root/dotnet/dotnet --list-sdks)"

step "3/4 Android NDK r27c"
if [ ! -f /root/android-ndk-r27c/source.properties ]; then
    curl -L --retry 3 -o /tmp/ndk.zip https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
    unzip -q /tmp/ndk.zip -d /root && rm -f /tmp/ndk.zip
fi
grep -q 'Pkg.Revision = 27.2.12479018' /root/android-ndk-r27c/source.properties \
    || die "NDK 版本不对：$(grep Pkg.Revision /root/android-ndk-r27c/source.properties)，必须是 27.2.12479018"

step "4/4 编译器替换（关键一步）"
# -L 指向 aarch64 这一份，同时解决 libunwind.a 与 libclang_rt.builtins。
# 只 symlink libunwind.a 的话，下一步会报 builtins 缺失。
[ -f "$LIB/libunwind.a" ] || die "找不到 $LIB/libunwind.a —— aarch64 的 libunwind.a 缺失"
[ -f "$LIB/libclang_rt.builtins-aarch64-android.a" ] || die "找不到 $LIB/libclang_rt.builtins-aarch64-android.a —— aarch64 的 builtins 缺失"
[ -e "$TC/bin/clang.real" ]   || mv "$TC/bin/clang"   "$TC/bin/clang.real"
[ -e "$TC/bin/clang++.real" ] || mv "$TC/bin/clang++" "$TC/bin/clang++.real"
printf '#!/bin/sh\nexec %s/bin/clang --sysroot=%s/sysroot -L%s "$@"\n'  "$P" "$TC" "$LIB" > "$TC/bin/clang"
printf '#!/bin/sh\nexec %s/bin/clang++ --sysroot=%s/sysroot -L%s "$@"\n' "$P" "$TC" "$LIB" > "$TC/bin/clang++"
chmod +x "$TC/bin/clang" "$TC/bin/clang++"
ln -sf "$P/bin/llvm-strip" "$TC/bin/llvm-strip"
mkdir -p /root/android-ndk-r27c/shader-tools/linux-x86_64
[ -x "$P/bin/glslc" ] || die "缺 Termux 的 glslc：回 Termux 执行 pkg install -y shaderc"
ln -sf "$P/bin/glslc" /root/android-ndk-r27c/shader-tools/linux-x86_64/glslc

echo 'int main(void){return 0;}' > /tmp/t.c
"$TC/bin/clang" --target=aarch64-linux-android31 -c /tmp/t.c -o /tmp/t.o
file /tmp/t.o | grep -q 'ARM aarch64' || die "clang 没在编 aarch64：$(file /tmp/t.o) —— 阶段 4 没做成"
info "$(file /tmp/t.o | cut -d: -f2-)"

cat > /root/nx-env.sh <<'EOS_NXENV'
export DOTNET_ROOT=/root/dotnet
export PATH=/root/dotnet:$PATH
export ANDROID_NDK_HOME=/root/android-ndk-r27c
EOS_NXENV

printf '\n\033[1m环境就绪。\033[0m 下一步：\n'
printf '  cd /root/nxdiva2Androidtermux\n'
printf '  source /root/nx-env.sh && python3 -m porter doctor\n'
EOS_ENV
chmod +x "$ROOTFS/root/setup-env.sh"

printf '\n\033[1mTermux 侧就绪。\033[0m 下一步：\n'
printf '  ~/nx.sh bash /root/setup-env.sh\n'
