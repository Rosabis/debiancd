#!/usr/bin/env bash
# 构建 Debian bullseye 5.10 内核的 linux-image .deb（stripped）。
#
# 思路：
#   1. 从 snapshot.debian.org 拉 Debian 官方源码包（dsc + orig + debian tarball）
#   2. 把 amd64 收敛成唯一 flavour（去掉 cloud-amd64），只编一个 flavour
#   3. DEBIAN_KERNEL_DISABLE_DEBUG=1 关掉几百 MB 的 -dbg 包
#      —— vmlinuz 的 objcopy --strip-debug 和模块的 INSTALL_MOD_STRIP=1
#         是 Debian 打包规则无条件做的，所以 image 包天然就是 stripped 的
#   4. 同源构建 linux-headers 三件套（arch headers + common headers + kbuild），
#      否则第三方模块（DKMS/VirtualBox/NVIDIA/ZFS）的 Module.symvers CRC 可能与
#      这个内核对不上，编出来的模块加载失败。headers 必须与 image 同版本同源码。
#   5. 可选再重打包一个只含 vmlinuz + lib/modules 的 minimal 包
#
# 用法（workflow 里通过环境变量传参）：
#   VERSION=5.10.262-1 ABI=5.10.0-46 MODE=both HEADERS=yes bash scripts/build-bullseye-kernel.sh
set -euo pipefail

VERSION="${VERSION:-5.10.262-1}"       # Debian 源版本（打包框架 + 补丁集的来源）
ABI="${ABI:-5.10.0-46}"                # 二进制 ABI 名（与上游修订号解耦）
SNAPSHOT="${SNAPSHOT:-20260804T131246Z}" # snapshot.debian.org 时间戳
UPSTREAM_TARGET="${UPSTREAM_TARGET:-}" # 可选：嫁接到 kernel.org 上游版本，如 5.10.274
MODE="${MODE:-both}"                   # official | minimal | both
HEADERS="${HEADERS:-yes}"              # yes/true/1 = 一并构建 headers 三件套
# GitHub 表达式可能把 YAML 的 yes 渲染成 true；统一归一化，别让它静默关掉 headers
case "$HEADERS" in
  true|TRUE|1) HEADERS=yes ;;
esac
JOBS="${JOBS:-$(nproc)}"
WORK="${WORK:-work/kernel}"
OUT="${OUT:-work/kernel-out}"

UPSTREAM="${VERSION%-*}"               # 5.10.262-1 -> 5.10.262
KBUILD_VER="${UPSTREAM%.*}"            # 5.10.262 -> 5.10（linux-kbuild-5.10）
PKG="linux-image-${ABI}-amd64"
# 嫁接后源码版本改成 <上游>-1；包名前缀 ABI 不变（Debian 内核 KERNELRELEASE 被覆盖成 ABI）
SRCVER="${UPSTREAM_TARGET:+$UPSTREAM_TARGET-1}"
SRCVER="${SRCVER:-$VERSION}"
OFFICIAL="${PKG}_${SRCVER}_amd64.deb"
MINIMAL="${PKG}-minimal_${SRCVER}_amd64.deb"
# headers 三件套：arch 头依赖 common 的精确版本 + kbuild，三者必须同批下载/安装
HDR_ARCH="linux-headers-${ABI}-amd64_${SRCVER}_amd64.deb"
HDR_COMMON="linux-headers-${ABI}-common_${SRCVER}_all.deb"
HDR_KBUILD="linux-kbuild-${KBUILD_VER}_${SRCVER}_amd64.deb"
BASE="https://snapshot.debian.org/archive/debian-security/${SNAPSHOT}/pool/updates/main/l/linux"

# 这些开关必须在 debian/control 生成之前就生效：gencontrol.py 在那一刻决定
# 是否生成 -dbg 包、是否把镜像包命名为 -unsigned。
#   DISABLE_SIGNED=1 -> 产出 linux-image-<ABI>-amd64（官方名字），而不是 -unsigned；
#                       签名版本来由单独的 linux-signed-amd64 源码包生成，这里用不上。
#   DISABLE_DEBUG=1  -> 不生成几百 MB 的 linux-image-*-dbg。
export DEBIAN_KERNEL_DISABLE_SIGNED=1
export DEBIAN_KERNEL_DISABLE_DEBUG=1
export DEBIAN_KERNEL_JOBS="$JOBS"
export DEB_BUILD_PROFILES="nodoc pkg.linux.nosource noudeb pkg.linux.nometa pkg.linux.mintools"

say() { printf '\n=== %s ===\n' "$*"; }

