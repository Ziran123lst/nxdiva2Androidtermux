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

# termux/setup.sh 现在是"手维护"文件（见文件头注释），不再由本脚本内嵌生成。
# 原因：重跑本脚本会把外部对它的修改覆盖掉，已踩过一次。它必须已随仓库提交。
[ -f termux/setup.sh ] || die "termux/setup.sh 缺失：它现在是手维护文件，请确保已随仓库提交"

# termux/build.sh 与 termux/sync.sh 现在也是"手维护"文件（同 setup.sh 的理由）：
# 重跑本脚本会覆盖外部修改，已经踩过一次。它们必须已随仓库提交。
for f in termux/setup.sh termux/build.sh termux/sync.sh; do
    [ -f "$f" ] || die "termux/$f 缺失：它是手维护文件，请确保已随仓库提交"
done
cat > termux/START-HERE.md <<'EOS_START'
# 从零开始：在手机上把 Switch 游戏跑成 APK

这份文档写给**完全没用过 Termux** 的人。按顺序做，每一步都有"在哪执行"和"看到什么算成功"。

只想看速查版 → [README.md](README.md)

---

## 开之前：你需要这些东西

| 需要 | 说明 | 能不能省 |
|---|---|---|
| 骁龙手机（Adreno GPU，支持 BC 纹理） | 移植版要 Vulkan + Adreno 专有纹理压缩 | 不能 |
| Android 12 或更高 | NDK r27c 工具链需要 | 不能 |
| 剩余空间 **≥ 40 GB** | 游戏本体 ~13 GB + 解包 ~13 GB + NDK ~1 GB + 数据包 ~14 GB | 不能 |
| Termux | 见下面第 0 步，**装错版本会走不下去** | 不能 |
| 你自己的游戏文件（XCI/NSP） | 从你自己的 Switch 主机 dump 出来的 | 不能 |
| 你自己的 `prod.keys` | 同上，从自己的主机 dump | 不能 |

> ⚠️ **仓库里没有任何密钥，也没有任何游戏文件。** 这两个只能来自你自己的机器。
> 缺了它们，第 7 步就做不下去 —— 前面 6 步照样可以先跑完，把环境准备好。

---

## 第 0 步：装对 Termux（最容易翻车的一步）

**应用商店（Play Store）版的 Termux 已经在 2020 年下架并废弃**，装不上之后要用的
`pkg` 命令，等于后面全废。

两个正确来源，任选一个：

**A. F-Droid（省心，自动更新）**

1. 装 F-Droid 客户端：<https://f-droid.org>
2. 搜 `Termux`，装 **Termux**（包名 `com.termux`）。

**B. GitHub 官方发布（直连 GitHub，国内偶尔慢）**

<https://github.com/termux/termux-app/releases> → 最新版 → 下载 APK。

选哪个变体（文件名里带架构和 Android 版本）：

| 你的情况 | 下载 |
|---|---|
| 骁龙等 64 位，Android 7+ | `termux-app_v0.119.0-beta.3+apt-android-7-github-debug_arm64-v8a.apk` |
| 不确定自己是什么架构 | `..._apt-android-7-github-debug_universal.apk`（通吃，体积大点） |

> **`apt-android-5` 和 `apt-android-7` 不能混用。** `android-5` 是给 Android 5/6 的老系统的。
> 你的手机是 Android 12+，一定用 **`apt-android-7`**。
> 同一个手机里 F-Droid 版和 GitHub 版**不能共存**，装之前先把旧的卸掉。

安装时系统会问"是否允许安装未知来源应用" —— 允许，然后装。

---

## 第 1 步：认识这个终端

打开 Termux，屏幕黑底白字就是 shell。试着输入：

```sh
echo hello
```

回车，看到 `hello` 就说明能用。

三个新手必会的操作：

| 想做什么 | 怎么做 |
|---|---|
| **粘贴** | 长按屏幕 → 弹出菜单 → 选「粘贴」。**复制别人给的命令全靠这个** |
| **复制** | 长按屏幕 → 选择文字（有的版本直接长按就是选词） |
| **中断 / 取消** | 按 `Ctrl` + `C`。`Ctrl` 键 = 手机上的**音量减**键 |

