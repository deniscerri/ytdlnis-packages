#!/bin/bash
#
# Build aria2-next (https://github.com/AnInsomniacy/aria2-next, the maintained aria2 rewrite with the
# aria2c command line and JSON-RPC) for Android and pack it into the libaria2c.so JNI layout used by
# YTDLnis (yt-dlp --downloader aria2c).
#
# RUN THIS FROM THE ROOT OF A termux-packages CHECKOUT, INSIDE the docker container
# (./scripts/run-docker.sh ./build_aria2.sh). Only the container's NDK is used: aria2-next builds its
# own vendored dependency stack (curl, openssl, libtorrent, sqlite, ffmpeg/gpac for HLS/DASH, ...)
# with CMake, not with termux recipes.
#
# Output:  ./output/jniLibs/<android-abi>/libaria2c.so
#
# The result is ONE static executable (libc++ and every dependency linked in, DT_NEEDED is only
# Android's libc/libm/libdl). So there is no libaria2c.zip.so and none of the shared-lib
# isolation / prune steps of the other build scripts apply: nothing of it can clash with the
# libs of other bundles on the app's LD_LIBRARY_PATH. TLS certificates come from the app
# (--ca-certificate=$SSL_CERT_FILE, see RuntimeManager.kt).
#
# USAGE (termux arch names, like the other scripts):
#   ./build_aria2.sh                 # all four arches
#   ./build_aria2.sh aarch64         # one arch
#   CLEAN=1 ./build_aria2.sh         # drop the per-arch CMake build dirs first
#
set -euo pipefail
shopt -s nullglob

############################  CONFIG  ############################

ARIA2_VERSION="${ARIA2_VERSION:-3.1.0}"
# sha256 of the GitHub tag archive; set ARIA2_SHA256= (empty) to skip the check when trying another version
ARIA2_SHA256="${ARIA2_SHA256-c2a7fc95c206c555743b22b6b902d5791b041c5fbf8a4b943a2c94666e6a7bcf}"
ARIA2_SRCURL="https://github.com/AnInsomniacy/aria2-next/archive/refs/tags/v${ARIA2_VERSION}.tar.gz"

ALL_ARCHES=("aarch64" "arm" "i686" "x86_64")
ANDROID_API="${ANDROID_API:-24}" # the app's minSdk
CLEAN="${CLEAN:-0}"

OUTPUT_BASE_DIR="${PWD}/output"
JNI_DIR="${OUTPUT_BASE_DIR}/jniLibs"
# On the container's own filesystem (a bind-mounted Windows checkout is slow and breaks symlinks).
WORK="${WORK_DIR:-/tmp/ytdlnis-work}/aria2"
PATCH_DIR="${PWD}/ytdlnis/aria2-next"

ELF_PAGE_SIZE=16384 # 16 KB segment alignment: also works on 4 KB devices, required on 16 KB ones

# Android system libs the binary may link (everything else must be static).
SYS_LIBS="libc.so libm.so libdl.so liblog.so"

#################################################################

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

in_list() { local x="$1"; shift; local e; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

android_abi() {
    case "$1" in
        aarch64) echo "arm64-v8a" ;;
        arm)     echo "armeabi-v7a" ;;
        i686)    echo "x86" ;;
        x86_64)  echo "x86_64" ;;
        *)       echo "$1" ;;
    esac
}

