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
WORK="${OUTPUT_BASE_DIR}/_work"

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
    local usr="$1" tag="$2" keep="${3:-}" lib="$1/lib" f soname new n patched=0
    local -A map=()
    local args=()

    # 1. rename every real shared library in usr/lib to its tagged soname
    while IFS= read -r f; do
        is_elf "$f" || continue
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
    done < <(find "$lib" -maxdepth 1 -type f -name '*.so*')

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

    info "isolate: renamed ${#map[@]} libs to *_${tag}.so*, rewrote DT_NEEDED in $patched files"
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

check_prereqs() {
    [ -x ./build-package.sh ] || die "build-package.sh not found. Run this from the termux-packages root."
    for t in zip dpkg dpkg-deb llvm-strip patchelf; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found on PATH."
    done
}

########################  PHASE 0  ########################
check_prereqs
mkdir -p "$WORK" "$JNI_DIR"

sed -i 's/4e6131cc859ec6a36569f1978cf3617cc3836a681d13d228ded1b4885dab7770/9b9568ec5a9ff728f49c77d73644e7691fe386956e2d9acbdef0fc590e5828c8/' x11-packages/foot/build.sh 2>/dev/null || true

if [ "$#" -gt 0 ]; then
    ARCHITECTURES=("$@")
    for a in "${ARCHITECTURES[@]}"; do
        in_list "$a" "${ALL_ARCHES[@]}" || die "unknown/unsupported arch '$a' for deno (valid: ${ALL_ARCHES[*]})"
    done
else
    ARCHITECTURES=("${ALL_ARCHES[@]}")
fi
log "Target arches: ${ARCHITECTURES[*]}   (SKIP_BUILD=${SKIP_BUILD})"

########################  PHASE 1 - build per arch  ########################
if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1 -> skipping Phase 1, reusing existing .debs in output/<arch>/"
fi
for ARCH in "${ARCHITECTURES[@]}"; do
    if [ "$SKIP_BUILD" = "1" ]; then continue; fi
    log "Building $PKG for: $ARCH"
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "$PKG" \
        || die "build failed for $ARCH"

    find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \
        \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) \
        -exec mv -t "$OUTPUT_DIR/" {} + 2>/dev/null || true

    info "done: $ARCH"
done

########################  PHASE 2 - merge & optimize JNI zip  ########################
for ARCH in "${ARCHITECTURES[@]}"; do
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
    llvm-strip --strip-unneeded "${USR}/bin/${BIN_NAME}" 2>/dev/null || strip --strip-unneeded "${USR}/bin/${BIN_NAME}" 2>/dev/null || true
    
    find "${USR}/lib" -type f -name "*.so*" -exec \
        sh -c 'llvm-strip --strip-unneeded "$1" 2>/dev/null || strip --strip-unneeded "$1" 2>/dev/null || true' _ {} \;

    # 3b. Package-unique library names. After stripping: strip rewrites the files patchelf just laid out.
    isolate_libs "$USR" deno

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