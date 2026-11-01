#!/bin/bash
#
# Build deno (termux) for Android and pack it into the libdeno.so /
# libdeno.zip.so JNI layout used by YTDLnis.
#
# Output:  ./output/jniLibs/<android-abi>/{libdeno.so,libdeno.zip.so}
#
set -euo pipefail
shopt -s nullglob

############################  CONFIG  ############################

ALL_ARCHES=("aarch64" "x86_64")
SKIP_BUILD="${SKIP_BUILD:-0}"

PKG="deno"
BIN_NAME="deno"
LIB_PREFIX="libdeno"

USE_ANDROID_ABI_NAMES=true
OUTPUT_BASE_DIR="${PWD}/output"
JNI_DIR="${OUTPUT_BASE_DIR}/jniLibs"
# Scratch dir for unpacking/patching. Must be on the container's own filesystem: on a bind-mounted
# Windows/macOS checkout (Docker Desktop) tar fails with "Directory renamed before its status could
# be extracted" and symlinks/patchelf are unreliable. Only the final artifacts go to output/.
WORK="${WORK_DIR:-/tmp/ytdlnis-work}/deno"

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

# ------------------------------------------------------------------------------------------------
# Shared-library isolation + .deb selection. KEEP IDENTICAL in build_node.sh, build_python.sh,
# build_ffmpeg.sh and build-deno.sh.
#
# The app puts every package's usr/lib on ONE LD_LIBRARY_PATH. Each bundle ships its own copy of
# common libs (libffi.so, libssl.so.3, libz.so.1, ...), built at different times, and the linker
# takes the first file with a matching name -- so the package listed first decides the version for
# everyone (node failed with "cannot locate symbol ffi_call_plan_free" because python's older
# libffi.so won). isolate_libs gives every bundled lib a package-unique SONAME
# (libffi.so -> libffi_<tag>.so) and rewrites DT_NEEDED in every ELF of the bundle to match, so a
# bundle can never resolve another bundle's libs and the package order in the app stops mattering.
# The old name stays as a symlink to the renamed lib, for code that dlopen()s by name and for native
# wheels / addons installed later that still link against the plain name.
# ------------------------------------------------------------------------------------------------
ELF_PAGE_SIZE=16384 # patchelf segment alignment: 16 KB also works on 4 KB devices, required on 16 KB ones

is_elf() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

# libssl.so.3 -> libssl_<tag>.so.3
tag_soname() { printf '%s_%s.so%s' "${1%%.so*}" "$2" "${1#*.so}"; }

# isolate_libs <usr-dir> <tag> [regex of sonames to leave untouched]
isolate_libs() {
    local usr="$1" tag="$2" keep="${3:-}" lib="$1/lib" f soname new n base patched=0
    local -A map=() renamed=() links=()
    local args=()

    # 0. remember which real file every usr/lib symlink points at. A lib without a SONAME (libsqlite)
    #    is linked by the symlink's name (DT_NEEDED libsqlite3.so), so that name has to follow the rename.
    while IFS= read -r f; do
        links["$(basename "$f")"]="$(basename "$(readlink -f "$f")")"
    done < <(find "$lib" -maxdepth 1 -type l -name '*.so*')

    # 1. rename every real shared library in usr/lib to its tagged soname
    while IFS= read -r f; do
        is_elf "$f" || continue
        base="$(basename "$f")"
        soname="$(patchelf --print-soname "$f" 2>/dev/null || true)"
        [ -n "$soname" ] || soname="$(basename "$f")"
        case "$soname" in *.so|*.so.*) ;; *) continue ;; esac
        case "$soname" in *_"$tag".so*) continue ;; esac # already isolated
        if [ -n "$keep" ] && [[ "$soname" =~ $keep ]]; then continue; fi
        if [ -n "${map[$soname]:-}" ]; then
            info "isolate: $(basename "$f") has the same soname as another lib ($soname), left as is"
            continue
        fi
        new="$(tag_soname "$soname" "$tag")"
        patchelf --page-size "$ELF_PAGE_SIZE" --set-soname "$new" "$f"
        mv "$f" "$lib/$new"
        map["$soname"]="$new"
        renamed["$base"]="$new"
    done < <(find "$lib" -maxdepth 1 -type f -name '*.so*')

    # 1b. symlink names of a renamed lib (libsqlite3.so -> libsqlite3.so.3.54.1) map to it as well
    for n in "${!links[@]}"; do
        if [ -z "${map[$n]:-}" ] && [ -n "${links[$n]}" ] && [ -n "${renamed[${links[$n]}]:-}" ]; then
            map["$n"]="${renamed[${links[$n]}]}"
        fi
    done

    # 2. the old symlinks (libfoo.so -> libfoo.so.1) now dangle: drop them, point the old sonames at the renamed files
    find "$lib" -maxdepth 1 -xtype l -delete
    for soname in "${!map[@]}"; do
        [ -e "$lib/$soname" ] || ln -s "${map[$soname]}" "$lib/$soname"
    done

    # 3. rewrite DT_NEEDED in every ELF of the bundle (binaries, libs, python extensions, node addons, openssl modules)
    while IFS= read -r f; do
        is_elf "$f" || continue
        args=()
        while IFS= read -r n; do
            if [ -n "$n" ] && [ -n "${map[$n]:-}" ]; then args+=(--replace-needed "$n" "${map[$n]}"); fi
        done < <(patchelf --print-needed "$f" 2>/dev/null || true)
        if [ "${#args[@]}" -gt 0 ]; then
            patchelf --page-size "$ELF_PAGE_SIZE" "${args[@]}" "$f"
            patched=$((patched + 1))
        fi
    done < <(find "$usr" -type f \( -path "$usr/bin/*" -o -name '*.so' -o -name '*.so.*' -o -name '*.node' \))

    info "isolate: renamed ${#renamed[@]} libs to *_${tag}.so*, rewrote DT_NEEDED in $patched files"
}