say "构建参数"
printf '  version  = %s\n  upstream = %s\n  abi      = %s\n  snapshot = %s\n  mode     = %s\n  headers  = %s\n  jobs     = %s\n' \
  "$VERSION" "$UPSTREAM" "$ABI" "$SNAPSHOT" "$MODE" "$HEADERS" "$JOBS"

mkdir -p "$WORK" "$OUT"
# 关键：改用绝对路径。之前 SRCDIR 是相对的 "work/kernel/linux-..."，而下面又
# cd 进了 "$WORK"，dpkg-source 的目标目录被拼成 work/kernel/work/kernel/...，
# 连带 orig tarball 的复制目标也算错，报 "cannot copy ... No such file"。
WORK="$(cd "$WORK" && pwd)"
OUT="$(cd "$OUT" && pwd)"
SRCDIR="$WORK/linux-${UPSTREAM}"
cd "$WORK"

say "下载 Debian 源码包"
for f in "linux_${UPSTREAM}.orig.tar.xz" "linux_${VERSION}.debian.tar.xz" "linux_${VERSION}.dsc"; do
  if [ ! -s "$f" ]; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$f" "${BASE}/${f}"
  fi
  printf '  %-46s %s\n' "$f" "$(du -h "$f" | cut -f1)"
done

say "校验 dsc 中的 SHA256 并解压源码"
# 自己校验 checksum，再用 --no-check 让 dpkg-source 别去跑 gpgv：
# bullseye-slim 的 gpgv 不认 trustedkeys.kbx，日志会刷 "No public key" 警告。
# 签名警告本来不致命，但去掉后 CI 日志干净，完整性校验也一点没少。
awk '
  /^Checksums-Sha256:/ { in_sec=1; next }
  /^[^[:space:]]/       { in_sec=0 }
  in_sec && NF==3 && length($1)==64 && $1 ~ /^[0-9a-f]+$/ { print $1 "  " $3 }
' "$WORK/linux_${VERSION}.dsc" > "$WORK/.sha256-check"
test -s "$WORK/.sha256-check" || { echo "ERROR: 没从 dsc 解析出 SHA256"; exit 1; }
( cd "$WORK" && sha256sum -c .sha256-check )
rm -f "$WORK/.sha256-check"
# 上次失败可能留下半截目录；只有完整解出的树才算可复用。
if [ -d "$SRCDIR" ] && [ ! -f "$SRCDIR/debian/rules" ]; then
  echo "清理上次残留的不完整源码树：$SRCDIR"
  rm -rf "$SRCDIR"
fi
if [ ! -d "$SRCDIR" ]; then
  dpkg-source --no-check -x "$WORK/linux_${VERSION}.dsc" "$SRCDIR"
fi

if [ -n "$UPSTREAM_TARGET" ] && [ "$UPSTREAM_TARGET" != "$UPSTREAM" ]; then
  say "嫁接上游：${UPSTREAM} -> ${UPSTREAM_TARGET}（kernel.org 增量补丁链）"
  # 为什么用增量而不是整包替换：Debian 的 102 个补丁 + 配置已经套在 5.10.262
  # 源码树上，逐个叠加 kernel.org 的 262→263→…→274 增量补丁，Debian 打包层
  # 完全不动，冲突面最小（上游 stable 只改少量代码，且这些补丁多为 Xen 修复）。
  INCR="https://cdn.kernel.org/pub/linux/kernel/v5.x/incr"
  cur="$UPSTREAM"
  : > "$WORK/upstream-patch-log.txt"
  while [ "$cur" != "$UPSTREAM_TARGET" ]; do
    n="${cur##*.}"                       # 262
    next="${cur%.*}.$((n + 1))"          # 5.10.263
    pf="patch-${cur}-${next}.xz"
    if [ ! -s "$pf" ]; then
      curl -fsSL --retry 3 --retry-delay 2 -o "$pf" "${INCR}/${pf}"
    fi
    printf '  %-28s' "$pf"
    if xz -dc "$pf" | ( cd "$SRCDIR" && patch -p1 --forward --batch --fuzz=2 ); then
      echo " OK"
    else
      echo " 检查上游-patch-log.txt（可能已由 Debian 补丁 backport 同一修复）"
    fi
    xz -dc "$pf" | grep -E '^--- |^\+\+\+ ' >> "$WORK/upstream-patch-log.txt" || true
    cur="$next"
  done

  say "同步源码版本号到 debian/changelog"
  # 只改第一行版本，distribution 保持 bullseye-security（打包规则与 ABI 不变）。
  # 内核 KERNELRELEASE 由 rules.real:187 强制覆盖成 ABINAME，uname 仍是 5.10.0-46-amd64。
  sed -i "1s/^linux ([^)]*)/linux (${UPSTREAM_TARGET}-1)/" "$SRCDIR/debian/changelog"
  head -1 "$SRCDIR/debian/changelog"
  # 版本号变了 -> version-info/control.md5sum 失配，下面生成 control 时会自动重跑 gencontrol
  rm -f "$SRCDIR/debian/control.md5sum"
