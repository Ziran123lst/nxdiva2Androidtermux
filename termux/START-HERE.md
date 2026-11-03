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
