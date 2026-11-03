#!/usr/bin/env bash
# apply_patches.sh -- nx2android 的 7 个补丁 + termux/ 三件套
#
# 在仓库根目录执行：  bash apply_patches.sh
#
# 设计原则（重要）：
#   1. 每个补丁都是“精确字符串替换 + 断言”。替换前先数锚点出现次数，不是 1 次就
#      立即中止并打印原因。上游一旦改了被替换的源码文本，这里会失败 —— 这是预期
#      行为，请人工核对新的源码后再改锚点，不要删掉断言改成盲替换。
#   2. 脚本是幂等的：已经打过的补丁会被识别为“已应用”并跳过，重复执行不会把代码
#      改两遍。
#   3. 补丁只做指南第 6 节列出的 7 件事，不多改一行。
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

for f in nxnative/dm/tools/nx_extract/Program.cs nxnative/dm/host/hle_audio.c \
         nxnative/dm/android/gfx_vk_shader.c nxnative/dm/android/front_android.c \
         nxnative/dm/host/hle_sf.c porter/pipeline.py; do
    [ -f "$f" ] || die "不是 nx2android 仓库根目录：缺 $f"
done

say "== 1/2 应用 7 个补丁 =="

python3 - <<'PYEOF'
import pathlib, sys

def fail(msg):
    print('\033[31m[FAIL]\033[0m ' + msg, file=sys.stderr)
    print('上游源码可能已改动。正确处置（不要删断言改成盲替换，也不要只停在报错）：', file=sys.stderr)
    print('  1) git fetch upstream', file=sys.stderr)
    print('  2) git diff upstream/main -- <被改的文件>   # 看上游到底改了哪一段', file=sys.stderr)
    print('  3) 把本脚本里对应的 OLD_xx 字符串更新成当前上游文本（保留断言），然后重跑 apply_patches.sh', file=sys.stderr)
    print('直接把断言删掉改成 replace(old, new) 无脑替换，会在大版本变动时静默破坏源码，比报错更危险。', file=sys.stderr)
    sys.exit(1)

def sub(path, old, new, name):
    """把 old 精确替换成 new。幂等：已应用则跳过；锚点异常则中止。
    每个补丁的 new 都含唯一新增片段，所以 new 出现在文件里即视为已生效。
    注意：上游一旦改了被替换的源码文本，old 不再恰好出现 1 次，这里会 fail
    并中止 —— 这是预期行为，请人工核对新源码后再改锚点，不要删断言盲替换。"""
    p = pathlib.Path(path)
    if not p.is_file():
        fail(f'{name}: 找不到文件 {path}')
    s = p.read_text(encoding='utf-8')
    if new in s:                      # 已应用（new 含唯一新增内容），跳过
        print(f'  {name}: ok（已经打过，跳过）')
        return
    n = s.count(old)
    if n != 1:
        fail(f'{name}: 锚点在 {path} 里出现了 {n} 次（应为 1 次），上游很可能改了这段源码。\n'
             f'        锚点首行：{old.splitlines()[0][:110]}')
    p.write_text(s.replace(old, new, 1), encoding='utf-8')
    print(f'  {name}: ok')

# ---- 6.1 nx_extract/Program.cs：XCI 内含 update -----------------------------
OLD_61 = '        Nca updProg = updPkg == null ? null : Pick(updPkg, NcaContentType.Program, baseProg.Header.TitleId) ?? throw new Exception("no Program NCA of the base game\'s program in the update NSP");\n'
NEW_61 = OLD_61 + '''        // 同一个 XCI 里的第二个 Program NCA 当作 update
        if (updProg == null)
        {
            var more = basePkg.FindAll(n => n.Header.ContentType == NcaContentType.Program && n.Header.TitleId == baseProg.Header.TitleId && !ReferenceEquals(n, baseProg));
            if (more.Count > 0) { updProg = more[more.Count - 1]; Console.WriteLine("[nca] a second Program NCA in the same image: treated as the update"); }
        }
'''
sub('nxnative/dm/tools/nx_extract/Program.cs', OLD_61, NEW_61,
    '6.1 第二个 Program NCA 当 update')

