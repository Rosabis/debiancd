# 用 GitHub Actions 复刻一张「647 MiB 带桌面的 Debian」

结论先行：**能，但你要复刻的不是"精简版"，而是"填满一张 CD"的官方安装盘**；照抄包名一定会挂，正确姿势是抄「任务/根包」让 apt 在新版本重算闭包。

---

## 1. 先弄清你这张盘到底是什么（本地实测，非猜测）

| 项目 | 实测值 |
|---|---|
| 文件 | `debian-bullseye-DI-alpha1-amd64-xfce-CD-1.iso`，678,428,672 B = **647.0 MiB** |
| 卷标识 | `Debian GNU/Linux bullseye-DI-alpha1 "Bullseye" - Official Snapshot amd64 xfce-CD Binary-1 20191130-23:05` |
| 盘型 | `.disk/cd_type` = `full_cd/single`（单盘全量，不联网也能装完） |
| 归档区 | 只有 `main`（无 contrib / non-free / non-free-firmware） |
| 包数量 | **998 个 deb，510.3 MiB**（解析 `dists/bullseye/main/binary-amd64/Packages`） |
| 解包后占用 | **2.11 GiB**（Installed-Size 合计，压缩比约 4.2×） |
| 安装器 | `install.amd` 73.7 MiB：`initrd.gz` 18.6 + `gtk/initrd.gz` 44.5 + 2×`vmlinuz` 5.3 |
| 内核 / 浏览器 | `linux-image-5.3.0-2-amd64` / `firefox-esr` 45.65 MiB |

三条判读：

1. **它不是"迷你 Debian"，是 debian-cd 生成的官方 xfce-CD-1 快照。** 2019-11-30 的 bullseye（当时还是 testing）单盘镜像，就是「standard 任务 + XFCE 桌面 + 安装器」，刚好塞进一张 CD。647 MiB ≈ 678 MB，基本是卡着 debian-cd 的 700MB 单盘上限做的——**大小是"填满"的结果，不是"裁剪"的结果**。
2. **这类镜像官方现在不发了。** 现查 `cdimage/debian-cd/current/amd64/iso-cd/`，13.8.0 只剩三种 netinst（758 MB），没有任何 `*-CD-1.iso`；桌面要么 netinst 联网装、要么 3.6 GB 的 live 镜像。所以"自己造一张小体积带桌面的盘"这件事**确实有现实价值**。
3. **别拿它当系统用。** bullseye 已经退出 LTS（2026-08 结束），内核 5.3、firefox 68，它的价值只是"体积与组件参照物"。

## 1b. 为什么 13.x 的 netinst 比 bullseye 大那么多？（有官方实锤）