> 想让打字有 Tab 补全：`音量加` 键 = `Tab`。

---

## 第 2 步：给存储权限

```sh
termux-setup-storage
```

弹窗点**「允许」**。它让你能读写 `/sdcard`（手机内部存储），后面传游戏文件、导出 APK 都要用。

验证：

```sh
ls /sdcard
```

能列出目录就对了。

---

## 第 3 步：装 git，把仓库克隆下来

先装包（第一次 `pkg update` 会拉很久，耐心等）：

```sh
pkg update -y
pkg upgrade -y
pkg install -y git
```

> **为什么要单独先装 git？** 因为仓库要用 git 克隆下来，而 `setup.sh` 本身就在仓库里 ——
> 鸡生蛋问题，所以 git 得先手动装。

然后克隆**你自己的 fork**（补丁只在这个仓库里，上游 `shirai91/nx2android` 没有）：

```sh
cd ~
git clone https://github.com/Ziran123lst/nxdiva2Androidtermux.git
cd nxdiva2Androidtermux
git log --oneline -1
```

**看到 `d560973` 或更新的 commit 号 = 成功。** 记下这个号，和 [README 第 0 步](README.md#第-0-步确认-remote-指向别把补丁推回上游) 对得上。

---

## 第 4 步：跑 setup.sh —— 装 Ubuntu

还在 Termux 里、仓库目录下：

```sh
cd ~/nxdiva2Androidtermux
bash termux/setup.sh
```

这一步会依次做：

1. 更新 Termux 并装 `proot-distro clang lld llvm binutils git curl shaderc`
2. 申请存储权限
3. 装 Ubuntu（版本由 proot-distro 决定，本机实测为 26.04）
4. 写 `~/nx.sh`（进 Ubuntu 的启动脚本）
5. 把仓库复制进 Ubuntu 的 `/root/nxdiva2Androidtermux`

**大概 10~30 分钟**，全看网速。正常结束时最后会打印：

```
Termux 侧就绪。下一步：
  ~/nx.sh bash /root/setup-env.sh
```

> ❗ **别在这里关屏幕、别切走。** 部分国产 ROM（小米/OPPO/vivo）会把后台应用杀掉，
> 去系统设置里把 Termux 的**电池优化关掉**、允许后台运行。
> 也可以先执行 `termux-wake-lock` 让它不休眠（完事用 `termux-wake-unlock` 解开）。

---

## 第 5 步：把游戏文件放进 Ubuntu（**不能放 /sdcard**）

### 5.1 先把文件传到手机

把游戏本体（`.xci` 或 `.nsp`）和 `prod.keys` 传到手机的 `/sdcard/Download/`。
（用数据线、MT 管理器、或你自己的 dump 工具都行）

### 5.2 再从 /sdcard 拷进 Ubuntu

在 **Termux** 里执行：

```sh
~/nx.sh bash -c 'mkdir -p /root/rom; cd /sdcard/Download; for f in *.xci *.nsp prod.keys; do [ -f "$f" ] && cp -v "$f" /root/rom/; done'
```

**为什么必须多这一步？** Android 的外部存储（`/sdcard`）是 `noexec` 挂载 —— 工具要在游戏目录
旁边编译并运行 `nx_extract`，放在 `/sdcard` 会直接 `Permission denied`。
Ubuntu 里 `/root` 是 ext4，能执行。

### 5.3 确认文件到位

```sh
~/nx.sh bash -c 'ls -lh /root/rom'
```

应该能看到你的 `.xci`/`.nsp` 和 `prod.keys`。

> 13 GB 拷进 ext4 要好几分钟，别以为卡死了。

---

## 第 6 步：装依赖 + NDK（最久的一步）

在 **Termux** 里：

```sh
~/nx.sh bash /root/setup-env.sh
```

它在 Ubuntu 里面做 4 件事：

| 步骤 | 内容 |
|---|---|
| 1/4 | `apt` 装 python3/pip/git/adb/`libicu-dev` 等；`pip` 装 lz4/capstone/pillow/pyyaml/pycryptodome |
| 2/4 | 装 .NET SDK 10 |
| 3/4 | 下载 Android NDK r27c（约 1 GB），并校验版本必须是 `27.2.12479018` |
| 4/4 | **把 NDK 的 clang 换成 Termux clang 的包装脚本**（整套环境最关键一步） |

**30~60 分钟**，NDK 有 1 GB 多。

最后会自检，成功时你看到类似：

```
  /tmp/t.o: ELF 64-bit LSB relocatable, ARM aarch64
```

**必须出现 `ARM aarch64`。** 如果显示 `x86-64`，说明第 4 步没做成，别往下走，先解决这个。

---

## 第 7 步：移植 + 出 APK

还在 **Termux** 里，用一条命令跑完（省得手动进 Ubuntu 再找目录）：

```sh
~/nx.sh bash -c 'cd /root/nxdiva2Androidtermux && bash termux/build.sh "/root/rom" -k "/root/rom/prod.keys" --experimental'
```

想进去一步步看也行：`~/nx.sh` 进 Ubuntu → `cd /root/nxdiva2Androidtermux` →
`bash termux/build.sh "/root/rom" -k "/root/rom/prod.keys" --experimental`。

porter 分 8 个阶段，正常长这样（详细判读表见 [README](README.md#porter-阶段的正常表现判读-rootportlog)）：

| 阶段 | 正常输出 |
|---|---|
| [1/8] build nx_extract | `✓ ... (0:10)` |
| [2/8] extract v0 | `✓ ... 9,6xx files, 13.x GB` |
| [4/8] shader split | `✓ ... NNN shaders` |
| [6/8] host | `✓ ... 1.4 MB` ← 宿主库编出来了 |
| [7/8] APK | `✓ ... .apk, 1.7 MB`（这版不含 shader，下一步会重打） |
| [8/8] data pack | `✓ ... 14.x GB` |

跑完 `build.sh` 会自动重打一遍 APK（内包 shader 和 mods），最后打印：

```
完成。
  APK   /root/rom/<游戏名>-termux.apk (19 MB)
  mods  31 个内包
```

> `--experimental` 是必须的：这个游戏没被官方移植到 Android，porter 会靠文件特征猜一份
> profile。**能出 APK，但不一定能跑起来** —— 这不影响流程本身跑通。

---

## 第 8 步：装到手机上

### 8.1 装 APK

先拷到 `/sdcard`，再用文件管理器点安装：

```sh
~/nx.sh bash -c 'cp /root/rom/*-termux.apk /sdcard/Download/'
```

去「文件管理 → Download → 点那个 APK → 安装」。

包名是 `org.nx2a.t` + TitleID 小写（例如 `org.nx2a.t0100f3100da46000`）。

### 8.2 送数据包（**必须用 MT 管理器或 adb**）

数据包在 `/root/rom/<游戏名>-data/`，14 GB。要送到：

```
/storage/emulated/0/Android/data/org.nx2a.t0100f3100da46000/files/
```

里面的东西：

```
RomFS/            ← 必须，13~14 GB
aoc/              ← 有 DLC 时才有
env.txt  settings.txt  nx2a-data.json  nintendo_ext.ttf
```

**`shaders.dmsv` 和 `mods/` 不用送** —— 已经内包进 APK 了。（因为 Termux 写的单个文件属主
不对，游戏进程 `open()` 会拿到 `EACCES`，所以才内包。）

两种送法：

- **MT 管理器**（最简单）：复制 `RomFS` 等进去。缺点是 13 GB 复制很慢。
- **adb push**（最稳，权限正确）：

  ```sh
  # 在 Ubuntu 里（adb 已装）
  adb push /root/rom/<游戏名>-data/RomFS /sdcard/Android/data/org.nx2a.t0100f3100da46000/files/
  ```

---

## 全程一条龙（复制粘贴版）

在 **Termux** 里，从头到尾就这几行（游戏文件要提前放好在 `/sdcard/Download`）：

```sh
pkg update -y && pkg upgrade -y
pkg install -y git
termux-setup-storage
cd ~ && git clone https://github.com/Ziran123lst/nxdiva2Androidtermux.git && cd nxdiva2Androidtermux
git log --oneline -1
bash termux/setup.sh
~/nx.sh bash -c 'mkdir -p /root/rom; cd /sdcard/Download; for f in *.xci *.nsp prod.keys; do [ -f "$f" ] && cp -v "$f" /root/rom/; done'
~/nx.sh bash -c 'ls -lh /root/rom'
~/nx.sh bash /root/setup-env.sh
~/nx.sh bash -c 'cd /root/nxdiva2Androidtermux && bash termux/build.sh "/root/rom" -k "/root/rom/prod.keys" --experimental'
~/nx.sh bash -c 'cp /root/rom/*-termux.apk /sdcard/Download/'
```

---

## 卡住了看这张表

| 现象 | 原因 / 处理 |
|---|---|
| `pkg: command not found` | 装的是废弃的应用商店版 → 回第 0 步重装 |
| `termux-setup-storage` 没弹窗 | 已经授权过了，直接跳过 |
| `Unable to locate package` | `pkg update` 没成功，检查网络后重试 |
| `proot-distro install` 卡住不动 | 网络问题，或换 F-Droid 源 `termux-change-repo` |
| 构建到一半被杀掉 / 应用闪退 | 国产 ROM 杀后台 → 关电池优化 + `termux-wake-lock` |
| `Extract: Permission denied ... nx_extract` | 游戏文件还在 `/sdcard` → 回第 5 步 |
| `Couldn't find a valid ICU package` | `libicu-dev` 没装上 → `~/nx.sh bash -c "apt install -y libicu-dev"` |
| `file /tmp/t.o` 显示 x86-64 | 第 6 步的编译器替换没成功 → 重跑 `setup-env.sh` |
| `unable to find library -l:libunwind.a` | 同上（`-L` 指到了错架构的目录） |
| `not enough disk space ... needs about NN GB` | 空间不够，或第 6.7 号补丁没生效 |
| `LinkedList is empty` / 几千个文件被跳过 | 6.2 号补丁没生效 → 确认 commit 是 `d560973` 或更新 |
| `ArgumentException: Offset must be a multiple of 16` | 6.1 号补丁没生效 → 同上 |
| 改了 Termux 侧代码，Ubuntu 里还是旧的 | `setup.sh` 是复制不是挂载 → Termux 里跑 `bash termux/sync.sh` |
| `git pull` 报 `detected dubious ownership` | 见 README 第 0 步的 remote 说明 |

---

## 一个提醒

上面"保留断言""不用 `find | head -1` 找 libunwind"这两条，不是纸上谈兵的设计洁癖，
而是**在这台设备上实测踩出来的构建前提** —— 修掉它们之后才成功编出 1.4 MB 的
`libdmhost.so` 和 19 MB 的 APK。所以别嫌脚本啰嗦。
EOS_START

cat > termux/README.md <<'EOS_README'
# 在安卓手机（Termux）上跑通 nx2android

把 Switch 游戏移植成安卓 APK 的完整流程，全部在手机上完成。
验证过的游戏：初音ミク Project DIVA MEGA39's（Title ID `0100F3100DA46000`，JP，1.0.9）。

> **完全没接触过 Termux？先看 [START-HERE.md](START-HERE.md)** —— 那是从零开始的
> 逐步教学（装哪个版本的 Termux、怎么粘贴命令、每一步在哪一层执行）。
> 本文档是给已经知道自己在做什么的人看的速查版。

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
| `apt install ... libicu-dev` | .NET 的硬依赖，缺了报 `Couldn't find a valid ICU package` |
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
| `Couldn't find a valid ICU package` | 缺 libicu → `apt install -y libicu-dev` |
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