# ---- 6.2 nx_extract/Program.cs：读坏块不中断 --------------------------------
OLD_62 = '''            }
            written += e.Size;
'''
NEW_62 = '''            }
            catch (Exception x) when (x is InvalidOperationException || x is IOException)
            {
                try {
                    if (g_lenient != null) {
                        g_lenientFs ??= g_lenient();
                        using var lf = new UniqueRef<IFile>();
                        g_lenientFs.OpenFile(ref lf.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                        Write(lf.Get, op, e.Size, buf);
                        continue;
                    }
                } catch (Exception y) { Console.WriteLine("[RED] lenient read failed, skipped: " + e.FullPath + " (" + y.Message + ")"); }
                Console.WriteLine("[RED] read failed, skipped: " + e.FullPath + " (" + x.Message + ")");
                if (File.Exists(op)) File.Delete(op);
                continue;
            }
            written += e.Size;
'''
sub('nxnative/dm/tools/nx_extract/Program.cs', OLD_62, NEW_62,
    '6.2 坏块只跳过该文件')

# ---- 6.3 hle_audio.c：认领游戏自建的 AudioOut -------------------------------
OLD_63 = 'static aout *ao(const void *g) { aout *a = objmap_get(g); if (!a) die("AudioOut %p was not created by the host", g); return a; }'
NEW_63 = '''static Result au_open_at(void *g, void *ev, const char *name, const uint8_t *param, void *lr);
static aout *ao(const void *g) {
    aout *a = objmap_get(g);
    if (!a) {
        static const uint8_t def[8] = {0,0,0,0,2,0,0,0};
        LOG("[RED] audio: AudioOut %p was made by the game itself; opening a host output for it", g);
        au_open_at((void *)g, NULL, "game-made", def, NULL);
        a = objmap_get(g);
        if (!a) die("AudioOut %p could not be created", g);
    }
    return a;
}'''
sub('nxnative/dm/host/hle_audio.c', OLD_63, NEW_63,
    '6.3 游戏自建 AudioOut')

# ---- 6.4 gfx_vk_shader.c：shader 包从 APK assets 读 -------------------------
sub('nxnative/dm/android/gfx_vk_shader.c',
    '#include "gfx_vk.h"',
    '#include <android/asset_manager.h>\n#include "gfx_vk.h"',
    '6.4a asset_manager.h')

sub('nxnative/dm/android/gfx_vk_shader.c',
    '#include <fcntl.h>',
    '#include <errno.h>\n#include <fcntl.h>',
    '6.4b errno.h')

OLD_64c = 'void vk_shaders_open(const char *path) {'
NEW_64c = '''AAssetManager *dm_front_assets(void);
static int bundle_from_assets(const char *why) {
    AAssetManager *am = dm_front_assets(); if (!am) return 0;
    AAsset *a = AAssetManager_open(am, "shaders.dmsv", AASSET_MODE_BUFFER); if (!a) return 0;
    off_t n = AAsset_getLength(a); uint8_t *p = malloc((size_t)n);
    if (!p || AAsset_read(a, p, (size_t)n) != n) { free(p); AAsset_close(a); return 0; }
    AAsset_close(a);
    if (memcmp(p, "DMSV", 4)) { VKLOG("[RED] the APK's shaders.dmsv is not a shader bundle"); free(p); return 0; }
    g_bundle = p; memcpy(&g_nent, g_bundle + 8, 4); g_ent = (const bent *)(g_bundle + 12);
    VKLOG("shader bundle from the APK assets (%s): %u shaders, %.1f MB", why, g_nent, n / 1048576.0);
    return 1;
}
void vk_shaders_open(const char *path) {'''
sub('nxnative/dm/android/gfx_vk_shader.c', OLD_64c, NEW_64c,
    '6.4c bundle_from_assets')

OLD_64d = '    if (fd < 0 || fstat(fd, &st)) { VKLOG("[RED] no shader bundle at %s: nothing will be drawn", path); if (fd >= 0) close(fd); return; }'
NEW_64d = '    if (fd < 0 || fstat(fd, &st)) { VKLOG("[RED] no shader bundle at %s (errno=%d %s), trying the APK\'s assets", path, errno, strerror(errno)); if (fd >= 0) close(fd); bundle_from_assets("the file was not readable"); return; }'
sub('nxnative/dm/android/gfx_vk_shader.c', OLD_64d, NEW_64d,
    '6.4d 打开失败转 assets')

