#!/data/data/com.termux/files/usr/bin/bash
# termux/setup.sh —— 修正版
# 相比仓库早期版本，修掉了在 Ubuntu 26.04 / proot-distro 新版本上踩到的 6 个坑：
#   1. 容器"已存在"但 rootfs 缺失（半残留）→ 不再依赖 installed-rootfs 路径，改用 login 探测 + reset
#   2. Ubuntu 是 26.04，没有 libicu74 → 改用 libicu-dev（版本无关）
#   3. Python 3.14 装不上 backports.zstd → 明确忽略（3.14 已内置 compression.zstd）
#   4. apt 装的 pip 不能自我升级（no RECORD file）→ 删掉 --upgrade pip
#   5. LIB 在 NDK 下载前就算 → set -e 下命令替换失败会静默退出 → 移到 NDK 之后并加 || true
#   6. 容器没挂 /system，Termux 的 clang 无法执行 → nx.sh 增加 /system /apex /vendor 挂载
#      另外包装脚本的 clang/clang++ 写反过一次 → 写完做内容校验
# 本文件现在是"手维护"的：apply_patches.sh 不再内嵌生成它，避免重跑把外部修改覆盖掉。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="/data/data/com.termux/files/usr"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$PREFIX" ] || die "这个脚本要在 Termux 里跑（找不到 $PREFIX）"

step "1/5 更新 Termux 并安装基础包"
pkg update -y
pkg upgrade -y || true
pkg install -y proot-distro clang lld llvm binutils git curl || die "pkg install 失败"
pkg install -y shaderc || info "shaderc 装不上，后面会检查 \$PREFIX/bin/glslc"

step "2/5 存储权限"
termux-setup-storage || true
[ -d /sdcard ] || info "还没拿到存储权限（弹窗里点允许）。只影响把 APK 拷出去，不影响构建。"

step "3/5 安装 / 修复 Ubuntu 容器"
# 先看是否已注册；没有就装（新版 proot-distro 只认 ubuntu:24.04）
if ! proot-distro list 2>/dev/null | grep -q 'ubuntu'; then
    proot-distro install ubuntu 2>/dev/null \
        || proot-distro install ubuntu:24.04 2>/dev/null \
        || true
fi
# 用 login 探测真实可用性：注册信息残留 / rootfs 被删时会失败
if ! proot-distro login ubuntu -- true >/dev/null 2>&1; then
    info "容器不可用（注册残留或 rootfs 缺失），执行 reset"
    proot-distro reset ubuntu || die "proot-distro reset ubuntu 失败"
fi
proot-distro login ubuntu -- true >/dev/null 2>&1 || die "Ubuntu 容器仍然不可用，请贴出 proot-distro list 的输出"
info "容器可用"

step "4/5 写入 ~/nx.sh（必须挂 /system，否则 Termux 的 clang 在容器里跑不起来）"
cat > "$HOME/nx.sh" <<'EOS_NX'
#!/data/data/com.termux/files/usr/bin/bash
exec proot-distro login ubuntu \
  --bind /sdcard:/sdcard \
  --bind /data/data/com.termux/files/usr:/data/data/com.termux/files/usr \
  --bind /system:/system \
  --bind /apex:/apex \
  --bind /vendor:/vendor \
  --bind /data/data/com.termux/files/home:/termux/home \
  -- "$@"
EOS_NX
chmod +x "$HOME/nx.sh"

"$HOME/nx.sh" bash -c '. /etc/os-release; echo "  Ubuntu $VERSION_ID ($VERSION_CODENAME)"'
"$HOME/nx.sh" test -x "$PREFIX/bin/clang" || die "proot 里看不到 Termux 的 clang（nx.sh 的 bind 有问题）"
"$HOME/nx.sh" "$PREFIX/bin/clang" --version | head -1 || die "Termux 的 clang 在容器里无法执行（缺 /system 挂载）"

step "5/5 把仓库与 setup-env.sh 放进 Ubuntu"
# 用 bind 进来的 Termux home 复制，不依赖 rootfs 的实际路径
"$HOME/nx.sh" bash -c "rm -rf /root/nxdiva2Androidtermux; cp -a /termux/home/$(basename "$REPO") /root/"

# Termux 的根目录是只读的、没有 /tmp；临时文件用 $TMPDIR（=$PREFIX/tmp），回退到 $HOME
TMPF="${TMPDIR:-$HOME}/setup-env.sh"
cat > "$TMPF" <<'EOS_ENV'
#!/bin/bash
# 阶段 1-4（指南第 2-5 节）：Ubuntu 依赖 / .NET 10 / NDK r27c / 用 Termux clang 顶替 NDK clang。
# 在 Ubuntu 里执行：  bash /root/setup-env.sh
set -euo pipefail

