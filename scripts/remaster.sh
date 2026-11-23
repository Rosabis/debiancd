#!/usr/bin/env bash
# ============================================================================
# remaster.sh —— 在官方 netinst 基础上"灌入"桌面依赖闭包，重打一张自带桌面的安装 CD
#
# 必须在 Debian/Ubuntu 环境（推荐 debian:trixie 容器）以 root 运行。
# 依赖：xorriso apt-utils xz-utils gzip curl isolinux ca-certificates
#
# 设计要点：
#   1. 不"抄包名"—— 让 apt 在目标发行版里重新算依赖闭包，避免 bullseye→trixie 改名/合并踩坑
#   2. 索引从实际 pool 目录重新生成，保证 Packages 与盘上文件严格一致
#   3. 体积由 PKGS 列表 + INSTALL_RECOMMENDS 控制，脚本结束打印体积报告
# ============================================================================
set -euo pipefail

# ---------- 可调参数 ----------
DIST="${DIST:-trixie}"
AREAS="${AREAS:-main}"                 # 需要固件就写 "main contrib non-free-firmware"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
CDIMAGE="${CDIMAGE:-https://cdimage.debian.org/debian-cd}"
NETINST_VER="${NETINST_VER:-auto}"     # auto = 从 SHA256SUMS 里解析最新版
PROFILE="${PROFILE:-slim}"             # slim | task | exact（exact = 照 manifests/cd1-packages.tsv 的 998 项复刻）
INSTALL_RECOMMENDS="${INSTALL_RECOMMENDS:-no}"   # slim 建议 no，task 建议 yes
PATCH_PRESEED="${PATCH_PRESEED:-1}"    # 是否把 pkgsel/include preseed 挂到启动命令上
SIZE_LIMIT_MB="${SIZE_LIMIT_MB:-800}"  # CD-R 实际约 700 MiB，超过只是告警（写 U 盘无妨）
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-debian-${DIST}-amd64-xfce-CD-1.iso}"
EXTRA_PKGS="${EXTRA_PKGS:-}"
# 默认就产出"小盘"：摘掉非显卡固件 + 图形/xen 安装器 initrd，并对 pool 去重。
STRIP_FIRMWARE="${STRIP_FIRMWARE:-1}"        # 0 = 保留官方全量固件（体积 +~310 MiB）
FIRMWARE_KEEP="${FIRMWARE_KEEP:-}"           # 保留的固件包名，空格分隔；会搬进 pool/main
DROP_EXTRA_INITRD="${DROP_EXTRA_INITRD:-1}"  # 0 = 保留 gtk/xen 安装器（体积 +~160 MiB）

# ---------- 两个 profile 的包清单 ----------
# 注意：内核必须显式带上 —— d-i 的 base-installer 会从光盘里找 linux-image-amd64，
# 缺了就会转去联网（离线安装直接失败）。
#
# 引导器不能两个一起交给同一次 apt 求解：trixie 里
#   grub-efi-amd64 Conflicts: grub-pc   (反之亦然)
# 写进同一个 install 命令必然 "held broken packages"。
# 正确做法：主闭包不放任何 grub flavor，另外用两次独立的 apt 求解分别下载
# grub-pc / grub-efi-amd64 及其依赖，两个 .deb 都进 pool；d-i 的 grub-installer
# 按实际启动方式（BIOS/UEFI）自己 apt-install 对应的那个。
GRUB_FLAVORS="${GRUB_FLAVORS:-grub-pc grub-efi-amd64}"
BASE_REQUIRED="linux-image-amd64"

# slim：只装"能进桌面、能上网、能出声"的最小集（推荐值）
SLIM_PKGS="
  $BASE_REQUIRED
  xfce4 xfce4-terminal thunar xfce4-taskmanager mousepad
  lightdm lightdm-gtk-greeter
  xorg xserver-xorg xinit dbus-x11 sudo
  network-manager network-manager-gnome
  pipewire pipewire-pulse wireplumber alsa-utils
  fonts-dejavu-core
  xfce4-whiskermenu-plugin
"
# task：官方等价 —— 直接把 tasksel 的 xfce 任务整包塞进盘里（体积大，但任务闭包完整）
TASK_PKGS="$BASE_REQUIRED task-xfce-desktop"
[ "$PROFILE" = "task" ] && PKGS="$TASK_PKGS" || PKGS="$SLIM_PKGS"
# 固件包不进 apt 闭包：它们来自 non-free-firmware，AREAS=main 时 apt 根本找不到。
# 它们已经被搬进 pool/main 并重建索引，只需写进 preseed 的 pkgsel/include 即可装上。
PRESEED_EXTRA="$FIRMWARE_KEEP"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