# ---- 6.5 front_android.c：mods 从 APK assets 解包 ---------------------------
OLD_65a = 'static void *host_thread(void *a) {'
NEW_65a = '''static int copy_mods_from_assets(const char *dst) {
    AAssetManager *am = dm_front_assets(); if (!am) return 0;
    AAssetDir *dir = AAssetManager_openDir(am, "mods"); if (!dir) return 0;
    mkdir(dst, 0700);
    const char *name; int n = 0;
    while ((name = AAssetDir_getNextFileName(dir))) {
        char an[600], p[700];
        snprintf(an, sizeof an, "mods/%s", name);
        AAsset *a = AAssetManager_open(am, an, AASSET_MODE_BUFFER);
        if (!a) continue;
        snprintf(p, sizeof p, "%s/%s", dst, name);
        FILE *f = fopen(p, "wb");
        if (f) { char buf[65536]; int k; while ((k = AAsset_read(a, buf, sizeof buf)) > 0) fwrite(buf, 1, (size_t)k, f); fclose(f); n++; }
        AAsset_close(a);
    }
    AAssetDir_close(dir);
    LOG("[mods] %d files copied from the APK assets to %s", n, dst);
    return n;
}
static void *host_thread(void *a) {'''
sub('nxnative/dm/android/front_android.c', OLD_65a, NEW_65a,
    '6.5a copy_mods_from_assets')

OLD_65b = '    char mods[600]; snprintf(mods, sizeof mods, "%s/mods", g_root);'
NEW_65b = '''    char mods[600]; snprintf(mods, sizeof mods, "%s/mods-internal", g_act->internalDataPath);
    if (copy_mods_from_assets(mods) <= 0) snprintf(mods, sizeof mods, "%s/mods", g_root);'''
sub('nxnative/dm/android/front_android.c', OLD_65b, NEW_65b,
    '6.5b mods 目录改到私有目录')

# ---- 6.6 hle_sf.c：放行 audout:u -------------------------------------------
sub('nxnative/dm/host/hle_sf.c',
    'static const char *const sf_served[] = {"olsc:u"};',
    'static const char *const sf_served[] = {"olsc:u", "audout:u"};',
    '6.6 放行 audout:u')

# ---- 6.7 pipeline.py：磁盘检查放宽为警告 ------------------------------------
OLD_67 = "        if free < need: raise BuildError(f'not enough disk space on {self.o.folder.anchor}: the port needs about {need / 2**30:.1f} GB more, {free / 2**30:.1f} GB is free')"
NEW_67 = "        if free < need: print(f'[RED] disk space low (need {need / 2**30:.1f} GB, free {free / 2**30:.1f} GB): going on anyway')"
sub('porter/pipeline.py', OLD_67, NEW_67,
    '6.7 磁盘检查放宽')
PYEOF

say "== 2/2 写出 termux/ 脚本 =="
mkdir -p termux

cat > termux/setup.sh <<'EOS_SETUP'
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
info "已复制 $REPO -> $ROOTFS/root/nxdiva2Androidtermux"
info "以后改了 Termux 侧仓库，跑 bash termux/sync.sh 重新同步（不用重跑整个 setup.sh）"

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
printf '\n\033[1m改动同步：\033[0m 在 Termux 里 git pull 或改完代码后，执行\n'
printf '  bash termux/sync.sh\n'
printf '即可把仓库重新同步进 Ubuntu（setup.sh 是 cp -a 复制，不会自动同步）。\n'
EOS_SETUP

cat > termux/build.sh <<'EOS_BUILD'
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
EOS_BUILD

cat > termux/sync.sh <<'EOS_SYNC'
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
EOS_SYNC

cat > termux/README.md <<'EOS_README'
# 在安卓手机（Termux）上跑通 nx2android

把 Switch 游戏移植成安卓 APK 的完整流程，全部在手机上完成。
验证过的游戏：初音ミク Project DIVA MEGA39's（Title ID `0100F3100DA46000`，JP，1.0.9）。

**前置条件**

- 骁龙（Adreno，需支持 BC 纹理）、Android 12+、剩余空间 ≥ 40 GB
- F-Droid 版 Termux（应用商店版已废弃）：`https://f-droid.org/packages/com.termux/`
- 用户自己的 `prod.keys` 与游戏 dump。**仓库里没有任何密钥和游戏文件。**

---

## 第 0 步：确认 remote 指向（别把补丁推回上游）

本仓库是 **fork**：`Ziran123lst/nxdiva2Androidtermux`；上游是 `shirai91/nx2android`。
**补丁只存在于你的 fork**，上游没有。

```sh
cd ~/nxdiva2Androidtermux && git remote -v
```

