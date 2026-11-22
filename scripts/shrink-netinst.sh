#!/usr/bin/env bash
# ============================================================================
# shrink-netinst.sh —— 把官方 netinst 里的 non-free firmware（以及可选图形安装器）摘掉
#
# 背景：Debian 12 起官方媒介开始携带 non-free-firmware，Debian CD 团队因此把
#       netinst 的 FORCE_CD_SIZE1 从 CD700 改成了 STICK1GB。实测 11.5.0→12.0.0：
#         /firmware    0 → 216 MiB
#         /install.amd 67 → 138 MiB
#         /pool       301 → 360 MiB
#       也就是说"netinst 变大"主要是固件 + 安装器里膨胀的驱动/固件 udeb，不是桌面。
#
# 本脚本不改主归档（main）的任何文件，只删固件相关目录并把 Release 里的
# non-free-firmware 组件摘掉，因此对 d-i 的完整性检查是安全的。
#
# 用法（root，Debian/Ubuntu 环境）：
#   # 全部删掉
#   KEEP_FIRMWARE=0 bash scripts/shrink-netinst.sh
#   # 只保留显卡固件，其余全删；保留的 deb 会搬进 pool/main，作为普通包被索引
#   FIRMWARE_KEEP="firmware-amd-graphics" bash scripts/shrink-netinst.sh
#
# FIRMWARE_KEEP 常用取值（trixie 实测大小）：
#   firmware-amd-graphics 16 MB / firmware-intel-graphics + -misc 11 MB /
#   firmware-nvidia-graphics 99 MB；而全量固件集约 339 MB。
# ============================================================================
set -euo pipefail

DIST="${DIST:-trixie}"
CDIMAGE="${CDIMAGE:-https://cdimage.debian.org/debian-cd}"
NETINST_VER="${NETINST_VER:-auto}"
WORK="${WORK:-$PWD/work-shrink}"
OUT="${OUT:-debian-${DIST}-amd64-netinst-slim.iso}"
KEEP_FIRMWARE="${KEEP_FIRMWARE:-0}"
DROP_GUI="${DROP_GUI:-0}"
SIZE_LIMIT_MB="${SIZE_LIMIT_MB:-800}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$WORK"; cd "$WORK"

# ---------- 0 工具 ----------
log "0/7 安装工具"
export DEBIAN_FRONTEND=noninteractive
if command -v xorriso >/dev/null 2>&1; then
  echo "    xorriso 已就绪"
else
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends xorriso curl ca-certificates gzip xz-utils >/dev/null
fi

# ---------- 1 取 ISO ----------
log "1/7 获取官方 netinst"
if [ "$NETINST_VER" = "auto" ]; then
  NETINST_VER=$(curl -fsSL "$CDIMAGE/current/amd64/iso-cd/SHA256SUMS" \
    | awk '/-amd64-netinst\.iso$/{print $2; exit}' \
    | sed -E 's/^debian-(.*)-amd64-netinst\.iso$/\1/')
  [ -n "$NETINST_VER" ] || die "无法解析版本号，请显式设置 NETINST_VER"
fi
BASE_ISO="debian-${NETINST_VER}-amd64-netinst.iso"
[ -f "$BASE_ISO" ] || curl -fL --retry 3 -o "$BASE_ISO" \
  "$CDIMAGE/current/amd64/iso-cd/$BASE_ISO"
echo "    $BASE_ISO  ($(du -h "$BASE_ISO" | cut -f1))"

# ---------- 2 按 LBA 去重统计真实占用（y）----------
# 直接 du 解包后的目录会把 /firmware 与 /pool/non-free-firmware 的硬链接重复计数。
# 按 Debian CD 邮件列表里 Thomas Schmitt 的方法：用 report_lba 取每个文件的起始 LBA，
# 相同 LBA 只算一次，这才是 ISO 上真实占用的块数。
report_lba() {
  local iso="$1" label="$2"
  echo "--- $label ---"
  xorriso -indev "$iso" -find / -type f -exec report_lba -- 2>/dev/null \
    | awk -F' , ' '
        /^File data lba:/ {
          lba = $2 + 0;
          if (!(lba in seen)) {
            seen[lba] = 1; total += $3;
            p = $5; gsub(/^\047|\047$/, "", p);
            split(p, a, "/"); top = (a[2] == "" ? "(root)" : a[2]);
            per[top] += $3;
          }
        }
        END {
          printf "  unique data: %7.1f MiB\n", total * 2048 / 1048576;
          for (d in per) printf "    /%-22s %7.1f MiB\n", d, per[d] * 2048 / 1048576;
        }' | sort -k2 -nr
}
log "2/7 体积解剖（按 LBA 去重，非 du）"
report_lba "$BASE_ISO" "原始镜像"

# ---------- 3 解包 ----------
log "3/7 解包 ISO"
rm -rf tree; mkdir -p tree
xorriso -osirrox on -indev "$BASE_ISO" -extract / tree >/dev/null 2>&1 \
  || die "xorriso 解包失败"
chmod -R u+w tree

# ---------- 4 删除固件 ----------
log "4/7 删除 non-free-firmware"
if [ "$KEEP_FIRMWARE" = "1" ]; then
  echo "    KEEP_FIRMWARE=1，跳过"
