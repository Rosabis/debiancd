#!/bin/bash
# build-slitaz-kernel.sh — Build a SliTaz-style kernel .tazpkg from vanilla
# kernel.org sources, entirely inside a GitHub Actions runner (no SliTaz host,
# no cookutils, no uclibc cross-toolchain required).
#
# Reproduces what SliTaz wok/linux/stuff does, but with gcc-native builds:
#   download tarball -> apply SliTaz patches -> use SliTaz .config ->
#   build bzImage + modules -> xz-compress modules -> assemble .tazpkg.
#
# Usage:
#   ARCH=i486|amd64 VERSION=3.16.85 OUT=out.iso bash scripts/build-slitaz-kernel.sh
#
# Required env:
#   ARCH     i486 (32-bit, LOCALVERSION -slitaz, pkg 'linux') or
#            amd64 (64-bit, LOCALVERSION -slitaz64, pkg 'linux64')
#   VERSION  kernel version, e.g. 3.16.85 (default 3.16.85)
# Optional env:
#   KERNEL_URL  override tarball URL
#   JOBS        parallel make jobs (default nproc)
#   APPLY_PATCHES   1/0 (default 1)
#   OUTDIR      output directory (default work)
#   EXTRA_KCFLAGS   extra kernel CFLAGS (e.g. -Wno-error=incompatible-pointer-types)

set -euo pipefail

ARCH="${ARCH:-i486}"
VERSION="${VERSION:-3.16.85}"
JOBS="${JOBS:-$(nproc)}"
APPLY_PATCHES="${APPLY_PATCHES:-1}"
OUTDIR="${OUTDIR:-work}"
EXTRA_KCFLAGS="${EXTRA_KCFLAGS:-}"

# --- Per-arch profile -------------------------------------------------------
case "$ARCH" in
  i486|i386|x86)
    KARCH=i386
    CROSS=""                       # native gcc with -m32; no uclibc toolchain
    CONFIG_SRC="linux-slitaz.config"
    SUFFIX=""                      # LOCALVERSION "-slitaz"
    PKG="linux"
    BITS=32
    ;;
  amd64|x86_64|64)
    KARCH=x86_64
    CROSS=""                       # CRITICAL: config64 hardcodes uclibc-x86_64-
    CONFIG_SRC="linux-slitaz.config64"
    SUFFIX="64"                    # LOCALVERSION "-slitaz64"
    PKG="linux64"
    BITS=64
    ;;
  *)
    echo "ERROR: unknown ARCH=$ARCH (use i486 or amd64)" >&2
    exit 2
    ;;
esac

KVER="${VERSION}-slitaz${SUFFIX}"          # e.g. 3.16.85-slitaz64
MAJ="${VERSION%%.*}"                        # 3
SRC="linux-${VERSION}"
TARBALL="linux-${VERSION}.tar.xz"
KERNEL_URL="${KERNEL_URL:-https://cdn.kernel.org/pub/linux/kernel/v${MAJ}.x/${TARBALL}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STUFF="$REPO_ROOT/slitaz-kernel/stuff"
WORK="$REPO_ROOT/$OUTDIR/$ARCH"
DESTDIR="$WORK/dest"
mkdir -p "$WORK" "$DESTDIR"