| `origin` 指向 | 含义 | 怎么办 |
|---|---|---|
| `Ziran123lst/nxdiva2Androidtermux` | 你的 fork ✅ | 直接 `git pull --ff-only` |
| `shirai91/nx2android` | 上游原作者 ❌ | 改指自己的 fork（见下） |

```sh
# origin 指错上游时：否则 git push origin 会推向原作者的仓库，必然被拒
git remote set-url origin https://github.com/Ziran123lst/nxdiva2Androidtermux.git
git fetch origin && git reset --hard origin/main   # 本地有改动先 git stash
```

拉完自检：

```sh
git log --oneline -1                      # 应是 54eb897 或更新
grep -c profile-derived termux/build.sh   # 应为 1（5 处 bug 修复之一）
```

> `git status -sb` 显示 `ahead 3` 是**正常**的：那 3 个提交（7 补丁 / 3 修正 / 5 修复）
> 本来就只该在你的 fork 里，相对上游 ahead 才对。要看的不是 `ahead`，而是**服务端
> `main` 的 SHA 是否等于你本地的 HEAD**。分支列表里那些 `chore/*` 是从上游继承来的，
> 不是新推送。

---

## 三步走

```sh
# 1) Termux 里：装 Ubuntu、把仓库和环境脚本放进 proot
cd ~/nxdiva2Androidtermux && bash termux/setup.sh

# 2) Ubuntu 里：依赖 / .NET 10 / NDK r27c / 编译器替换
~/nx.sh bash /root/setup-env.sh

# 3) Ubuntu 里：移植 + 重打 APK
cd /root/nxdiva2Androidtermux
bash termux/build.sh "/root/rom" -k "/root/rom/prod.keys" --experimental
```

产物：`/root/rom/<游戏名>-termux.apk`（**19 MB 以上**，含 shader 与 mods）和
`/root/rom/<游戏名>-data/`（数据包，约 14 GB）。

### 本机实测记录

这套配置在设备上**已经跑出产物**，不是推测：

```
[6/8] host (0:30): 1.4 MB          ← libdmhost.so 编出来并链接成功
[7/8] APK: ProjectDivaMEGA39s.apk, 1.7 MB
APK 19~20 MB（内包 shader 后）
mods embedded: 31 / 62
```

判据：`libdmhost.so` 1.4 MB 且链接成功 → APK 含 shader 后 19~20 MB → mods 内包 31/62。
「保留断言」「不用 `find|head`」这两个约束就是照着这次成功的构建定下来的，
属于**已实测验证的构建前提**，不是通用设计约定。

---

## 第 1 步之前：放好游戏文件

游戏文件**必须放在 proot 的 ext4 上（`/root/...`），不能放 `/sdcard`** ——
Android 外部存储是 `noexec`，工具会在游戏目录旁编译并执行 `nx_extract`，放 `/sdcard` 会
`Permission denied`。

```
/root/rom/
  project diva.xci            本体（若该 XCI 内含 update，会自动识别）
  xxx[UPD][1.0.9].nsp         可选：独立更新
  xxx[DLC].nsp                可选：DLC，可多个；会打包成 aoc/
  prod.keys                   必需（自己 dump）
```

---

## 每一步在做什么

### 第 1 步 `termux/setup.sh`

| 动作 | 说明 |
|---|---|
| `pkg install proot-distro clang lld llvm binutils git curl shaderc` | `shaderc` 提供 `glslc`，宿主构建要用 |
| `proot-distro install ubuntu` | 整套流程跑在 glibc 的 Ubuntu 里（.NET 只有 glibc 版，Termux 是 bionic） |
| 写 `~/nx.sh` | 带两个 bind，`--bind /data/data/com.termux/files/usr:...` 是编译器替换的关键 |
| 复制仓库到 `/root/nxdiva2Androidtermux` | 后续两步都在 Ubuntu 里跑 |
| 生成 `/root/setup-env.sh` | 第 2 步的脚本 |

> **仓库是复制进去的，不是挂载的。** `setup.sh` 用 `cp -a` 把仓库拷进 rootfs，
> 之后你在 Termux 侧 `git pull` 或改文件，rootfs 里那份**不会自动更新**。
> 改完代码后执行：
>
> ```sh
> bash termux/sync.sh      # 只重新同步仓库，不重跑 pkg / apt / .NET / NDK
> ```
>
> 没改成 `--bind` 挂载的原因：proot 里以 root 身份写出的文件，回到 Termux 侧属主会变成 root，
> Termux 里的 git 会报 `detected dubious ownership`。`cp -a` + `sync.sh` 没有这个问题。