else
  # 关键优化：只保留"上一版就有的"那几个固件包（通常是显卡固件）。
  # 把它们搬到 pool/main/，后续由 remaster.sh 的 main 索引统一收编 ——
  # 这样既不用维护 non-free-firmware 组件索引，装完的系统里也有对应固件。
  if [ -n "${FIRMWARE_KEEP:-}" ]; then
    mkdir -p tree/pool/main/f
    MOVED=0; MOVED_MB=0
    for fw in $FIRMWARE_KEEP; do
      for deb in tree/firmware/${fw}_*.deb; do
        [ -f "$deb" ] || continue
        base=$(basename "$deb")
        pkg=${base%%_*}
        install -D -m644 "$deb" "tree/pool/main/f/$pkg/$base"
        MOVED=$((MOVED+1))
        MOVED_MB=$((MOVED_MB + $(du -m "$deb" | cut -f1)))
      done
    done
    echo "    保留固件: $FIRMWARE_KEEP → $MOVED 个 deb / ${MOVED_MB} MiB 已移入 pool/main"
  fi
  for p in tree/firmware "tree/pool/non-free-firmware" "tree/dists/$DIST/non-free-firmware"; do
    [ -e "$p" ] && { echo "    rm -rf $p"; rm -rf "$p"; }
  done
  # 有些点发行版还有 pool/contrib 等，若 dists Release 里没列就别动
  REL="tree/dists/$DIST/Release"
  if [ -f "$REL" ]; then
    sed -i '/non-free-firmware/d' "$REL"
    sed -i -E 's/^(Components:).*$/Components: main/' "$REL"
  fi
  echo "main" > tree/.disk/base_components
  if [ -f tree/.disk/info ]; then
    sed -i 's/ with firmware//; s/WITH FIRMWARE//' tree/.disk/info
  fi
  echo "    已摘掉 non-free-firmware 组件"
fi

# ---------- 5 可选：删掉图形安装器 ----------
log "5/7 图形安装器"
if [ "$DROP_GUI" = "1" ]; then
  if [ -d tree/install.amd/gtk ]; then
    GUI_MB=$(du -sm tree/install.amd/gtk | cut -f1)
    rm -rf tree/install.amd/gtk
    echo "    删除 install.amd/gtk（${GUI_MB} MiB）"
    # 清掉引导菜单里指向 gtk initrd 的条目；按空行分段过滤
    while IFS= read -r f; do
      cp "$f" "$f.bak"
      awk 'BEGIN{RS="";ORS="\n\n"} !/gtk\//' "$f.bak" > "$f"
      if ! grep -q 'vmlinuz' "$f"; then
        echo "    [warn] $f 已无 vmlinuz 条目，恢复备份"
        mv "$f.bak" "$f"
      else
        rm -f "$f.bak"
      fi
    done < <(find tree/isolinux tree/boot/grub -type f 2>/dev/null \
             | while read -r x; do grep -q 'gtk/' "$x" && echo "$x"; done)
    sed -i -E 's/^(default[[:space:]]+)installgui/\1install/' \
      tree/isolinux/isolinux.cfg 2>/dev/null || true
  else
    echo "    没有 install.amd/gtk，跳过"
  fi
else
  echo "    DROP_GUI=0，保留图形安装（可省约 40–90 MiB，但只能文本安装）"
fi

# ---------- 6 重算 md5sum.txt ----------
log "6/7 重算 md5sum.txt"
( cd tree && find . -type f ! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt )
echo "    $(wc -l < tree/md5sum.txt) 条"

# ---------- 7 重打包 ----------
log "7/7 重打包 ISO"
EFI_IMG=$(cd tree && find . -name 'efi.img' -o -name 'efiboot.img' | head -1 | sed 's#^\./##')
MK=(-r -J -joliet-long -cache-inodes -partition_offset 16
    -A "Debian $DIST netinst slim" -p "Debian custom CD" -publisher "Debian custom CD")
if [ -f tree/isolinux/isolinux.bin ]; then
  MK+=(-b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot
       -boot-load-size 4 -boot-info-table)
  if [ -f /usr/lib/ISOLINUX/isohdpfx.bin ]; then
    MK+=(-isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin)
  fi
fi
if [ -n "${EFI_IMG:-}" ]; then
  MK+=(-eltorito-alt-boot -e "$EFI_IMG" -no-emul-boot -isohybrid-gpt-basdat)
fi
rm -f "$OUT"
xorriso -as mkisofs "${MK[@]}" -V "Debian ${NETINST_VER} amd64 1" -o "$OUT" tree \
  > xorriso.log 2>&1 || { tail -20 xorriso.log; die "xorriso 打包失败"; }

printf '\n========== 体积对比 ==========\n'
echo "  原镜像: $(du -m "$BASE_ISO" | cut -f1) MiB"
echo "  裁剪后: $(du -m "$OUT" | cut -f1) MiB  -> $OUT"
report_lba "$OUT" "裁剪后（按 LBA 去重）"
if [ "$(du -m "$OUT" | cut -f1)" -gt "$SIZE_LIMIT_MB" ]; then
  echo "  [warn] 仍超过 ${SIZE_LIMIT_MB} MiB；试试 DROP_GUI=1"
fi
sha256sum "$OUT" | tee "$OUT.sha256"