REPO_ROOT="$PWD"   # 清单文件在仓库里，cd 到 WORK 之后要用绝对路径找
mkdir -p "$WORK"
cd "$WORK"
# apt 的 -o Dir::Etc::sourcelist=<path> 必须是绝对路径；给相对路径时它会
# 按 /etc/apt/<path> 解析，报 "Unable to read /etc/apt/work/sources.list"
# 然后把所有包都当成不存在。WORK 可能是 workflow 传入的 "work" 这种相对值。
WORK="$PWD"

# ---------- 0. 依赖 ----------
log "0/8 安装构建工具"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl xorriso apt-utils xz-utils gzip isolinux file >/dev/null

# ---------- 1. 取官方 netinst ----------
log "1/8 获取官方 netinst 镜像"
if [ "$NETINST_VER" = "auto" ]; then
  NETINST_VER=$(curl -fsSL "$CDIMAGE/current/amd64/iso-cd/SHA256SUMS" \
    | awk '/-amd64-netinst\.iso$/{print $2; exit}' \
    | sed -E 's/^debian-(.*)-amd64-netinst\.iso$/\1/')
  [ -n "$NETINST_VER" ] || die "无法从 SHA256SUMS 解析版本号，请手动设置 NETINST_VER"
fi
if [ -n "${BASE_ISO_OVERRIDE:-}" ]; then
  [ -f "$BASE_ISO_OVERRIDE" ] || die "BASE_ISO_OVERRIDE 不存在: $BASE_ISO_OVERRIDE"
  BASE_ISO="$BASE_ISO_OVERRIDE"
  if [ "$NETINST_VER" = "auto" ]; then NETINST_VER="custom"; fi
elif [ -n "${NETINST_URL:-}" ]; then
  # 老版本（如 bullseye 11.11.0）只在 cdimage/archive/ 下，不在 current/
  BASE_ISO=$(basename "$NETINST_URL")
  [ -f "$BASE_ISO" ] || curl -fL --retry 3 -o "$BASE_ISO" "$NETINST_URL"
  if [ "$NETINST_VER" = "auto" ]; then
    NETINST_VER=$(printf '%s' "$BASE_ISO" | sed -E 's/^debian-([0-9.]+)-amd64-netinst\.iso$/\1/')
  fi
else
  BASE_ISO="debian-${NETINST_VER}-amd64-netinst.iso"
  [ -f "$BASE_ISO" ] || curl -fL --retry 3 -o "$BASE_ISO" \
    "$CDIMAGE/current/amd64/iso-cd/$BASE_ISO"
fi
echo "    基座: $BASE_ISO  $(du -h "$BASE_ISO" | cut -f1)"

# ---------- 2. 解包 ISO ----------
log "2/8 解包 ISO 到 tree/"
rm -rf tree; mkdir -p tree
xorriso -osirrox on -indev "$BASE_ISO" -extract / tree >/dev/null 2>&1 \
  || die "xorriso 解包失败"
chmod -R u+w tree
BASE_SIZE=$(du -sm tree | cut -f1)
echo "    解包后 $(du -sh tree | cut -f1)（内核/initrd/固件/pool）"

# ---------- 2b. 摘掉用不上的固件 ----------
# 官方 netinst 把固件同时放在 /firmware 和 /pool/non-free-firmware（原盘是硬链接，
# 但 xorriso 解包重打后会变成两份独立数据，实测白白多占 ~164 MiB）。这里整块拿掉，
# 只把白名单里的显卡固件搬进 pool/main 当普通包索引。
if [ "$STRIP_FIRMWARE" = "1" ]; then
  FW_SAVED=$( { du -sm tree/firmware tree/pool/non-free-firmware 2>/dev/null || true; } | awk '{s+=$1} END{print s+0}')
  if [ -n "$FIRMWARE_KEEP" ]; then
    for fw in $FIRMWARE_KEEP; do
      for deb in tree/firmware/${fw}_*.deb \
                 tree/pool/non-free-firmware/f/firmware-nonfree/${fw}_*.deb; do
        [ -f "$deb" ] || continue
        base=$(basename "$deb")
        install -D -m644 "$deb" "tree/pool/main/f/$fw/$base"
      done
    done
    echo "    保留固件: $FIRMWARE_KEEP（已移入 pool/main）"
  fi
  rm -rf tree/firmware tree/pool/non-free-firmware "tree/dists/$DIST/non-free-firmware"
  REL="tree/dists/$DIST/Release"
  if [ -f "$REL" ]; then
    sed -i '/non-free-firmware/d' "$REL"
    sed -i -E 's/^(Components:).*$/Components: main/' "$REL"
  fi
  echo "main" > tree/.disk/base_components
  echo "    已摘全量固件（约 ${FW_SAVED} MiB）"
