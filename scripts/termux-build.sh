#!/usr/bin/env bash
# Build herdr natively on Termux/Android (aarch64-linux-android).
#
# Two things stop a plain `cargo build --release` on Termux:
#   1. zig cannot provide bionic libc for android targets, so build.rs needs
#      an Android sysroot to compile the vendored libghostty-vt against.
#   2. zig's build runner hard-links into its cache, and Android's
#      untrusted_app SELinux domain denies link(2), so the zig phase must run
#      as root and the tree has to be handed back to the app afterwards.
#
# The sysroot below is assembled from the Termux prefix itself: same bionic
# headers, same CRT objects and the device's own /system/lib64 libc, laid out
# the way vendor/libghostty-vt/pkg/android-ndk expects to find an NDK.
set -euo pipefail

SELF="$(readlink -f "$0")"
REPO="${HERDR_REPO:-$(dirname "$(dirname "$SELF")")}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HERDR_HOME:-/data/data/com.termux/files/home}"
NDK_FAKE="${ANDROID_NDK_HOME:-$HOME_DIR/android-ndk-fake}"
SYSROOT="$NDK_FAKE/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
API=29
ZIG_REQUIRED=0.16.0

log() { printf '\033[1m[termux-build]\033[0m %s\n' "$*"; }

# magisk su resets HOME to "/", so the root phase has to fix its environment
# before any path default below is derived from $HOME.
if [ "${1:-}" = --root-phase ]; then
  export HOME="$HOME_DIR"
  export CARGO_HOME="$HOME/.cargo"
  export PATH="$PREFIX/bin:/system/bin:/system/xbin"
  unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy CARGO_TARGET_DIR
fi

if [ "${1:-}" != --root-phase ]; then
  # ---------------------------------------------------------------- user phase
  zig version | grep -qx "$ZIG_REQUIRED" || {
    log "installing zig $ZIG_REQUIRED"
    pkg install -y zig
    zig version | grep -qx "$ZIG_REQUIRED" || { log "zig $(zig version) != $ZIG_REQUIRED"; exit 1; }
  }

  log "building bionic sysroot at $NDK_FAKE"
  rm -rf "$NDK_FAKE"
  mkdir -p "$SYSROOT/usr/include/c++" "$SYSROOT/usr/lib/aarch64-linux-android/$API"
  for f in "$PREFIX"/include/*; do ln -sfn "$f" "$SYSROOT/usr/include/$(basename "$f")"; done
  ln -sfn "$PREFIX/include/c++/v1" "$SYSROOT/usr/include/c++/v1"
  for f in "$PREFIX"/lib/crt*.o "$PREFIX/lib/libc++_shared.so"; do
    ln -sfn "$f" "$SYSROOT/usr/lib/aarch64-linux-android/$(basename "$f")"
    ln -sfn "$f" "$SYSROOT/usr/lib/aarch64-linux-android/$API/$(basename "$f")"
  done
  for f in /system/lib64/libc.so /system/lib64/libm.so /system/lib64/libdl.so \
           /system/lib64/liblog.so /system/lib64/libz.so; do
    ln -sfn "$f" "$SYSROOT/usr/lib/aarch64-linux-android/$(basename "$f")"
    ln -sfn "$f" "$SYSROOT/usr/lib/aarch64-linux-android/$API/$(basename "$f")"
  done

  # su drops termux-exec, so the `#!/usr/bin/env bash` shebang (no /usr/bin on
  # Android) cannot be resolved: hand the root phase to the Termux bash.
  log "cargo build --release (as root, for zig's hard-link cache)"
  su -c "HERDR_REPO='$REPO' HERDR_HOME='$HOME_DIR' '$PREFIX/bin/bash' '$SELF' --root-phase" || exit 1

  log "done: $REPO/target/release/herdr"
  "$REPO/target/release/herdr" --version
  exit 0
fi

# ---------------------------------------------------------------- root phase
export ANDROID_NDK_HOME="$NDK_FAKE"
cd "$REPO"
cargo build --release --locked
status=$?

# Everything root wrote (target/, zig-out/, .zig-cache/, the zig package cache)
# is root-owned and carries the root SELinux label, which leaves it unreadable
# and undeletable for the app: fix ownership and restore the app's categories.
if [ "$status" -eq 0 ]; then
  label="$(ls -Zd "$HOME" | awk '{print $1}')"
  chown -R "$(stat -c %u "$HOME"):$(stat -c %g "$HOME")" \
    "$REPO" "$HOME/.cargo" "$HOME/.cache/zig" 2>/dev/null || true
  chcon -R "$label" "$REPO" "$HOME/.cargo" "$HOME/.cache/zig" 2>/dev/null || true
fi
exit "$status"