P=/data/data/com.termux/files/usr            # Termux 的 clang 通过 nx.sh 的 bind 挂在这里
TC=/root/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$P/bin/clang" ] || die "看不到 Termux 的 clang（$P/bin/clang）。用 ~/nx.sh 进 Ubuntu 了吗？"

step "1/4 Ubuntu 依赖"
export DEBIAN_FRONTEND=noninteractive
apt update
# libicu-dev 会拉取对应版本的运行时；不要写死 libicu74（Ubuntu 26.04 没有）
apt install -y python3 python3-pip python3-venv git curl unzip xz-utils ca-certificates file adb libicu-dev
# 不要 pip --upgrade：apt 装的 pip 没有 RECORD 文件，升级必然失败
pip3 install --break-system-packages lz4 capstone pillow fonttools pyyaml pycryptodome
# Python >= 3.14 自带 compression.zstd，backports.zstd 装不上是正常的
pip3 install --break-system-packages backports.zstd || info "backports.zstd 装不上（Python >= 3.14 已内置 zstd，忽略）"

step "2/4 .NET SDK 10"
if [ ! -x /root/dotnet/dotnet ]; then
    curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/di.sh
    bash /tmp/di.sh --channel 10.0 --install-dir /root/dotnet
fi
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
# 必须在 NDK 就位之后再算 LIB：NDK 不存在时命令替换失败，set -e 会静默退出
LIB=$(ls -d "$TC"/lib/clang/*/lib/linux/aarch64 2>/dev/null | tail -1 || true)
[ -n "$LIB" ] || die "找不到 $TC/lib/clang/*/lib/linux/aarch64（NDK 里没有 aarch64 目录？）"
[ -f "$LIB/libunwind.a" ] || die "找不到 $LIB/libunwind.a"
[ -f "$LIB/libclang_rt.builtins-aarch64-android.a" ] || die "找不到 $LIB/libclang_rt.builtins-aarch64-android.a"

[ -e "$TC/bin/clang.real" ]   || mv "$TC/bin/clang"   "$TC/bin/clang.real"
[ -e "$TC/bin/clang++.real" ] || mv "$TC/bin/clang++" "$TC/bin/clang++.real"

printf '#!/bin/sh\nexec %s/bin/clang --sysroot=%s/sysroot -L%s "$@"\n'   "$P" "$TC" "$LIB" > "$TC/bin/clang.new"
printf '#!/bin/sh\nexec %s/bin/clang++ --sysroot=%s/sysroot -L%s "$@"\n' "$P" "$TC" "$LIB" > "$TC/bin/clang++.new"
mv "$TC/bin/clang.new"   "$TC/bin/clang"
mv "$TC/bin/clang++.new" "$TC/bin/clang++"
chmod +x "$TC/bin/clang" "$TC/bin/clang++"

# 校验：clang 必须指向 clang，clang++ 指向 clang++（曾经写反过）
grep -q '/bin/clang '   "$TC/bin/clang"   || die "clang 包装脚本内容不对：$(cat "$TC/bin/clang")"
grep -q '/bin/clang++ ' "$TC/bin/clang++" || die "clang++ 包装脚本内容不对：$(cat "$TC/bin/clang++")"

ln -sf "$P/bin/llvm-strip" "$TC/bin/llvm-strip"
mkdir -p /root/android-ndk-r27c/shader-tools/linux-x86_64
[ -x "$P/bin/glslc" ] || die "缺 Termux 的 glslc：回 Termux 执行 pkg install -y shaderc"
ln -sf "$P/bin/glslc" /root/android-ndk-r27c/shader-tools/linux-x86_64/glslc

echo 'int main(void){return 0;}' > /tmp/t.c
"$TC/bin/clang" --target=aarch64-linux-android31 -c /tmp/t.c -o /tmp/t.o
file /tmp/t.o | grep -q 'ARM aarch64' || die "clang 没在编 aarch64：$(file /tmp/t.o)"
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

"$HOME/nx.sh" bash -c 'cat > /root/setup-env.sh' < "$TMPF"
"$HOME/nx.sh" bash -c 'chmod +x /root/setup-env.sh; wc -l /root/setup-env.sh'

printf '\n\033[1mTermux 侧就绪。\033[0m 下一步：\n'
printf '  ~/nx.sh bash /root/setup-env.sh\n'
printf '\n\033[1m改动同步：\033[0m 在 Termux 里 git pull 或改完代码后，执行\n'
printf '  bash termux/sync.sh\n'
printf '即可把仓库重新同步进 Ubuntu（setup.sh 是复制不是挂载，不会自动同步）。\n'