# Print one .deb per package (its highest version) from an arch output dir. Rebuilding for a newer
# version leaves the old .deb next to the new one, and unpacking both lets the glob order decide
# whose files win (for python that even means picking the old python3.x dir).
latest_debs() {
    local dir="$1" arch="$2" deb pkg ver
    local -A best=() bestver=()
    for deb in "$dir"/*_"$arch".deb "$dir"/*_all.deb; do
        pkg="$(dpkg-deb -f "$deb" Package)"
        ver="$(dpkg-deb -f "$deb" Version)"
        if [ -z "${best[$pkg]:-}" ] || dpkg --compare-versions "$ver" gt "${bestver[$pkg]}"; then
            best["$pkg"]="$deb"
            bestver["$pkg"]="$ver"
        fi
    done
    for pkg in "${!best[@]}"; do printf '%s\n' "${best[$pkg]}"; done | sort
}
# ------------------------------------------------------------------------------------------------

# Shared libs the Android system provides; everything else NEEDED must be bundled.
SYSTEM_LIBS="libc.so libm.so libdl.so liblog.so libandroid.so libz.so"

check_prereqs() {
    [ -x ./build-package.sh ] || die "build-package.sh not found. Run this from the termux-packages root."
    for t in zip dpkg dpkg-deb patchelf; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found on PATH."
    done
    ensure_llvm_strip
}

# The builder image only ships versioned llvm tools (llvm-strip-N), so install llvm if needed.
ensure_llvm_strip() {
    command -v llvm-strip >/dev/null 2>&1 && return 0
    log "llvm-strip not found, installing llvm"
    local sudo=""
    [ "$(id -u)" -eq 0 ] || sudo="sudo"
    $sudo apt-get update && $sudo apt-get install -y llvm || die "could not install llvm (needed for llvm-strip)."
    command -v llvm-strip >/dev/null 2>&1 || die "llvm installed but llvm-strip still not on PATH."
}

########################  PHASE 0  ########################
check_prereqs
mkdir -p "$WORK" "$JNI_DIR"

if [ "$#" -gt 0 ]; then
    ARCHITECTURES=("$@")
    for a in "${ARCHITECTURES[@]}"; do
        in_list "$a" "${ALL_ARCHES[@]}" || die "unknown/unsupported arch '$a' for deno (valid: ${ALL_ARCHES[*]})"
    done
else
    ARCHITECTURES=("${ALL_ARCHES[@]}")
fi
log "Target arches: ${ARCHITECTURES[*]}   (SKIP_BUILD=${SKIP_BUILD})"

if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1 -> skipping the builds, reusing existing .debs in output/<arch>/"
fi

# Each arch is built AND packaged before the next one starts, so a finished arch can be
# tested while the others are still building (and a packaging error shows up early).
for ARCH in "${ARCHITECTURES[@]}"; do
    ########################  PHASE 1 - build  ########################
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    if [ "$SKIP_BUILD" != "1" ]; then
        log "Building $PKG for: $ARCH"
        ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "$PKG" \
            || die "build failed for $ARCH"

        find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \
            \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) \
            -exec mv -t "$OUTPUT_DIR/" {} + 2>/dev/null || true
        info "built: $ARCH"
    fi

    ########################  PHASE 2 - merge & optimize JNI zip  ########################
    log "Packaging JNI libs for: $ARCH"
    EX="${WORK}/extract-${ARCH}"
    rm -rf "$EX"; mkdir -p "$EX"

    # 1. Unpack non-static .deb packages
    while IFS= read -r deb; do
        base="$(basename "$deb")"
        case "$base" in
            *-static_*.deb|*-dev_*.deb) continue ;;
        esac
        info "unpack $base"
        dpkg-deb -x "$deb" "$EX"
    done < <(latest_debs "${OUTPUT_BASE_DIR}/${ARCH}" "$ARCH")

    FILES_DIR="${EX}/data/data/com.termux/files"
    USR="${FILES_DIR}/usr"
    [ -f "${USR}/bin/${BIN_NAME}" ] || die "usr/bin/${BIN_NAME} not found for $ARCH (build incomplete)"

    if $USE_ANDROID_ABI_NAMES; then OUT_NAME="$(android_abi "$ARCH")"; else OUT_NAME="$ARCH"; fi
    dest="${JNI_DIR}/${OUT_NAME}"
    mkdir -p "$dest"

    # 2. Aggressive Cleanup of Non-Essential Files
    info "Pruning unnecessary files and assets..."
    rm -rf "${USR}/share/doc" \
           "${USR}/share/man" \
           "${USR}/share/info" \
           "${USR}/share/locale" \
           "${USR}/share/gtk-doc" \
           "${USR}/include" \
           "${USR}/lib/pkgconfig" \
           "${USR}/lib/cmake"
           
    # Remove all development archives (.a files) accidentally packed in non-static packages
    find "${USR}" -type f -name "*.a" -delete

    # 3. Strip Symbols from Binaries and Dynamic Libraries (.so files)
    info "Stripping symbols from executable and shared objects..."
    llvm-strip --strip-unneeded "${USR}/bin/${BIN_NAME}" 2>/dev/null || true

    find "${USR}/lib" -type f -name "*.so*" -exec llvm-strip --strip-unneeded {} \; 2>/dev/null || true

    # 3b. Package-unique library names. After stripping: strip rewrites the files patchelf just laid out.
    isolate_libs "$USR" deno

    # 3c. Every DT_NEEDED of deno and its libs must be bundled (or be an Android system lib).
    missing=()
    while IFS= read -r f; do
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            case " $SYSTEM_LIBS " in *" $n "*) continue ;; esac
            [ -e "${USR}/lib/$n" ] || missing+=("$n (needed by $(basename "$f"))")
        done < <(patchelf --print-needed "$f" 2>/dev/null || true)
    done < <(find "${USR}/bin" "${USR}/lib" -maxdepth 1 -type f \( -path "${USR}/bin/*" -o -name '*.so' -o -name '*.so.*' \))
    [ "${#missing[@]}" -eq 0 ] || die "libraries needed by deno but not in the bundle for $ARCH: $(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')"

    # 4. Copy stripped executable to target
    cp "${USR}/bin/${BIN_NAME}" "${dest}/${LIB_PREFIX}.so"

    # 5. Pack into maximum-compression ZIP archive
    tmp_zip="${WORK}/${LIB_PREFIX}.zip"
    rm -f "$tmp_zip"
    zdirs=()
    for d in lib etc share; do [ -d "${USR}/${d}" ] && zdirs+=("usr/${d}"); done

    info "Compressing runtime environment with maximum zip compression (-9)..."
    ( cd "$FILES_DIR" && zip -9 --symlinks -qr "$tmp_zip" "${zdirs[@]}" )
    mv "$tmp_zip" "${dest}/${LIB_PREFIX}.zip.so"

    info "wrote ${dest}/{${LIB_PREFIX}.so,${LIB_PREFIX}.zip.so}"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    if $USE_ANDROID_ABI_NAMES; then n="$(android_abi "$ARCH")"; else n="$ARCH"; fi
    info "$n : $(ls -1 "${JNI_DIR}/${n}" 2>/dev/null | tr '\n' ' ')"
done