else
  echo "    STRIP_FIRMWARE=0，保留官方全量固件"
fi

# ---------- 2c. 摘掉图形 / Xen 安装器 ----------
# install.amd/gtk/initrd.gz 与 install.amd/xen/initrd.gz 各带一份 vmlinuz，
# 合计约 160 MiB。文本安装足够把系统装起来，桌面是装完事。
if [ "$DROP_EXTRA_INITRD" = "1" ]; then
  EXTRA_SAVED=0
  for d in gtk xen; do
    if [ -d "tree/install.amd/$d" ]; then
      m=$(du -sm "tree/install.amd/$d" | cut -f1)
      EXTRA_SAVED=$((EXTRA_SAVED + m))
      rm -rf "tree/install.amd/$d"
    fi
  done
  for f in tree/isolinux/isolinux.cfg tree/boot/grub/grub.cfg \
           tree/EFI/boot/grub.cfg tree/boot/grub/efi.cfg; do
    [ -f "$f" ] || continue
    if grep -qE 'install\.amd/(gtk|xen)/' "$f"; then
      cp "$f" "$f.bak"
      awk 'BEGIN{RS="";ORS="\n\n"} !/install\.amd\/(gtk|xen)\//' "$f.bak" > "$f"
      if ! grep -q 'vmlinuz' "$f"; then
        echo "    [warn] $f 过滤后无启动项，恢复"
        mv "$f.bak" "$f"
      else
        rm -f "$f.bak"
      fi
    fi
  done
  sed -i -E 's/^(default[[:space:]]+)installgui/\1install/' \
    tree/isolinux/isolinux.cfg 2>/dev/null || true
  echo "    已摘图形/Xen 安装器（约 ${EXTRA_SAVED} MiB）"
else
  echo "    DROP_EXTRA_INITRD=0，保留图形/Xen 安装器"
fi

# ---------- 3. 让 apt 在目标发行版里算闭包并只下载 ----------
log "3/8 解析并下载桌面依赖闭包（profile=$PROFILE, recommends=$INSTALL_RECOMMENDS）"
rm -rf debs; mkdir -p debs
APT_OPTS=(
  -o "Dir::State::status=/dev/null"       # 假装系统没装任何包 → 拿到完整闭包
  -o "Dir::Cache::archives=$WORK/debs"
  -o "APT::Install-Recommends=$([ "$INSTALL_RECOMMENDS" = yes ] && echo true || echo false)"
  -o "APT::Install-Suggests=false"
)
printf 'deb %s %s %s\n' "$MIRROR" "$DIST" "$AREAS" > sources.list
# sourceparts 指向一个真实的空目录；用 "-" 会让 apt 每次都报
# "Unable to read /etc/apt/-/ - DirectoryExists"。
mkdir -p empty-sourceparts
REPO_OPTS=(-o "Dir::Etc::sourcelist=$WORK/sources.list" \
           -o "Dir::Etc::sourceparts=$WORK/empty-sourceparts")
