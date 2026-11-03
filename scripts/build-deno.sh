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

# 1 = shrink the bundle (0 = package everything, as before): drop libs deno can't load (other packages
# built in the same container: python, ffmpeg's codecs, ...) and strip debug symbols.
SHRINK_BUNDLE="${SHRINK_BUNDLE:-1}"

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
# Bundle shrinking, used when SHRINK_BUNDLE=1 (top of each script). KEEP IDENTICAL as well.
#
# prune_dev_files    headers, docs, man pages, translations, static archives: never read at runtime.
# prune_unused_libs  output/<arch> holds the .debs of EVERY package built in this container (python,
#                    ffmpeg, node, deno and all their deps) and every script unpacks all of them, so a
#                    bundle carried whatever else had been built before it. This keeps only what the
#                    bundle's own programs can load: the DT_NEEDED closure of the given roots and of the
#                    kept usr/lib subdirs. A program can't load a lib outside that closure, except by
#                    dlopen()ing it by name (list those in the keep-libs regex), so no feature is lost.
# strip_elfs         drops debug info and symbol tables, the code itself is untouched.
# ------------------------------------------------------------------------------------------------
du_k() { du -sk "$1" 2>/dev/null | cut -f1; }

find_llvm_strip() {
    local s="" c
    for c in "$(command -v llvm-strip 2>/dev/null || true)" \
             "${NDK:-/nonexistent}"/toolchains/llvm/prebuilt/*/bin/llvm-strip \
             "$HOME"/lib/android-ndk*/toolchains/llvm/prebuilt/*/bin/llvm-strip \
             "$(compgen -c llvm-strip- 2>/dev/null | sort -V | tail -1 || true)"; do
        [ -n "$c" ] || continue
        c="$(command -v "$c" 2>/dev/null || true)"   # bare names from compgen -> full path
        if [ -n "$c" ] && [ -x "$c" ]; then s="$c"; break; fi
    done
    printf '%s' "$s"
}

prune_dev_files() {
    local usr="$1"
    rm -rf "$usr/include" "$usr/lib/pkgconfig" "$usr/lib/cmake" \
           "$usr/share/doc" "$usr/share/man" "$usr/share/info" "$usr/share/locale" "$usr/share/gtk-doc"
    find "$usr" -type f \( -name '*.a' -o -name '*.la' \) -delete
}

# keep_only <dir> <regex>: delete every entry of <dir> whose name doesn't match
keep_only() {
    local dir="$1" re="$2" e
    [ -d "$dir" ] || return 0
    for e in "$dir"/* "$dir"/.[!.]*; do
        [[ "$(basename "$e")" =~ $re ]] || rm -rf "$e"
    done
}

# prune_unused_libs <usr> <keep-subdirs-regex> <keep-libs-regex> <root>...
#   roots: the bundle's programs (files, or dirs searched for ELFs).
#   keep-subdirs-regex: usr/lib subdirs to keep (their ELFs become roots too), every other subdir goes.
#   keep-libs-regex: usr/lib libs to keep although nothing links them (dlopen by name), '' for none.
prune_unused_libs() {
    local usr="$1" keep_dirs="$2" keep_libs="$3" lib="$1/lib" f n real d removed=0
    shift 3
    local -A keep=() seen=()
    local roots=("$@") queue=()

    while IFS= read -r d; do
        if [[ "$(basename "$d")" =~ $keep_dirs ]]; then roots+=("$d"); else rm -rf "$d"; fi
    done < <(find "$lib" -mindepth 1 -maxdepth 1 -type d)

    while IFS= read -r f; do
        is_elf "$f" && queue+=("$f")
    done < <(find "${roots[@]}" -type f 2>/dev/null)
    if [ -n "$keep_libs" ]; then
        while IFS= read -r f; do
            n="$(basename "$f")"
            if [[ "$n" =~ $keep_libs ]] && is_elf "$f"; then keep["$n"]=1; queue+=("$f"); fi
        done < <(find "$lib" -maxdepth 1 -type f -name '*.so*')
    fi

    # walk DT_NEEDED: a needed name is usr/lib/<name>, often a symlink to the real file
    while [ "${#queue[@]}" -gt 0 ]; do
        f="${queue[0]}"; queue=("${queue[@]:1}")
        [ -z "${seen[$f]:-}" ] || continue
        seen["$f"]=1
        while IFS= read -r n; do
            [ -n "$n" ] && [ -e "$lib/$n" ] || continue
            real="$(readlink -f "$lib/$n")"
            keep["$n"]=1
            keep["$(basename "$real")"]=1
            queue+=("$real")
        done < <(patchelf --print-needed "$f" 2>/dev/null || true)
    done

    # drop the libs nothing reaches. Symlinks to a kept lib stay (other names it may be dlopen()ed by),
    # non-ELF files are left alone.
    while IFS= read -r f; do
        n="$(basename "$f")"
        if [ -L "$f" ]; then
            [ -z "${keep[$(basename "$(readlink -f "$f")")]:-}" ] || continue
        else
            is_elf "$f" || continue
            [ -z "${keep[$n]:-}" ] || continue
        fi
        rm -f "$f"
        removed=$((removed + 1))
    done < <(find "$lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*')
    find "$lib" -maxdepth 1 -xtype l -delete
    info "prune: removed $removed unused libs from usr/lib"
}

strip_elfs() {
    local usr="$1" s f n=0
    s="$(find_llvm_strip)"
    if [ -z "$s" ]; then
        info "strip: llvm-strip not found, skipped"
        return 0
    fi
    while IFS= read -r f; do
        is_elf "$f" || continue
        if "$s" --strip-unneeded "$f" </dev/null 2>/dev/null; then n=$((n + 1)); fi
    done < <(find "$usr" -type f)
    info "strip: stripped $n ELF files ($(basename "$s"))"
}

# shrink_bundle <usr> <keep-subdirs-regex> <keep-libs-regex> <root>...
#   Run before isolate_libs: it works on the plain lib names, and strip rewrites what patchelf lays out.
shrink_bundle() {
    local usr="$1" before
    before="$(du_k "$usr")"
    prune_dev_files "$usr"
    prune_unused_libs "$@"
    strip_elfs "$usr"
    info "shrink: usr ${before}K -> $(du_k "$usr")K"
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

    # 2b. Drop libs deno can't load.
    if [ "$SHRINK_BUNDLE" = "1" ]; then
        shrink_bundle "$USR" '^(ossl-modules|engines-3)$' '' "${USR}/bin/${BIN_NAME}"
    fi

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
    done < <(echo "${USR}/bin/${BIN_NAME}"; find "${USR}/lib" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \))   # only what ships: other bin/ tools aren't packaged
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
    info "$n : $(cd "${JNI_DIR}/${n}" 2>/dev/null && du -h -- * | awk '{printf "%s (%s)  ", $2, $1}')"
done