#!/bin/sh
# update-gcc-tarball.sh - refresh the injected GCC snapshot tarball from a local
# git checkout, so musl-cross-make builds the compiler from *your* tree.
#
# musl-cross-make treats GCC as a normal package: it looks for
#   sources/gcc-$GCC_VER.tar.gz          (a tarball whose top dir is gcc-$GCC_VER/)
# verified against
#   hashes/gcc-$GCC_VER.tar.gz.sha1
# then extracts to gcc-$GCC_VER.orig, copies to gcc-$GCC_VER, and applies
# patches/gcc-$GCC_VER/*. There is no official gcc-17.0.0 release, so we generate
# that tarball ourselves from a trunk checkout via `git archive`.
#
# Usage:
#   ./update-gcc-tarball.sh [GCC_CHECKOUT] [GIT_REF]
#
#   GCC_CHECKOUT  path to the gcc git worktree   (default: $GCC_SRC or
#                 /media/flo/nvme0-ssd/gcc/gcc-git)
#   GIT_REF       commit/branch/tag to snapshot  (default: HEAD)
#
# Options (env):
#   DISTCLEAN=1   also remove build/ so the next `make` rebuilds GCC from scratch
#                 (mcm's incremental build/ does NOT notice new source contents).
#
# Only committed content is captured (git archive). Uncommitted working-tree
# edits are ignored; commit or stash them first if you want them in the build.

set -eu

# --- locate the mcm repo (this script's dir) and read GCC_VER from config.mak --
unset CDPATH
MCM_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$MCM_DIR"

if [ ! -f config.mak ]; then
	echo "error: config.mak not found in $MCM_DIR" >&2
	exit 1
fi

# Active (non-commented) GCC_VER assignment; last one wins, matching make.
GCC_VER=$(sed -n 's/^[[:space:]]*GCC_VER[[:space:]]*=[[:space:]]*//p' config.mak | tail -n1)
if [ -z "${GCC_VER:-}" ]; then
	echo "error: GCC_VER is not set (uncommented) in config.mak" >&2
	exit 1
fi

SRC=${1:-${GCC_SRC:-/media/flo/nvme0-ssd/gcc/gcc-git}}
REF=${2:-HEAD}

PKG="gcc-$GCC_VER"
TARBALL="sources/$PKG.tar.gz"
HASHFILE="hashes/$PKG.tar.gz.sha1"

# --- sanity checks -----------------------------------------------------------
if ! git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
	echo "error: '$SRC' is not a git checkout" >&2
	exit 1
fi

COMMIT=$(git -C "$SRC" rev-parse "$REF")
DESC=$(git -C "$SRC" log -1 --format='%h %ci %s' "$REF")

if [ -n "$(git -C "$SRC" status --porcelain=v1)" ]; then
	echo "warning: $SRC has uncommitted changes -- they will NOT be included" >&2
	echo "         (git archive only captures committed content of $REF)" >&2
fi

echo "==> Snapshotting $SRC @ $REF"
echo "    $DESC"
echo "==> Target: $TARBALL  (top dir: $PKG/)"

mkdir -p sources hashes

# --- build the tarball -------------------------------------------------------
# Top-level directory MUST be gcc-$GCC_VER/ for mcm's extract rule to work.
TMP="$TARBALL.tmp.$$"
trap 'rm -f "$TMP"' EXIT INT TERM
git -C "$SRC" archive --format=tar.gz --prefix="$PKG/" "$REF" > "$TMP"
mv -f "$TMP" "$TARBALL"
trap - EXIT INT TERM

# record provenance next to the tarball
printf '%s  %s\n' "$COMMIT" "$REF" > "sources/$PKG.gitref"

# --- refresh the hash, then make sure the tarball is newer than it -----------
# (mcm's rule `$(SOURCES)/%: hashes/%.sha1` would re-download if the .sha1 were
#  newer than the tarball -- and the GNU mirror has no gcc-17.0.0, so it'd fail.)
( cd sources && sha1sum "$PKG.tar.gz" ) > "$HASHFILE"
touch "$TARBALL"

echo "==> Wrote $TARBALL ($(du -h "$TARBALL" | cut -f1)) and updated $HASHFILE"

# --- drop stale extracted trees so `make` re-extracts + re-patches -----------
rm -rf "$PKG" "$PKG.orig" "$PKG.tmp" "$PKG.orig.tmp"
echo "==> Removed stale $PKG/ and $PKG.orig/ (will be re-extracted on next build)"

# --- optional: verify our patch stack still applies to the new tree ----------
if [ -d "patches/$PKG" ] && ls "patches/$PKG"/* >/dev/null 2>&1; then
	echo "==> Dry-run: checking patches/$PKG/* still apply..."
	WORK=$(mktemp -d)
	# extract into a temp tree named $PKG/ and try the same cat|patch -p1 mcm uses
	( cd "$WORK" && tar xzf "$MCM_DIR/$TARBALL" )
	if cat "patches/$PKG"/* | ( cd "$WORK/$PKG" && patch -p1 --dry-run ) >/dev/null 2>&1; then
		echo "    OK: all patches apply cleanly"
	else
		echo "    WARNING: some patches FAILED the dry-run against $REF." >&2
		echo "    Re-run manually to see details:" >&2
		echo "      cat patches/$PKG/* | (cd <extracted>/$PKG && patch -p1 --dry-run)" >&2
	fi
	rm -rf "$WORK"
fi

# --- optional deep clean -----------------------------------------------------
if [ "${DISTCLEAN:-0}" = "1" ]; then
	rm -rf build
	echo "==> DISTCLEAN: removed build/ (full GCC rebuild on next make)"
else
	echo "==> Note: mcm's build/ cache won't detect the new sources on its own."
	echo "    For a clean rebuild:  rm -rf build   (or re-run with DISTCLEAN=1)"
fi

echo "==> Done. Next:  make  (or: make install)"