find_ndk() {
    local d
    for d in "${NDK:-}" "${ANDROID_NDK_HOME:-}" "$HOME"/lib/android-ndk*; do
        [ -n "$d" ] && [ -f "$d/source.properties" ] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

check_prereqs() {
    local missing=() t
    for t in cmake ninja make perl patch curl; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        # the termux builder image has no cmake/ninja; Ubuntu 24.04's cmake (3.28) is new enough (3.25+)
        info "installing missing tools: ${missing[*]}"
        local pkgs=("${missing[@]/ninja/ninja-build}")
        sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null \
            || die "could not install ${missing[*]} (apt-get install ${pkgs[*]})"
    fi
    NDK="$(find_ndk)" || die "Android NDK not found (set NDK=/path/to/ndk)"
    TOOLBIN="$(echo "$NDK"/toolchains/llvm/prebuilt/*/bin)"
    READELF="$TOOLBIN/llvm-readelf"
    STRIP="$TOOLBIN/llvm-strip"
    [ -x "$READELF" ] && [ -x "$STRIP" ] || die "llvm-readelf / llvm-strip not found in $TOOLBIN"
    # OpenSSL's android-* targets look for a bare "clang" on PATH (else: "no NDK <triple>-gcc on $PATH")
    export PATH="$TOOLBIN:$PATH"
}

fetch_source() {
    local tarball="${WORK}/aria2-next-${ARIA2_VERSION}.tar.gz"
    SRC="${WORK}/aria2-next-${ARIA2_VERSION}"
    if [ ! -f "$tarball" ]; then
        info "download $ARIA2_SRCURL"
        curl -fL --retry 3 -o "$tarball.part" "$ARIA2_SRCURL" || die "download failed"
        mv "$tarball.part" "$tarball"
    fi
    if [ -n "$ARIA2_SHA256" ]; then
        echo "$ARIA2_SHA256  $tarball" | sha256sum -c --quiet - \
            || { rm -f "$tarball"; die "wrong checksum for $tarball (removed, re-run to download again)"; }
    fi
    # re-extract whenever the patches change, so an edited patch never meets an already patched tree
    local stamp; stamp="$(cat "$PATCH_DIR"/*.patch 2>/dev/null | sha256sum | cut -c1-16)"
    if [ "$(cat "$SRC/.ytdlnis-patched" 2>/dev/null)" != "$stamp" ]; then
        rm -rf "$SRC"
        tar xzf "$tarball" -C "$WORK"
        local p
        for p in "$PATCH_DIR"/*.patch; do
            info "patch $(basename "$p")"
            patch -d "$SRC" -p1 --forward --quiet < "$p" || die "patch $(basename "$p") failed"
        done
        echo "$stamp" > "$SRC/.ytdlnis-patched"
    fi
}

# Fails if the binary links anything but Android system libs, has text relocations (rejected by the
# Android linker) or a LOAD segment aligned below 16 KB on a 64-bit ABI.
verify_binary() {
    local bin="$1" abi="$2" n bad=0 align
    while IFS= read -r n; do
        case " $SYS_LIBS " in *" $n "*) ;; *) printf '    unexpected DT_NEEDED: %s\n' "$n" >&2; bad=1 ;; esac
    done < <("$READELF" -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    if "$READELF" -d "$bin" | grep -q 'TEXTREL'; then
        printf '    binary has text relocations\n' >&2; bad=1
    fi
    case "$abi" in arm64-v8a|x86_64)
        while IFS= read -r align; do
            if [ $((align)) -lt "$ELF_PAGE_SIZE" ]; then printf '    LOAD segment aligned to %s\n' "$align" >&2; bad=1; fi
        done < <("$READELF" -lW "$bin" | awk '$1 == "LOAD" { print $NF }')
    esac
    [ "$bad" = 0 ] || return 1
    info "verify OK -- static (needs only: $("$READELF" -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' '))"
}

########################  BUILD  ########################
check_prereqs
mkdir -p "$WORK" "$JNI_DIR"

if [ "$#" -gt 0 ]; then
    ARCHITECTURES=("$@")
    for a in "${ARCHITECTURES[@]}"; do
        in_list "$a" "${ALL_ARCHES[@]}" || die "unknown arch '$a' (valid: ${ALL_ARCHES[*]})"
    done
else
    ARCHITECTURES=("${ALL_ARCHES[@]}")
fi
log "aria2-next ${ARIA2_VERSION} for: ${ARCHITECTURES[*]}   (NDK $(basename "$NDK"), API $ANDROID_API)"

fetch_source

# Upstream's release flags (-Os, function/data sections, --gc-sections). release-size-profile reads
# the commit date from git, which a tarball doesn't have.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(stat -c %Y "$SRC/CMakeLists.txt")}"
export GITHUB_WORKSPACE="$SRC" # path prefix stripped from __FILE__ strings
# shellcheck disable=SC1091
. "$SRC/packaging/scripts/release-size-profile" android
RELEASE_LDFLAGS="$RELEASE_LDFLAGS -Wl,-z,max-page-size=$ELF_PAGE_SIZE"

failed=()
for ARCH in "${ARCHITECTURES[@]}"; do
    ABI="$(android_abi "$ARCH")"
    BUILD="${WORK}/build-${ABI}"
    log "Building aria2-next for: $ARCH ($ABI)"
    [ "$CLEAN" = "1" ] && rm -rf "$BUILD"

    if ! (
        cd "$SRC"
        cmake -S . -B "$BUILD" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            "-DCMAKE_C_FLAGS=$RELEASE_CFLAGS" \
            "-DCMAKE_CXX_FLAGS=$RELEASE_CXXFLAGS" \
            "-DCMAKE_EXE_LINKER_FLAGS=$RELEASE_LDFLAGS" \
            -DARIA2_RELEASE_SIZE_OPTIMIZED=ON \
            -DARIA2_RELEASE_LTO=ON \
            -DBUILD_TESTING=OFF \
            -DCMAKE_SKIP_RPATH=ON \
            -DCMAKE_SYSTEM_NAME=Android \
            "-DCMAKE_ANDROID_NDK=$NDK" \
            "-DCMAKE_ANDROID_ARCH_ABI=$ABI" \
            -DCMAKE_ANDROID_STL_TYPE=c++_static \
            "-DCMAKE_SYSTEM_VERSION=$ANDROID_API" &&
        cmake --build "$BUILD" --target aria2_project -j"$(nproc)"
    ); then
        failed+=("$ARCH (build)"); continue
    fi

    BIN="$BUILD/aria2-next"
    [ -f "$BIN" ] || { failed+=("$ARCH (no binary)"); continue; }
    "$STRIP" --strip-all "$BIN"
    if ! verify_binary "$BIN" "$ABI"; then failed+=("$ARCH (verify)"); continue; fi

    dest="${JNI_DIR}/${ABI}"
    mkdir -p "$dest"
    cp "$BIN" "$dest/libaria2c.so"
    chmod 755 "$dest/libaria2c.so"
    info "wrote $dest/libaria2c.so"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    n="$(android_abi "$ARCH")"
    [ -f "${JNI_DIR}/${n}/libaria2c.so" ] && info "$n : libaria2c.so ($(du -h "${JNI_DIR}/${n}/libaria2c.so" | cut -f1))"
done
[ "${#failed[@]}" -eq 0 ] || die "failed: ${failed[*]}"