**不是桌面变大了，是固件进官方媒介了。** 2022 年 GR 之后 Debian 允许官方媒介携带 non-free firmware，从 bookworm 起 netinst 开始内置固件；Debian CD 团队的 [Bug#1038440](https://lists.debian.org/debian-cd/2023/06/msg00019.html) 用 `xorriso report_lba` 按 LBA 去重实测了 11.5.0 → 12.0.0：

| 目录 | bullseye 11.5.0 | bookworm 12.0.0 | 增长 |
|---|---:|---:|---:|
| `/firmware` | 0 MiB | 216 MiB | **+216** |
| `/install.amd` | 67 MiB | 138 MiB | +71 |
| `/pool` | 301 MiB | 360 MiB | +59 |

（`/firmware` 与 `/pool/non-free-firmware` 是硬链接，所以 `du` 解包目录会重复计数，必须按 LBA 去重才是真实占用。）

CD 团队在 [2025-08 的邮件](https://www.mail-archive.com/debian-cd@lists.debian.org/msg26410.html)里说得很直白：

> bullseye/firmware.cfg: `FORCE_CD_SIZE1=STICK1GB`
> bookworm/netinst.cfg: `FORCE_CD_SIZE1=STICK1GB` … and indeed the STICK1GB addition for bookworm happened right when we were working on splitting non-free-firmware from non-free.

所以：**官方早就放弃把 netinst 塞进 CD 了**，trixie/forky 继续 STICK1GB。13.x 的卷标也直接写着 "NETINST **with firmware**"。同一位报告者还注意到 ppc64el/riscv64/s390x 的 netinst 小 100+ MB —— 说明 x86 平台庞大的 Wi-Fi/显卡固件集是主要增量，叠加内核与 initrd 的自然膨胀，最后到了 758 MB。

**能不能裁？能，而且比裁桌面盘简单得多。** 固件都在独立目录里，跟 main 归档不交叉：

- `scripts/shrink-netinst.sh` + `.github/workflows/shrink-netinst.yml`：删 `/firmware`、`/pool/non-free-firmware`、`dists/<rel>/non-free-firmware/`，从 `Release` 里摘掉该组件和校验行，改 `.disk/base_components=main`，重算 `md5sum.txt`，再重打包。
- 脚本启动时会用上面那套 `report_lba` 方法打印**你自己下载那版 ISO 的真实体积分解**，跑一次就能看到 13.8 的确切数字（我这边无法下载 ISO，所以不去猜）。
- 预期：去固件 ≈ **758 → 500 MiB 左右**；再加 `DROP_GUI=1` 删图形安装器 ≈ **430 MiB**，回到 bullseye 量级，能刻 CD。
- 代价：没有固件，某些 Wi-Fi/显卡在装机时无法联网；用有线即可，或按 [Debian wiki](https://wiki.debian.org/DebianInstaller/NetbootFirmware) 的方法外挂 `firmware.cpio.gz`。
- 安全性：脚本不动 `main/binary-amd64/Packages` 和 udeb 索引，只从顶层 `Release` 删除 non-free-firmware 行，d-i 的完整性检查不会失败。

## 1c. 只留"上一版就有的"显卡固件，能不能同时塞下 XFCE？

**能，而且这笔账刚好合上 —— 前提是别用 NVIDIA。** 我从 Debian 镜像的 `pool/non-free-firmware/f/firmware-nonfree/` 拉到了 trixie 当前固件包（`20261019-1`）的真实体积：

| 固件包 | 大小 | 固件包 | 大小 |
|---|---:|---|---:|
| **firmware-nvidia-graphics** | **99 MB** | firmware-amd-graphics | 16 MB |
| firmware-marvell-prestera | 58 MB | firmware-intel-graphics | 8 MB |
| firmware-atheros | 38 MB | firmware-misc-nonfree | 6 MB |
| firmware-mediatek | 33 MB | firmware-brcm80211 | 5 MB |
| firmware-qcom-soc | 28 MB | firmware-realtek | 4 MB |
| firmware-iwlwifi | 25 MB | firmware-intel-misc | 3 MB |

29 个包合计 **339 MB（324 MiB）**，但**显卡固件只要 8–16 MB**（Intel 8+3，AMD 16；NVIDIA 例外，单包 99 MB）。bullseye 时代的 `20230210-5` 全量约 105 MB，而且当时**根本没有** `firmware-nvidia-graphics`（2025 年才出现，现在 99 MB），`firmware-intel-graphics` 也是后来从 `firmware-misc-nonfree` 拆出来的。所以"只要上一版就有的"这个原则，**天然就把最胖的那个 99 MB 包排除掉了**。

体积账（按你那张盘的实测比例估算，最终数字由 CI 打印）：

```
13.8 netinst                     758 MB
− 全量固件                       −324 MiB  → 约 434 MB
+ 显卡固件（AMD/Intel）           +8~16 MB  → 约 442~450 MB
+ XFCE slim 闭包（无 firefox/编译环境）
   bullseye 实测：CD 510 MiB 中 netinst pool 约 301 MiB，
   即"桌面+standard+内核"净增约 209 MiB；trixie 内核更大，
   估 220~280 MiB                           → 约 660~730 MB  ✅ 贴着 647 MiB
（若保留 NVIDIA +99 MB                      → 约 760~830 MB  ❌ 超了）
```

**实现**：`.github/workflows/build-xfce-gpu-fw.yml` 把两步串起来——

1. `shrink-netinst.sh` 的 `FIRMWARE_KEEP` 只保留指定固件包，**把这些 deb 搬进 `pool/main/`** 再删掉整个 non-free-firmware 组件；
2. `remaster.sh` 用 `BASE_ISO_OVERRIDE` 接上这个产物，`AREAS=main` 灌入 XFCE，并把固件包名写进 `pkgsel/include`，**装完的系统里确实有这个固件**。

这个设计的关键好处：不用维护 non-free-firmware 组件的 Packages/Release 索引，保留的固件在 main 里按普通包被索引，d-i 完整性检查不会出问题。

## 2. 体积到底花在哪（按 section 聚合，998 包）

| section | 包数 | 体积 | section | 包数 | 体积 |
|---|---:|---:|---|---:|---:|
| libs | 528 | 174.2 MiB | fonts | 13 | 19.6 MiB |
| kernel | 9 | 55.4 MiB | utils | 61 | 19.4 MiB |
| web | 2 | 46.5 MiB | devel | 11 | 15.3 MiB |
| admin | 89 | 33.9 MiB | **xfce** | **37** | **9.2 MiB** |
| x11 | 40 | 19.7 MiB | gnome(图标/主题) | 8 | 14.3 MiB |

**关键结论：XFCE 本体只有 9.2 MiB / 37 个包。** 体积全在：

- 依赖库 174 MiB（llvm/mesa/icu/python 这些"看不见"的东西）
- 内核 55 MiB、浏览器 46 MiB、字体 19.6 MiB
- `devel` 15 MiB —— 是 standard 任务带的 `gcc-9/cpp-9/linux-headers`，很多人其实不需要

所以"裁剪"的真正旋钮是**要不要浏览器 / 要不要编译环境 / 要不要固件 / 要不要图形安装器**，不是"换个更轻的桌面"。

## 3. 为什么不能照抄那 998 个包名

bullseye(2019) → trixie(13.x) 的映射已经断代：

| bullseye 里的包 | trixie 现状 |
|---|---|
| `libllvm9` | 现在是 `libllvm19`（soname 跟着 LLVM 走） |
| `gcc-9` / `cpp-9` | `gcc-14` / `cpp-14` |
| `libicu63` | `libicu76` |
| `python2.7*` | 已从主线删除 |
| `firefox-esr` | 还在，但体积从 45 MiB 涨到约 2 倍 |
| `systemd` `locales` | 变大，且 `locales` 依赖链变了 |
| 固件 | bookworm 起独立成 `non-free-firmware` 归档区 |

硬编码包名 → `apt` 直接 404，或者装出个残缺系统。**正确做法：抄「根包/任务」，让 apt 在目标发行版重算闭包。**
`manifests/cd1-roots.txt` 就是我从这张盘算出来的 59 个根包（不在任何包 Depends/Recommends 里、真正"被点选"的那些）：`task-xfce-desktop`、`firefox-esr`、`wget`、`vim-tiny`、`lvm2`、`mdadm`、`exim4-daemon-light`、`brltty`、`grub-efi` 等。这张清单比 998 行包名有用得多。

## 4. 四条路线

| 路线 | 产物 | 体积预期 | 复杂度 | CI 时长 | 备注 |
|---|---|---|---|---|---|
| **A. netinst 灌包**（`build-cd.yml`） | 安装 CD，BIOS+UEFI，离线可装 | 0.7–1.2 GB | 中 | 10–15 min | 和你的盘同构，索引要自己重建 |
| **B. live-build**（`build-live.yml`） | Live 桌面，内置安装器 | 0.6–0.9 GB | 低 | 15–30 min | 一条命令出图，最不容易翻车 |
| C. debian-cd 全流程 | 官方同构，可做多盘 | 0.7–1.2 GB | 高 | 40–90 min | 需要本地 partial mirror |
| D. simple-cdd | 同 C，封装版 | 同上 | 中 | 30–60 min | 上游久未大改，trixie 上要试 |

**尺寸上必须接受的现实**：13.8 的 netinst 本身已经 758 MB（内核/固件/initrd 都涨了）。在它上面"加桌面"必然 >758 MB。想要 650 MB 量级，只有两条路：**砍掉 non-free-firmware + 不装浏览器 + 去掉图形安装器 initrd（44 MiB）**，或者走 B 路线（squashfs 压缩，体积天然小一截）。

体积估算公式（用你这张盘的真实比例校准）：

```
产物 ≈ netinst(758) + 桌面闭包 deb 总量 - 可从 netinst 里删掉的部分
装完占用 ≈ deb 总量 × 4.2
live ISO ≈ 装完占用 × 0.35~0.45（xz squashfs）
```

## 5. 体积工程：按这张盘实测，哪些能砍

| 砍掉 | 省下（bullseye 实测） | 代价 |
|---|---:|---|
| `install.amd/gtk/initrd.gz` | **44.5 MiB** | 只剩文本安装界面（对桌面盘无所谓） |
| `firefox-esr` | 45.6 MiB | 系统里没浏览器，装完再联网装 |
| `gcc-9`+`cpp-9`+`libz3-4`+`linux-headers` | 31.7 MiB | 无编译环境（standard 任务的赠品） |
| `libflite1`+`espeak-ng-data` | 15.7 MiB | 无语音朗读 |
| `xfonts-100dpi`/`xfonts-base` 等点阵字体 | 9.3 MiB | 极老的 X 程序字变丑 |
| 非中文 `locales`、`doc-*` | ~5 MiB | 无 |

前四项加起来 ≈ 147 MiB：**647 → 约 500 MiB**，这就是这张盘能被压到的地板。

## 6. 仓库里有什么

```
.github/workflows/build-cd.yml       # 路线 A：netinst 灌包 → 自带桌面的安装 CD
.github/workflows/build-live.yml     # 路线 B：live-build → Live 桌面
.github/workflows/shrink-netinst.yml # 路线 C：把官方 netinst 的固件摘掉，复刻 bullseye 量级
.github/workflows/build-xfce-gpu-fw.yml # 路线 D：只留显卡固件 + XFCE（最贴近你那张盘）
scripts/remaster.sh                  # A 的实现（8 步，含体积报告；支持 BASE_ISO_OVERRIDE）
scripts/shrink-netinst.sh            # C 的实现（LBA 去重体积解剖 + FIRMWARE_KEEP 白名单 + 可选摘图形安装器）
manifests/cd1-packages.tsv           # 从你这张 ISO 解出的 998 包全量清单（名/版/架/大小/section）
manifests/cd1-roots.txt              # 上面算出的 59 个根包 = 真正的"点选清单"
```

用法：把这个目录推成一个 repo → Actions 里手动触发 `build-install-cd`（可选 slim/task、是否装推荐包、追加 firefox-esr 等）→ 从 artifact 拿 ISO。

`remaster.sh` 的 8 步：解包 netinst → 用空 dpkg 状态让 apt **算出完整桌面闭包并只下载** → 按 Debian pool 布局灌进 `pool/main/` → `apt-ftparchive` 重建 `Packages(.gz/.xz)` → 手写 `Release`（含 MD5Sum/SHA256，漏了就是 Hash Sum mismatch）→ 改 `.disk/{info,cd_type}` 为 `full_cd/single` 并重算 `md5sum.txt` → `xorriso -as mkisofs` 重新打 BIOS+UEFI 双启 ISO → 打印体积报告。

## 7. 第一次跑最可能挂在哪（按概率排序）

0. **内核和引导器必须显式进盘。** d-i 的 `base-installer` 会从光盘里找 `linux-image-amd64`，`finish-install` 会找 `grub-pc`/`grub-efi-amd64`；清单里漏了它们，安装到一半就转去联网，离线装机直接卡死。脚本已把 `BASE_REQUIRED` 固定加进两个 profile。
1. **`Release` 哈希/md5sum 不一致** → d-i 报 `Hash Sum mismatch`。脚本已重算，但如果你手工动过 pool 要重跑第 5 步。
2. **tasksel 语义**：`task-xfce-desktop` 安装时默认带 Recommends，盘上缺一个就整段失败。`slim` 模式因此写成 `preseed.cfg`（`pkgsel/install-recommends false` + `pkgsel/include`）并把 `preseed/file=/cdrom/preseed.cfg` 挂到启动参数上；`task` 模式才是官方等价行为。
3. **UEFI 引导**：`efi.img` 在 trixie 的路径可能是 `boot/grub/efi.img` 或 `EFI/boot/efi.img`，脚本自动探测；`-isohybrid-mbr` 依赖 `isolinux` 包里的 `isohdpfx.bin`。
4. **`dists/<rel>/main/debian-installer/binary-amd64/`** 必须原样保留（udeb 索引），删了安装器找不到组件。
5. **`.disk/cd_type`** 必须是 `full_cd/single`，否则 `apt-setup` 装完 base 仍然要求联网。
6. **固件**：只留 `main` 时不带无线网卡固件，笔记本装完可能没网。要就 `AREAS="main contrib non-free-firmware"`，代价 +100~200 MiB。
7. **Actions 资源**：容器 `debian:trixie`，磁盘 14 GB 够用；1 GB 级 artifact 单文件在 2 GB 限制内。首次跑建议 `profile=slim, recommends=no, areas=main` 先拿一个能启动的产物，再逐项加。

---

**一句话给你的建议**：按你刚才说的"显卡只要上一版有的"，直接跑路线 D（`build-xfce-gpu-fw.yml`，`gpu=amd` 或 `intel`），这是最贴近你那张 647 MiB 盘的复刻；想先看 netinst 到底胖在哪，跑 `shrink-netinst.yml`；想要"开机就是桌面"，跑路线 B。