log() { echo -e "\n=== $* ==="; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --- 1. Download & extract vanilla kernel ----------------------------------
cd "$WORK"
if [ ! -d "$SRC" ]; then
  log "Downloading $KERNEL_URL"
  if [ ! -f "$TARBALL" ]; then
    curl -fsSL --retry 3 -o "$TARBALL" "$KERNEL_URL" || die "download failed"
  fi
  log "Extracting $TARBALL"
  tar xf "$TARBALL"
fi
cd "$SRC"
echo "Kernel source ready: $(pwd)"

# --- 2. Apply SliTaz patches (from repo, tolerant of version skew) ----------
if [ "$APPLY_PATCHES" = "1" ]; then
  log "Applying SliTaz kernel patches"
  # Patches were made against 3.16.53; use --fuzz and --forward so 3.16.85's
  # minor drift doesn't abort the whole build. Failed patches are recorded.
  : > "$WORK/patch-failures.txt"
  for p in linux-diff.u linux-freeinitrd.u linux-subroot.u \
           linux-romfs.u linux-tcp_stealth.u linux-efi.u; do
    if [ ! -f "$STUFF/$p" ]; then
      echo "WARN: patch $p not found in $STUFF, skipping" | tee -a "$WORK/patch-failures.txt"
      continue
    fi
    echo "  -> $p"
    # Patch paths reference linux-3.16.53/... ; -p1 strips that component.
    if ! patch -p1 --forward --batch --fuzz=3 < "$STUFF/$p" > "$WORK/patch-$p.log" 2>&1; then
      echo "WARN: patch $p did not apply cleanly (see patch-$p.log)" | tee -a "$WORK/patch-failures.txt"
    fi
  done
  echo "Patch failures: $(wc -l < "$WORK/patch-failures.txt")"
fi

# --- 3. Install SliTaz .config ---------------------------------------------
log "Installing SliTaz config for $ARCH"
cp -f "$STUFF/$CONFIG_SRC" .config
# Force LOCALVERSION to the SliTaz per-arch suffix.
sed -i "s|\(CONFIG_LOCALVERSION=\).*|\1\"-slitaz${SUFFIX}\"|" .config
# Clear any hardcoded cross-compile prefix (config64 ships uclibc-x86_64-).
sed -i 's|^CONFIG_CROSS_COMPILE=.*|CONFIG_CROSS_COMPILE=""|' .config
# Enable modules (the without-modules variant is not our target here).
sed -i 's|^# CONFIG_MODULES is not set|CONFIG_MODULES=y|' .config
# Accept new symbols introduced between the config's kernel and 3.16.85.
# Use process substitution (not `yes | make`) so pipefail doesn't trip on
# `yes` receiving SIGPIPE when oldconfig finishes.
make ARCH="$KARCH" oldconfig < <(yes '') > "$WORK/oldconfig.log" 2>&1 || die "oldconfig failed"
echo "Config: $(grep -E '^CONFIG_(LOCALVERSION|64BIT|X86_32|CROSS_COMPILE)=' .config | tr '\n' ' ')"

# --- 4. Build bzImage + modules --------------------------------------------
log "Building bzImage + modules (ARCH=$KARCH, JOBS=$JOBS)"
# Modern gcc compatibility: 3.16 predates -fno-common default and strict
# pointer checks; relax those so the old tree compiles on gcc 11/12/13.
KCFLAGS="-fcommon -Wno-error=incompatible-pointer-types -Wno-error=array-bounds ${EXTRA_KCFLAGS}"

make ARCH="$KARCH" $CROSS KCFLAGS="$KCFLAGS" -j"$JOBS" bzImage \
  > "$WORK/build-bzimage.log" 2>&1 || { tail -60 "$WORK/build-bzimage.log"; die "bzImage build failed"; }
make ARCH="$KARCH" $CROSS KCFLAGS="$KCFLAGS" -j"$JOBS" modules \
  > "$WORK/build-modules.log" 2>&1 || { tail -60 "$WORK/build-modules.log"; die "modules build failed"; }
echo "bzImage: $(ls -lh arch/x86/boot/bzImage | awk '{print $5}')"

# --- 5. Install kernel + modules into DESTDIR ------------------------------
log "Installing modules into DESTDIR"
make ARCH="$KARCH" $CROSS INSTALL_MOD_PATH="$DESTDIR" modules_install \
  > "$WORK/install-modules.log" 2>&1 || die "modules_install failed"
mkdir -p "$DESTDIR/boot"
cp arch/x86/boot/bzImage "$DESTDIR/boot/vmlinuz-${KVER}"
cp System.map "$DESTDIR/boot/System.map-${KVER}"
cp .config "$DESTDIR/boot/config-${KVER}"

# --- 6. Compress modules to .ko.xz and fix modules.dep (gztazmod.sh logic) -
log "Compressing modules (.ko -> .ko.xz)"
MODDIR="$DESTDIR/lib/modules/$KVER"
if [ ! -d "$MODDIR" ]; then die "module dir $MODDIR missing"; fi
find "$MODDIR" -name '*.ko' -type f -exec xz -9 {} \;
# modules.dep references .ko on both sides of ':' plus dependency lines.
# Rewrite every ".ko" token to ".ko.xz" (idempotent: skip ones already .xz).
# Match .ko followed by ':' (key) or end-of-line/whitespace (dependency).
if [ -f "$MODDIR/modules.dep" ]; then
  sed -i -E 's/\.ko(\.xz)?([[:space:]:]|$)/.ko.xz\2/g' "$MODDIR/modules.dep"
fi

# --- 7. Select core modules into fs/ (SliTaz main package subset) ----------
log "Assembling package fs/ from core modules list"
FSROOT="$WORK/pkg/fs"
rm -rf "$WORK/pkg"
mkdir -p "$FSROOT/boot" "$FSROOT/lib/modules/$KVER"

# Always ship the kernel image, map, config and module metadata maps.
cp "$DESTDIR/boot/vmlinuz-${KVER}" "$FSROOT/boot/"
cp "$DESTDIR/boot/System.map-${KVER}" "$FSROOT/boot/" 2>/dev/null || true
cp "$DESTDIR/boot/config-${KVER}" "$FSROOT/boot/" 2>/dev/null || true
for m in modules.order modules.builtin modules.dep modules.alias modules.symbols; do
  [ -f "$MODDIR/$m" ] && cp "$MODDIR/$m" "$FSROOT/lib/modules/$KVER/"
done

# Cherry-pick modules listed in SliTaz's modules.list (core set). The list
# paths are relative to kernel/ ; copy matching .ko.xz files if present.
MODLIST="$STUFF/modules.list"
copied=0
missed=0
# Build a basename index of all compressed modules for path-drift fallback.
declare -A MODIDX
while IFS= read -r -d '' m; do
  MODIDX["$(basename "$m")"]="$m"
done < <(find "$MODDIR/kernel" -type f -name '*.ko.xz' -print0)

if [ -f "$MODLIST" ]; then
  while IFS= read -r raw || [ -n "$raw" ]; do
    rel="$(echo "$raw" | tr -d ' \t\r')"     # strip stray whitespace
    [ -z "$rel" ] && continue
    dstrel="$rel"
    case "$dstrel" in *.xz) ;; *) dstrel="${dstrel}.xz";; esac
    src="$MODDIR/kernel/$rel"
    hit=""
    if [ -f "$src" ]; then
      hit="$src"
    elif [ -n "${MODIDX[$(basename "$rel")]:-}" ]; then
      # path drifted between 3.16.55 and $VERSION — match by basename,
      # but preserve the path the kernel will actually look for.
      hit="${MODIDX[$(basename "$rel")]}"
      dstrel="${hit#$MODDIR/kernel/}"
    fi
    if [ -n "$hit" ]; then
      mkdir -p "$FSROOT/lib/modules/$KVER/kernel/$(dirname "$dstrel")"
      cp -a "$hit" "$FSROOT/lib/modules/$KVER/kernel/$dstrel"
      copied=$((copied+1))
    else
      missed=$((missed+1))
    fi
  done < "$MODLIST"