# exact profile：用参照盘解出的包名，在目标发行版里按"还存在的"取交集。
# 老盘是 2019 年的 bullseye alpha，包改名/删除很常见（libllvm9→11、python2.7 等），
# 直接照抄会让 apt 报 Unable to locate package；这里先和当前 main 索引取交集。
INSTALL_PKGS="$PKGS"     # 交给 apt 求闭包的一组根包（必须彼此不冲突）
MANIFEST_PKGS=""         # exact：清单里的包，直接 apt-get download，不解析依赖
TASK_SELECT=""           # exact：让 d-i 用 tasksel 装 xfce-desktop
if [ "$PROFILE" = "exact" ]; then
  MANIFEST="${MANIFEST:-$REPO_ROOT/manifests/cd1-packages.tsv}"
  case "$MANIFEST" in /*) ;; *) MANIFEST="$REPO_ROOT/$MANIFEST" ;; esac
  [ -f "$MANIFEST" ] || die "找不到组件清单: $MANIFEST"
  cut -f1 "$MANIFEST" | sed -E 's/[[:space:]]+$//' | grep -v '^$' | sort -u > manifest-names.txt
  if curl -fsSL "$MIRROR/dists/$DIST/main/binary-amd64/Packages.xz" -o remote-Packages.xz; then
    xz -dc remote-Packages.xz | awk '/^Package: /{print $2}' | sort -u > remote-names.txt
  else
    curl -fsSL "$MIRROR/dists/$DIST/main/binary-amd64/Packages.gz" -o remote-Packages.gz \
      || die "无法获取 $DIST 的 Packages 索引"
    gzip -dc remote-Packages.gz | awk '/^Package: /{print $2}' | sort -u > remote-names.txt
  fi
  comm -12 manifest-names.txt remote-names.txt > exact-names.txt
  comm -23 manifest-names.txt remote-names.txt > missing-names.txt
  # 内核版本与 grub flavor 由脚本专门处理（grub-pc/efi 互斥、内核元包跟版本走）
  grep -v -E '^(grub|linux-image-)' exact-names.txt > exact-names.filtered.txt || true
  mv exact-names.filtered.txt exact-names.txt
  printf '    组件清单 %s 项 → 目标版可用 %s 项 / 已失效 %s 项\n' \
    "$(wc -l < manifest-names.txt)" "$(wc -l < exact-names.txt)" "$(wc -l < missing-names.txt)"
  head -15 missing-names.txt | sed 's/^/      失效: /'

  # 关键：参照盘是"安装媒介"，同一张盘上并存互斥的备选包——实测有
  #   rdnssd Conflicts network-manager、grub-pc Conflicts grub-efi-amd64。
  # 把 900+ 个包一次性交给 apt install 求"一个自洽系统"必然无解。
  # 正确做法拆成两路：
  #   A) 清单里的包用 apt-get download 直取（不解析依赖）→ 全部进 pool，忠于组件列表；
  #   B) 内核元包单独下载即可。绝不能用 task-xfce-desktop 求闭包：
  #      它在 bullseye 里 task-xfce-desktop -> task-desktop -> Recommends 会拉进
  #      libreoffice(80MiB)/gimp/pocketsphinx/webkit/gcc-10/libllvm11 等一大堆
  #      参照盘根本没有的包（实测 pool 从 510 膨胀到 970 MiB）。
  MANIFEST_PKGS="$(tr '\n' ' ' < exact-names.txt)"
  INSTALL_PKGS="$BASE_REQUIRED"
  TASK_SELECT="xfce-desktop"
fi

apt-get "${REPO_OPTS[@]}" "${APT_OPTS[@]}" update -qq \
  || die "apt update 失败，检查 $WORK/sources.list 与网络"
# 只打印诊断，不作阻断：apt-cache 在最小容器里的输出格式不稳定，
# 之前用 policy 做 gate 会误杀正常流程；真正的解析失败由下面的 install 给出明确报错。
echo "    apt 源: $(cat "$WORK/sources.list")"
if [ -n "$MANIFEST_PKGS" ]; then
  # A) 媒介清单直取：apt-get download 不做依赖解析，所以 rdnssd/network-manager
  #    这类"同盘并存但互斥"的包都能拿到。下载到 debs/，后面统一去重进 pool。
  # shellcheck disable=SC2086
  if ! ( cd debs && apt-get "${REPO_OPTS[@]}" "${APT_OPTS[@]}" download $MANIFEST_PKGS ) \
        > download-manifest.log 2>&1; then
    echo "    [warn] 清单批量直取有失败项，改为逐个重试并跳过不可用项"
    : > download-manifest-failed.txt
    for p in $MANIFEST_PKGS; do
      # shellcheck disable=SC2086
      ( cd debs && apt-get "${REPO_OPTS[@]}" "${APT_OPTS[@]}" download "$p" ) \
        >> download-manifest.log 2>&1 || echo "$p" >> download-manifest-failed.txt
    done
    echo "    最终无法直取 $(wc -l < download-manifest-failed.txt) 项（见 work/download-manifest-failed.txt）"
  fi
  echo "    清单直取后 debs/: $(find debs -maxdepth 1 -name '*.deb' | wc -l) 个 deb"
fi
# B) 自洽闭包：只解一组根包，避开媒介里并存的冲突备选包。
# shellcheck disable=SC2086
apt-get "${REPO_OPTS[@]}" "${APT_OPTS[@]}" install -y --download-only $INSTALL_PKGS $EXTRA_PKGS \
  > download.log 2>&1 || { tail -40 download.log; die "依赖解析失败，见 work/download.log"; }

# 引导器：两个 flavor 各自独立求解，避开 grub-pc <-> grub-efi-amd64 的 Conflicts。
# 各自的依赖（grub-common / grub2-common / *-bin）会一起下下来，合并进同一个 debs/。
for flavor in $GRUB_FLAVORS; do
  fdir="debs-grub-$flavor"
  rm -rf "$fdir"; mkdir -p "$fdir"
  apt-get "${REPO_OPTS[@]}" \
    -o "Dir::State::status=/dev/null" \
    -o "Dir::Cache::archives=$WORK/$fdir" \
    -o "APT::Install-Recommends=false" \
    -o "APT::Install-Suggests=false" \
    install -y --download-only "$flavor" > "download-$flavor.log" 2>&1 \
    || { tail -30 "download-$flavor.log"; die "引导器 $flavor 依赖解析失败"; }
  n=$(find "$fdir" -maxdepth 1 -name '*.deb' | wc -l)
  echo "    引导器 $flavor: $n 个 deb"
  find "$fdir" -maxdepth 1 -name '*.deb' -exec cp -n {} debs/ \;
done

DEB_N=$(find debs -maxdepth 1 -name '*.deb' | wc -l)
DEB_MB=$(du -sm debs | cut -f1)
[ "$DEB_N" -gt 0 ] || die "没有下载到任何 deb"
echo "    下载 $DEB_N 个 deb，共 ${DEB_MB} MiB"
{
  echo "# 闭包根包（apt install + preseed）"
  echo "$INSTALL_PKGS $EXTRA_PKGS $GRUB_FLAVORS" | tr -s ' \n' '\n' | grep -v '^$' | sort -u
  if [ -n "$MANIFEST_PKGS" ]; then
    echo "# 媒介清单（apt-get download 直取，不参与依赖求解）"
    echo "$MANIFEST_PKGS" | tr -s ' \n' '\n' | grep -v '^$' | sort -u
  fi
} > selected-pkgs.txt

# ---------- 4. 塞进 pool/ ----------
log "4/8 复制 deb 到 tree/pool/main/（按文件名去重）"
mkdir -p tree/pool/main
# 关键：netinst 的 pool 里本来就有大量 base 包（libc / perl / grub / kernel…）。
# 我们的脚本用"<包名>"当 pool 子目录，与 Debian 按源码包分组的布局不同，
# 原来的写法会把同一个 deb 再放一份（实测 176 个重复、180.6 MiB，其中内核一份就 103.5 MiB）。
# 只要文件名（含版本+架构）相同就是同一份数据，直接跳过。
( cd tree && find pool -type f -name '*.deb' -printf '%f\n' ) | sort -u > pool-existing.txt
ADDED=0; SKIPPED=0
for deb in debs/*.deb; do
  name=$(basename "$deb")
  if grep -Fxq "$name" pool-existing.txt; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  pkg=${name%%_*}
  case "$pkg" in
    lib*) letter=${pkg:0:4} ;;   # 遵循 Debian pool 布局：libfoo -> libf
    *)    letter=${pkg:0:1} ;;
  esac
  install -D -m644 "$deb" "tree/pool/main/$letter/$pkg/$name"
  echo "$name" >> pool-existing.txt
  ADDED=$((ADDED + 1))
done
echo "    新增 $ADDED 个 deb，跳过已存在 $SKIPPED 个"

# ---------- 5. 重建索引 ----------
log "5/8 重建 Packages / Release / md5sum.txt"
IDX="tree/dists/$DIST/main/binary-amd64"
[ -d "$IDX" ] || die "找不到 $IDX，结构和预期不符"
rm -f "$IDX"/Packages "$IDX"/Packages.gz "$IDX"/Packages.xz
( cd tree && apt-ftparchive packages pool > "dists/$DIST/main/binary-amd64/Packages" )
gzip -9 -c "$IDX/Packages" > "$IDX/Packages.gz"
xz   -9 -c "$IDX/Packages" > "$IDX/Packages.xz"
PKG_COUNT=$(grep -c '^Package: ' "$IDX/Packages")
echo "    索引里 $(($(stat -c%s "$IDX/Packages")/1024)) KiB / $PKG_COUNT 个包"

gen_release() {   # $1=目录  $2=路径前缀
  local dir="$1" prefix="$2" f
  {
    echo "Origin: Debian"
    echo "Label: Debian"
    echo "Suite: stable"
    echo "Codename: $DIST"
    echo "Version: custom"
    echo "Architectures: amd64"
    echo "Components: main"
    echo "Description: Debian $DIST custom CD (${PROFILE})"
    echo "Date: $(date -Ru)"
    echo "MD5Sum:"
    for f in Packages Packages.gz Packages.xz; do
      if [ -f "$dir/$f" ]; then
        printf " %s %16s %s%s\n" "$(md5sum "$dir/$f" | cut -d' ' -f1)" "$(stat -c%s "$dir/$f")" "$prefix" "$f"
      fi
    done
    echo "SHA256:"
    for f in Packages Packages.gz Packages.xz; do
      if [ -f "$dir/$f" ]; then
        printf " %s %16s %s%s\n" "$(sha256sum "$dir/$f" | cut -d' ' -f1)" "$(stat -c%s "$dir/$f")" "$prefix" "$f"
      fi
    done
  } > "$dir/Release"
}
gen_release "$IDX" ""
if [ -f "tree/dists/$DIST/Release" ]; then
  # 只替换 main/binary-amd64/Packages* 的校验行，**保留原 Release 的其余内容**。
  # 不能整份重写：原 Release 里还有 main/debian-installer/binary-amd64/Packages
  # （udeb 索引）、SHA512、Components 等条目，整份替换会让 d-i 找不到 udeb 或
  # 报 Hash Sum mismatch。
  REL="tree/dists/$DIST/Release"
  HASHES="$WORK/release-hashes.tsv"
  : > "$HASHES"
  for alg in MD5Sum SHA256 SHA512; do
    case "$alg" in
      MD5Sum) sum=md5sum ;;
      SHA256) sum=sha256sum ;;
      SHA512) sum=sha512sum ;;
    esac
    for f in Packages Packages.gz Packages.xz; do
      [ -f "$IDX/$f" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$alg" "main/binary-amd64/$f" \
        "$($sum "$IDX/$f" | cut -d' ' -f1)" "$(stat -c%s "$IDX/$f")" >> "$HASHES"
    done
  done
  awk -F'\t' '
    NR==FNR { key[$1 SUBSEP $2]=$3; siz[$1 SUBSEP $2]=$4; next }
    /^(MD5Sum|SHA1|SHA256|SHA512):[[:space:]]*$/ {
      sec=$1; sub(/:$/, "", sec); print; next
    }
    sec != "" && $0 ~ /^ [0-9a-fA-F]+[[:space:]]+[0-9]+[[:space:]]+/ {
      rest=substr($0, 2); n=split(rest, p, /[[:space:]]+/)
      path=p[n]; k=sec SUBSEP path
      if (k in key) { printf " %s %16s %s\n", key[k], siz[k], path; next }
    }
    { print }
  ' "$HASHES" "$REL" > "$REL.new"
  mv "$REL.new" "$REL"
  echo "    已原位更新顶层 Release 的 main/binary-amd64 校验行（保留 udeb 等条目）"
fi

# ---------- 6. 改 .disk 元数据 + 可选 preseed ----------
log "6/8 写 .disk 元数据"
printf 'Debian GNU/Linux %s "%s" - Custom amd64 xfce-CD\n Binary-1 %s\n' \
  "$NETINST_VER" "$DIST" "$(date +%Y%m%d-%H:%M)" > tree/.disk/info
echo "full_cd/single" > tree/.disk/cd_type
: > tree/.disk/base_installable
echo "main" > tree/.disk/base_components

if [ "$PATCH_PRESEED" = "1" ]; then
  log "6b preseed：让安装器只装这张盘上确实存在的包"
  if [ -n "$TASK_SELECT" ]; then
    # exact：照参照盘的行为用 tasksel 选 xfce-desktop；pkgsel/include 只放固件。
    # 绝不能把 900+ 个媒介包（含互斥备选）写进 pkgsel/include，否则装机时
    # 会在 d-i 里重现同一个 "held broken packages"。
    PRESEED_INCLUDE="$PRESEED_EXTRA $EXTRA_PKGS"
    TASK_LINE="tasksel tasksel/first multiselect $TASK_SELECT"
  else
    PRESEED_INCLUDE="$PKGS $EXTRA_PKGS $PRESEED_EXTRA"
    TASK_LINE="tasksel tasksel/first multiselect"
  fi
  # exact：11.11.0 的 task-xfce-desktop 推荐 libreoffice/gimp 等参照盘没有的包。
  # 这些包不在盘上，若允许 recommends，装机时会转去联网拉取（离线安装失败）。
  # 参照盘的 2019 alpha 任务元包不带这些推荐，所以这里强制关掉以忠实复刻。
  local_recs="$INSTALL_RECOMMENDS"
  [ -n "$TASK_SELECT" ] && local_recs="no"
  {
    echo "# 由 remaster.sh 生成：让安装器只装这张盘上确实存在的包"
    echo "pkgsel/install-recommends boolean $([ "$local_recs" = yes ] && echo true || echo false)"
    echo "$TASK_LINE"
    echo "pkgsel/include string $(echo $PRESEED_INCLUDE | tr '\n' ' ')"
  } > tree/preseed.cfg
  for f in tree/isolinux/isolinux.cfg tree/boot/grub/grub.cfg; do
    [ -f "$f" ] || continue
    sed -i -E 's#(^|[[:space:]])---#preseed/file=/cdrom/preseed.cfg ---#' "$f"
    grep -q 'preseed/file=/cdrom/preseed.cfg' "$f" || \
      sed -i -E 's#(vmlinuz.*)$#\1 preseed/file=/cdrom/preseed.cfg#' "$f"
  done
fi

( cd tree && find . -type f ! -name md5sum.txt ! -name Release -print0 | xargs -0 md5sum > md5sum.txt )
echo "    md5sum.txt: $(wc -l < tree/md5sum.txt) 行"

# ---------- 7. 重打包 ----------
log "7/8 重打包 ISO"
EFI_IMG=$(cd tree && find . -name 'efi.img' -o -name 'efiboot.img' | head -1 | sed 's#^\./##')
MK=(-r -J -joliet-long -cache-inodes -partition_offset 16
    -A "Debian $DIST custom" -p "Debian custom CD" -publisher "Debian custom CD")
if [ -f tree/isolinux/isolinux.bin ]; then
  MK+=(-b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot
       -boot-load-size 4 -boot-info-table)
  if [ -f /usr/lib/ISOLINUX/isohdpfx.bin ]; then
    MK+=(-isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin)
  fi
else
  echo "    [warn] 没有 isolinux.bin，产物将不支持 BIOS 启动"
fi
if [ -n "${EFI_IMG:-}" ]; then
  MK+=(-eltorito-alt-boot -e "$EFI_IMG" -no-emul-boot -isohybrid-gpt-basdat)
  echo "    UEFI El Torito: $EFI_IMG"
else
  echo "    [warn] 没找到 efi.img，产物将不支持 UEFI 启动"
fi
rm -f "$OUT"
xorriso -as mkisofs "${MK[@]}" -V "Debian ${NETINST_VER} amd64 1" -o "$OUT" tree > xorriso.log 2>&1 \
  || { tail -20 xorriso.log; die "xorriso 打包失败"; }

# ---------- 8. 体积报告 ----------
log "8/8 体积报告"
SIZE_MB=$(du -m "$OUT" | cut -f1)
printf '  基座 netinst      : %6s MiB\n' "$BASE_SIZE"
printf '  新增 deb          : %6s MiB (%s 个)\n' "$DEB_MB" "$DEB_N"
printf '  产物 ISO          : %6s MiB  -> %s\n' "$SIZE_MB" "$OUT"
printf '  pool 总量         : %6s MiB\n' "$(du -sm tree/pool | cut -f1)"
printf '  install.amd       : %6s MiB\n' "$(du -sm tree/install.amd | cut -f1)"
if [ "$SIZE_MB" -gt "$SIZE_LIMIT_MB" ]; then
  echo "  [warn] 超过 ${SIZE_LIMIT_MB} MiB，CD-R 写不下；写 U 盘，或削减 PKGS / 去掉 gtk initrd"
fi
sha256sum "$OUT" | tee "$OUT.sha256"