fi

say "收敛 flavour：amd64 none 设为唯一 flavour"
# 原文件是 flavours: amd64 + cloud-amd64，quick-flavour 是 cloud-amd64；
# 另外 amd64/defines 还挂了 rt featureset（会多编一遍完整 RT 内核）。
# 只留 none/amd64，省掉 cloud 和 rt 两遍完整编译，拿到的正是官方通用 amd64 包。
cat > "$SRCDIR/debian/config/amd64/none/defines" <<'EOF'
[base]
flavours:
 amd64
default-flavour: amd64
EOF
cat > "$SRCDIR/debian/config/amd64/defines" <<'EOF'
[base]
featuresets:
 none
kernel-arch: x86

[build]
image-file: arch/x86/boot/bzImage
# 关键：必须为 false，否则 gencontrol.py 会选 control.image-unsigned 模板，
# 产物叫 linux-image-<ABI>-amd64-unsigned，拿不到"官方源那种"包名。
signed-code: false
vdso: true

[image]
bootloaders: grub-pc grub-efi-amd64 extlinux
install-stem: vmlinuz
breaks: xserver-xorg-input-vmmouse (<< 1:13.0.99)

[relations]
headers%gcc-10: linux-compiler-gcc-10-x86

[amd64_description]
hardware: 64-bit PCs
hardware-long: PCs with AMD64, Intel 64 or VIA Nano processors

[cloud-amd64_description]
hardware: x86-64 cloud
hardware-long: cloud platforms including Amazon EC2, Microsoft Azure, and Google Compute Engine
EOF

say "生成 debian/control（内核规则会故意 exit 1，属预期行为）"
# 强制重生成：signed-code / featureset / disable_debug 的改动必须反映到
# control 里，否则 dbg 包和 -unsigned 包会按旧 control 继续构建。
rm -f "$SRCDIR/debian/control.md5sum"
( cd "$SRCDIR" && PYTHONHASHSEED=0 debian/rules debian/control ) || true
test -s "$SRCDIR/debian/control" || { echo "ERROR: debian/control 生成失败"; exit 1; }

say "编译 amd64 flavour"
# DEBIAN_KERNEL_DISABLE_DEBUG=1 -> 不生成 linux-image-*-dbg（否则多几百 MB）
# -d 跳过 build-dep 检查（依赖已在 workflow 里手动装好）
# -b（不是 -B）：common headers 是 Architecture: all，只有 -b 才会产出。
#   build profiles 把不需要的 indep 包挡掉：
#     nodoc               -> 排除 linux-doc-5.10（要 texlive/sphinx，几百 MB）
#     pkg.linux.nosource  -> 排除 linux-source-5.10（120MB 源码包）
#     noudeb              -> 排除 d-i udeb（几百个 -di 包）
#     pkg.linux.nometa    -> 排除 linux-image-amd64 / linux-headers-amd64 元包
#     pkg.linux.mintools  -> 排除 perf/bpftool/cpupower 等工具包
#   ⚠ 不能用 pkg.linux.notools：linux-kbuild-5.10 也带这个标记，会被一起排除，
#     而 headers-amd64 硬依赖它，依赖链就断了。mintools 不碰 kbuild。
#   headers 三件套的 Build-Profiles 是 <!pkg.linux.nokernel !stage1>（kbuild 还带
#   !pkg.linux.notools），上面这些 profile 都不影响它们。
(
  cd "$SRCDIR"
  dpkg-buildpackage -b -us -uc -d -j"$JOBS"
)

say "收集官方结构产物"
# 正常应产出 $OFFICIAL；万一 Debian 规则仍走了 unsigned 分支，也识别出来并
# 明确告警，而不是只报一句 "找不到文件" 让人猜。
IMAGE_SRC=""
for cand in "$OFFICIAL" "${PKG}-unsigned_${SRCVER}_amd64.deb"; do
  if [ -s "$WORK/$cand" ]; then IMAGE_SRC="$cand"; break; fi