fi
echo "Core modules copied: $copied  missed: $missed"

# --- 8. Build receipt + files.list + md5sum --------------------------------
log "Generating receipt / files.list / md5sum"
PKGDIR="$WORK/pkg"
{
  echo '# SliTaz package receipt v2.'
  echo 'PACKAGE="'"$PKG"'"'
  echo 'VERSION="'"$VERSION"'"'
  echo 'CATEGORY="base-system"'
  echo 'SHORT_DESC="The Linux kernel and modules '"$VERSION"'."'
  echo 'MAINTAINER="github-actions@users.noreply.github.com"'
  echo 'LICENSE="GPL2"'
  echo 'WEB_SITE="https://www.kernel.org/"'
  echo 'DEPENDS="kmod"'
  echo 'post_install() { chroot "$root/" depmod -a '"$KVER"' ; }'
  echo 'post_remove()  { chroot "$root/" depmod -a '"$KVER"' ; }'
} > "$PKGDIR/receipt"

# files.list: regular files then symlinks, paths relative to fs/ with leading /.
( cd "$FSROOT" && find . -type f -print ) | sed 's|^\./|/|' > "$PKGDIR/files.list"
( cd "$FSROOT" && find . -type l -print ) | sed 's|^\./|/|' >> "$PKGDIR/files.list"

# md5sum: skip symlinks and the auto-generated module map files (as tazpkg does).
: > "$PKGDIR/md5sum"
while IFS= read -r f; do
  [ -L "$FSROOT$f" ] && continue
  [ -f "$FSROOT$f" ] || continue
  case "$f" in
    /lib/modules/*/modules.*) continue ;;
  esac
  h=$(md5sum "$FSROOT$f" | awk '{print $1}')
  echo "$h  $f" >> "$PKGDIR/md5sum"
done < "$PKGDIR/files.list"

# Sizes for the receipt (K blocks, matching tazpkg's du -chs output).
UNPACKED=$(du -chs "$FSROOT" "$PKGDIR/receipt" "$PKGDIR/files.list" "$PKGDIR/md5sum" 2>/dev/null | awk 'END{print $1}')
# --- 9. Compress fs/ to fs.cpio.lzma ---------------------------------------
log "Compressing fs/ -> fs.cpio.lzma"
# CRITICAL: cpio must archive the literal "fs" directory (entries fs/, fs/boot/...),
# because tazpkg installs with `cp -af fs/* "$root/"`. Archiving from inside
# fs/ (entries ./boot/...) would extract without the fs/ prefix and break install.
( cd "$PKGDIR" && find fs -print | cpio -o -H newc --quiet | xz -9 --format=lzma --stdout ) \
  > "$PKGDIR/fs.cpio.lzma"
PACKED=$(du -chs "$PKGDIR/fs.cpio.lzma" "$PKGDIR/receipt" "$PKGDIR/files.list" "$PKGDIR/md5sum" 2>/dev/null | awk 'END{print $1}')
rm -rf "$FSROOT"
# Inject size fields just below the first line (tazpkg style).
sed -i "2i PACKED_SIZE=\"$PACKED\"\nUNPACKED_SIZE=\"$UNPACKED\"" "$PKGDIR/receipt"

# --- 10. Wrap everything into the final .tazpkg (outer newc cpio) ----------
log "Wrapping final .tazpkg"
TAZPKG_NAME="${PKG}-${VERSION}.tazpkg"
( cd "$PKGDIR" && find . -print | cpio -o -H newc --quiet ) > "$WORK/$TAZPKG_NAME"
sha256sum "$WORK/$TAZPKG_NAME" | awk '{print $1}' > "$WORK/$TAZPKG_NAME.sha256"

log "DONE"
ls -lh "$WORK/$TAZPKG_NAME" "$WORK/$TAZPKG_NAME.sha256"
echo "TAZPKG_PATH=$WORK/$TAZPKG_NAME"
echo "TAZPKG_SIZE=$(stat -c%s "$WORK/$TAZPKG_NAME")"
echo "MODULE_COUNT=$copied"