### 第 2 步 `/root/setup-env.sh`

| 动作 | 说明 |
|---|---|
| `apt install ... libicu74` | .NET 的硬依赖，缺了报 `Couldn't find a valid ICU package` |
| `pip3 install --break-system-packages lz4 capstone pillow fonttools pyyaml pycryptodome` | 不要装 PySide6，命令行功能是全的 |
| `dotnet-install.sh --channel 10.0` | 装到 `/root/dotnet` |
| 下载 NDK r27c | 只认 r27c，会校验 `Pkg.Revision = 27.2.12479018` |
| **把 NDK 的 clang 换成 Termux clang 的包装脚本** | 整套环境最关键的一步，见下 |

**编译器替换**：Google 不提供 aarch64 版 NDK（只有 x86_64 编译器二进制），但
`toolchains/llvm/prebuilt/linux-x86_64/` 里除编译器二进制外都是与架构无关的数据
（sysroot、头文件、aarch64 stub 库）。所以把 `clang`/`clang++` 换成转发到 Termux clang 的
包装脚本，NDK 只当数据用。

包装脚本里的 `-L` 必须指向 **aarch64 的那一份 `.../lib/clang/<ver>/lib/linux/aarch64`**，而不是写死
`clang/18`，也不要用 `find ... | head -1` 去找。`find` 返回顺序里 `i386-unknown-linux-gnu`、
`x86_64-unknown-linux-gnu` 都可能排在 `aarch64` 前面，取第一个会命中错架构，链接时报
`unable to find library -l:libunwind.a`。脚本里按 `aarch64` 前缀 glob（不写死版本号），并对
`libunwind.a` 与 `libclang_rt.builtins-aarch64-android.a` 两个库都做存在性断言。

自检必须出现 `ARM aarch64`。

### 第 3 步 `termux/build.sh`

| 动作 | 说明 |
|---|---|
| `python3 -m porter port "$@"` | 参数原样传给 porter |
| `build.py --game <TitleID> --release --lib` | 改了 C 就必须重编，否则 APK 里还是旧逻辑 |
| `mkapk.py --asset shaders.dmsv=... --asset mods/<name>=...` | shader 与 mods 内包进 APK |

`build.sh` 结束时会断言：`assets/shaders.dmsv` 在包里，且 **APK 不小于 shader 包**
（`MB >= SH_MB - 1`）。判据**不写死 19 MB** —— 那是这台机器的经验值，shader 少的游戏
只有几 MB，写死会误杀。带 mods 会更大（mods 里的 `.patched.bin` 很大，可到 70~80 MB）。

porter 阶段的正常表现（判读 `/root/port.log`）：

| 阶段 | 正常 | 异常 |
|---|---|---|
| `[1/8] build nx_extract` | `✓ ... (0:10)` | .NET 问题 → `dotnet --list-sdks` |
| `[2/8] extract v0` | `✓ ... 9,6xx files, 13.x GB` | `[nca] a second Program NCA` 缺失 → 6.1 没打；`LinkedList is empty` → 6.2 没打 |
| `[4/8] shader split` | `✓ ... NNN shaders`（原版 808） | `found no shaders` → RomFS 里没有 BNSH |
| `[6/8] host` | `✓ ... 1.4 MB` | `unable to find library -l:libunwind.a` → 第 2 步的 `-L` |
| `[7/8] APK` | `✓ ... 1.7 MB` | 这个 APK 不含 shader，第 3 步会重打 |
| `[8/8] data pack` | `✓ ... files, 14.x GB` | |

---

## 装到手机

APK 直接点安装（同签名同包名可覆盖升级，versionCode 必须递增）。

**数据包**不能从 proot 直接写进 `Android/data/<包名>/files/`（Termux 无权限）。用 **MT 管理器**
复制，或 `adb push`（最稳，权限正确）：

```
RomFS/          （必要，13~14 GB）
aoc/            （有 DLC 时）
env.txt  settings.txt  nx2a-data.json  nintendo_ext.ttf
```

`shaders.dmsv` 和 `mods/` **不用拷** —— 已经内包在 APK 里。
（MT 写入的单个文件属主不对，游戏进程 `open()` 会得到 `EACCES`，这就是内包方案的由来。）

---

## 仓库里打了哪些补丁

`apply_patches.sh` 打 7 个补丁，全部是「精确字符串替换 + 断言」：