done
if [ -z "$IMAGE_SRC" ]; then
  echo "ERROR: 找不到 image 包。$WORK 下实际 .deb："
  ls -lh "$WORK"/*.deb 2>/dev/null || true
  exit 1
fi
if [ "$IMAGE_SRC" != "$OFFICIAL" ]; then
  echo "注意：实际产出 $IMAGE_SRC（内部 Package 名带 -unsigned）；已改为收集它。"
fi
cp -f "$WORK/$IMAGE_SRC" "$OUT/"
( cd "$OUT" && sha256sum "$IMAGE_SRC" > "${IMAGE_SRC}.sha256" )

if [ "$HEADERS" = "yes" ]; then
  say "收集同源 headers 三件套"
  # 三者版本必须完全一致：arch headers 的 Depends 是
  #   linux-headers-<ABI>-common (= ${source:Version}) + linux-kbuild-<ver> (>= ${source:Version})
  for h in "$HDR_ARCH" "$HDR_COMMON" "$HDR_KBUILD"; do
    test -s "$WORK/$h" || { echo "ERROR: 找不到 $h（检查 build profiles 是否误伤 headers）"; exit 1; }
    cp -f "$WORK/$h" "$OUT/"
    ( cd "$OUT" && sha256sum "$h" > "${h}.sha256" )
  done
fi

if [ "$MODE" = "minimal" ] || [ "$MODE" = "both" ]; then
  say "重打包 minimal 版（只保留 boot/vmlinuz + lib/modules）"
  REPACK="$WORK/repack"
  rm -rf "$REPACK"
  mkdir -p "$REPACK/DEBIAN"
  dpkg-deb -x "$WORK/$IMAGE_SRC" "$REPACK"
  # 删掉 boot/ 与 lib/ 之外的所有目录（etc、usr/share/doc 等）
  find "$REPACK" -mindepth 1 -maxdepth 1 \
    ! -name boot ! -name lib ! -name DEBIAN -exec rm -rf {} +
  # boot/ 下只留 vmlinuz-*（去掉 config-* / System.map-*）
  find "$REPACK/boot" -mindepth 1 ! -name 'vmlinuz-*' -exec rm -rf {} +
  cat > "$REPACK/DEBIAN/control" <<EOF
Package: ${PKG}
Version: ${SRCVER}
Section: kernel
Priority: optional
Architecture: amd64
Maintainer: Local Build <local@localhost>
Depends: kmod
Description: Linux ${UPSTREAM} kernel image (stripped, minimal)
 Stripped vmlinuz and loadable modules rebuilt from Debian bullseye source.
 No initramfs hooks, no System.map, no config, no docs.
EOF
  dpkg-deb --build --root-owner-group "$REPACK" "$OUT/$MINIMAL"
  ( cd "$OUT" && sha256sum "$MINIMAL" > "${MINIMAL}.sha256" )
fi

say "校验产物"
for f in "$OUT"/*.deb; do
  echo "---- $(basename "$f") ----"
  ls -lh "$f"
  dpkg-deb -f "$f" Package Version Architecture Installed-Size Depends
  case "$(basename "$f")" in
    linux-headers-*|linux-kbuild-*)
      # headers 包：关键是 Module.symvers / .config / include，不应有 vmlinuz 或 .ko
      echo "  Module.symvers: $(dpkg-deb -c "$f" | grep -c 'Module.symvers' || true)"
      echo "  .config       : $(dpkg-deb -c "$f" | grep -c '/\.config$' || true)"
      ;;
    *)
      echo "  vmlinuz 条目: $(dpkg-deb -c "$f" | grep -c '/boot/vmlinuz-' || true)"
      echo "  .ko 条目   : $(dpkg-deb -c "$f" | grep -c '\.ko$' || true)"
      ;;
  esac
  dbg=$(dpkg-deb -c "$f" | grep -cE '(/usr/lib/debug/|\.debug$)' || true)
  echo "  调试符号条目: $dbg"
  [ "$dbg" -eq 0 ] || { echo "ERROR: 包内出现调试符号"; exit 1; }
done

# headers 三件套版本必须一致，否则 arch headers 的精确版本依赖装不上
if [ "$HEADERS" = "yes" ]; then
  for h in "$HDR_ARCH" "$HDR_COMMON" "$HDR_KBUILD"; do
    v=$(dpkg-deb -f "$OUT/$h" Version)
    [ "$v" = "$SRCVER" ] || { echo "ERROR: $h 版本 $v != $SRCVER，依赖链会断"; exit 1; }
  done
  echo "OK: headers 三件套版本一致（$SRCVER），依赖链完整"
fi

( cd "$OUT" && sha256sum -c ./*.sha256 )

say "完成，产物在 $OUT"
ls -lh "$OUT"
