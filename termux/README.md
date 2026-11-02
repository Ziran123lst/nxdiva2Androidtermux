# 在安卓手机（Termux）上跑通 nx2android

把 Switch 游戏移植成安卓 APK 的完整流程，全部在手机上完成。
验证过的游戏：初音ミク Project DIVA MEGA39's（Title ID `0100F3100DA46000`，JP，1.0.9）。

**前置条件**

- 骁龙（Adreno，需支持 BC 纹理）、Android 12+、剩余空间 ≥ 40 GB
- F-Droid 版 Termux（应用商店版已废弃）：`https://f-droid.org/packages/com.termux/`
- 用户自己的 `prod.keys` 与游戏 dump。**仓库里没有任何密钥和游戏文件。**

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

`build.sh` 结束时会断言：APK ≥ 19 MB、且 `assets/shaders.dmsv` 在包里。
带 mods 会更大（mods 里的 `.patched.bin` 很大，可到 70~80 MB）。

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