| # | 文件 | 解决 |
|---|---|---|
| 6.1 | `nxnative/dm/tools/nx_extract/Program.cs` | XCI 内含 update：第二个 Program NCA 当 update |
| 6.2 | 同上 | LibHac 缓存层崩溃后，读失败切 lenient 存储，仍失败只跳过该文件 |
| 6.3 | `nxnative/dm/host/hle_audio.c` | 认领游戏自建的 AudioOut |
| 6.4 | `nxnative/dm/android/gfx_vk_shader.c` | shader 包改从 APK assets 读（`files/shaders.dmsv` 会 EACCES） |
| 6.5 | `nxnative/dm/android/front_android.c` | mods 从 APK assets 解到应用私有目录 |
| 6.6 | `nxnative/dm/host/hle_sf.c` | `sf_served` 放行 `audout:u` |
| 6.7 | `porter/pipeline.py` | 磁盘检查放宽为警告（原来按 2 倍游戏体积估算） |

> **上游一旦改了被替换的源码文本，`apply_patches.sh` 会断言失败并中止。** 这是刻意的：
> 请人工核对新源码后再改锚点，**不要删掉断言改成盲替换**。

> **pchtxt 偏移换算（本机实测结论，非推断）**：本作 `main` 的段文件偏移是 `0x101`，所以
> **pchtxt 文件偏移 = 补丁偏移 + 0x101**（不是 +0x100）。用 +0x100 会在 `DT_INIT` 阶段 `SIGILL`。
> 自己改补丁时务必按 `0x101` 对齐。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `Couldn't find a valid ICU package` | 缺 libicu → `apt install -y libicu74` |
| `git push origin` 被拒 / 推到上游去了 | `origin` 指到了 `shirai91/nx2android` → 见「第 0 步」，改指自己的 fork |
| rootfs 里的代码是旧的 | `setup.sh` 是复制不是挂载 → Termux 里跑 `bash termux/sync.sh` |
| 第二次跑 build.sh，mods 一个都没内包 | 已修：`STEM` 现在从 `*-data` 目录推，不再误选 `-termux.apk` |
| `unable to find library -l:libunwind.a` | 包装脚本 `-L` 指错了架构（写死 `clang/18` 随 NDK 升版失效，或 `find|head` 命中 i386/x86_64）→ 改用 `ls -d "$TC"/lib/clang/*/lib/linux/aarch64` |
| `file /tmp/t.o` 显示 x86-64 | 用了 NDK 原始 clang → 重跑 `/root/setup-env.sh` 的第 4 步 |
| `Extract: Permission denied ... nx_extract` | 游戏文件放在 `/sdcard`（noexec）→ 移到 `/root` |
| `LinkedList is empty` / 4361 个文件被跳过 | 6.2 补丁 |
| `ArgumentException: Offset must be a multiple of 16` | 把补丁型 NCA 当基座 → 6.1 补丁 |
| `not enough disk space ... needs about NN GB` | 6.7 补丁 |
| 启动崩 `FATAL AudioOut ... was not created by the host` | 6.3 补丁 |
| `sf: ... audout:u ... does not serve` | 6.6 补丁 |
| `no shader bundle at .../files/shaders.dmsv (EACCES)` | 6.4 补丁 + 内包 shader |
| `FATAL open .../mods/main.fixups.tsv` | mods 只拷了 .bin 缺 tsv → 6.5 补丁（整目录内包） |
| 黑屏有声音 | 检查日志里 `shader bundle from the APK assets` |
EOS_README

chmod +x termux/setup.sh termux/build.sh termux/sync.sh
say "已写出：termux/setup.sh  termux/build.sh  termux/sync.sh  termux/README.md"

if git rev-parse --git-dir >/dev/null 2>&1; then
    git add -A
    if ! git diff --cached --quiet; then
        git commit -q -m "termux: 7 patches for on-device porting + setup/build scripts

6.1 nx_extract: treat a second Program NCA in the same image as the update
6.2 nx_extract: on a read failure fall back to the lenient storage, else skip the file
6.3 hle_audio: adopt an AudioOut the game made itself
6.4 gfx_vk_shader: read the shader bundle from the APK's assets
6.5 front_android: unpack mods from the APK's assets
6.6 hle_sf: serve audout:u
6.7 pipeline: downgrade the disk-space check to a warning"
        say "已提交：$(git log --oneline -1)"
    else
        info "没有改动可提交"
    fi
fi
say "全部完成"
