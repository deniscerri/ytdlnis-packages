#!/bin/bash
#
# Build Python (latest, 3.14.x) for Android with the termux build system,
# bundle a set of Python packages into site-packages, and pack everything into
# the libpython.so / libpython.zip.so JNI layout used by YTDLnis.
#
# RUN THIS FROM THE ROOT OF A termux-packages CHECKOUT, INSIDE the docker
# container (start it with ./scripts/run-docker.sh, then run ./build_python.sh).
# It expects, in the current dir: build-package.sh and packages/ .
#
# Output goes to  ./output/jniLibs/<android-abi>/{libpython.so,libpython.zip.so}
#
# Bundled packages:
#   native, all arches : python-pycryptodomex, python-brotli   (cross-compiled)
#   native, arm64 only : python-cffi                            (cross-compiled)
#   wheel,  arm64 only : curl-cffi  (prebuilt cp314 android wheel)
#   pure-python, all   : requests certifi charset-normalizer idna urllib3
#                        websockets mutagen pycparser
#
set -euo pipefail
shopt -s nullglob

#
# USAGE (termux arch names):
#   ./build_python.sh                      # build all four arches
#   ./build_python.sh aarch64              # only arm64 (one CI job)
#   ./build_python.sh aarch64 x86_64       # a subset
#   SKIP_BUILD=1 ./build_python.sh aarch64 # skip Phase 1 (reuse existing .debs),
#                                            just re-fetch wheels + re-pack the zip
#
############################  CONFIG  ############################

# Full set of supported arches. The ones actually built are chosen from the
# command line (see PHASE 0); with no args, all of these are built.
ALL_ARCHES=("aarch64" "arm" "i686" "x86_64")

# Set to 1 (or pass SKIP_BUILD=1 in the env) to skip Phase 1 and reuse the
# .debs already in output/<arch>/ -- handy when only tweaking the packaging.
SKIP_BUILD="${SKIP_BUILD:-0}"

# 1 = give python's libs package-unique names (isolate_libs, as the other bundles do).
# Off by default: ffmpeg builds from before isolate_libs (still installed by many users) don't
# bundle libandroid-posix-semaphore, libandroid-support, libc++_shared, libcrypto and libexpat and
# load python's copies by their plain names. Requires python's usr/lib to come before the isolated
# bundles on LD_LIBRARY_PATH (their plain names are symlinks to their own renamed libs).
ISOLATE="${ISOLATE:-0}"

# Arches that additionally get cffi + curl-cffi (curl-cffi only ships an arm64
# android wheel, and cffi is its native runtime dependency).
CURL_CFFI_ARCHES=("aarch64")

# Native python extension packages to build per arch (python itself is built first, see PHASE 1).
# These are always rebuilt (-f): a copy built against an older python in a reused container would
# otherwise be skipped and install into the old python3.x dir.
NATIVE_PKGS=("python-pycryptodomex" "python-brotli")
# Extra native package built only for the CURL_CFFI_ARCHES (recipe: packages/python-cffi).
NATIVE_PKGS_CURLCFFI=("python-cffi")

# NOTE: we deliberately do NOT hand-list which .debs to bundle. Phase 3 unpacks
# EVERY runtime .deb that build-package.sh staged for the arch (python + its full
# dependency closure + the python-* extension packages), excluding only "-static"
# dev packages. This guarantees every backing library the stdlib C extensions
# dlopen is present -- libexpat (pyexpat), libsqlite (sqlite3), liblzma, libbz2,
# gdbm, libcrypt, ncurses, zstd, ... -- instead of a subset that silently drops one.

# Pure-python packages, pinned  ->  "<pypi-name>:<version>". These are fetched
# as their -none-any.whl wheels and are architecture independent.
PURE_PKGS=(
    "requests:2.34.2"
    "certifi:2026.10.23"
    "charset-normalizer:3.5.2"
    "idna:3.20"
    "urllib3:2.8.0"
    "websockets:17.3"
    "mutagen:1.48.1"
    "pycparser:3.12"     # runtime dep of cffi
)

# Prebuilt curl-cffi android wheel (arm64 / aarch64 only). The cp tag must match the python
# recipe's x.y (packages/python/build.sh); curl-cffi 0.16.x needs cffi >= 2.0.0.
CURL_CFFI_VERSION="0.17.0"
CURL_CFFI_WHEEL="curl_cffi-${CURL_CFFI_VERSION}-cp314-cp314-android_24_arm64_v8a.whl"
CURL_CFFI_URL="https://github.com/lexiforest/curl_cffi/releases/download/v${CURL_CFFI_VERSION}/${CURL_CFFI_WHEEL}"
CURL_CFFI_SHA256="0d85bec9648bf7c14c3b43056ba82521740f72cd96ed7700a0e1973e7fc93f74"

# Name the jniLibs folders with Android ABI names (arm64-v8a / armeabi-v7a /
# x86 / x86_64) so they can be dropped straight into the app's jniLibs.
USE_ANDROID_ABI_NAMES=true

OUTPUT_BASE_DIR="${PWD}/output"
JNI_DIR="${OUTPUT_BASE_DIR}/jniLibs"
# Scratch dir for unpacking/patching. Must be on the container's own filesystem: on a bind-mounted
# Windows/macOS checkout (Docker Desktop) tar fails with "Directory renamed before its status could
# be extracted" and symlinks/patchelf are unreliable. Only the final artifacts go to output/.
WORK="${WORK_DIR:-/tmp/ytdlnis-work}/python"
PURE_SITE="${WORK}/pure-site"          # shared, arch independent
CURLCFFI_SITE="${WORK}/curl-cffi-site" # arm64 only

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

check_prereqs() {
    [ -x ./build-package.sh ] || die "build-package.sh not found. Run this from the termux-packages root."
    for t in curl unzip zip dpkg dpkg-deb python3 patchelf sha256sum; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found on PATH."
    done
}

# Safety net: if the curl-cffi wheel was built for a different python (e.g. an abi3 wheel built
# on 3.13), its DT_NEEDED names that libpython. On Android, extensions are hard-linked against
# libpython, so point it at the one we ship. No-op when the wheel's cp tag matches our python.
patch_curl_cffi_libpython() {
    local so="$1" pyver="$2"
    [ -f "$so" ] || return 0
    local cur
    cur="$(patchelf --print-needed "$so" | grep -E '^libpython3\.' | head -1 || true)"
    if [ -n "$cur" ] && [ "$cur" != "libpython${pyver}.so" ]; then
        info "patchelf: $cur -> libpython${pyver}.so  ($(basename "$so"))"
        patchelf --page-size "$ELF_PAGE_SIZE" --replace-needed "$cur" "libpython${pyver}.so" "$so"
    fi
}

# The python-cffi recipe lives in the tree (packages/python-cffi/build.sh). It is not generated
# here: the container's AppArmor profile forbids writing to the repo outside output/.
check_cffi_recipe() {
    [ -f "packages/python-cffi/build.sh" ] \
        || die "packages/python-cffi/build.sh not found (needed for curl-cffi)."
}

# Download a wheel (from a URL), verify its sha256 and unzip it into a site dir.
unpack_wheel_url() {
    local url="$1" site="$2" sha="$3"
    local file="${WORK}/$(basename "$url")"
    curl -fsSL "$url" -o "$file"
    echo "${sha}  ${file}" | sha256sum -c --quiet - || die "sha256 mismatch for $(basename "$url")"
    unzip -q -o "$file" -d "$site"
}

# Resolve a PyPI "name:version" to its -none-any.whl download URL (+ sha256) and unpack it.
fetch_pure_pkg() {
    local entry="$1" site="$2"
    local name="${entry%%:*}" ver="${entry##*:}"
    info "pure  $name==$ver"
    local url sha
    read -r url sha < <(curl -fsSL "https://pypi.org/pypi/${name}/${ver}/json" \
        | python3 -c "import sys,json;d=json.load(sys.stdin);u=next(u for u in d['urls'] if u['filename'].endswith('-none-any.whl'));print(u['url'],u['digests']['sha256'])") \
        || die "could not resolve a pure wheel for ${name}==${ver}"
    sha="${sha%$'\r'}"
    [ -n "$sha" ] || die "could not resolve a pure wheel for ${name}==${ver}"
    unpack_wheel_url "$url" "$site" "$sha"
}

########################  PHASE 0  ########################
check_prereqs
check_cffi_recipe
mkdir -p "$WORK" "$JNI_DIR"

# Select arches from the command line, defaulting to all of them.
if [ "$#" -gt 0 ]; then
    ARCHITECTURES=("$@")
    for a in "${ARCHITECTURES[@]}"; do
        in_list "$a" "${ALL_ARCHES[@]}" || die "unknown arch '$a' (valid: ${ALL_ARCHES[*]})"
    done
else
    ARCHITECTURES=("${ALL_ARCHES[@]}")
fi
log "Target arches: ${ARCHITECTURES[*]}   (SKIP_BUILD=${SKIP_BUILD})"

########################  PHASE 1 - build native packages per arch  ########################
if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1 -> skipping the builds, reusing existing .debs in output/<arch>/"
fi

########################  PHASE 1 - fetch pure + curl-cffi wheels (once)  ########################
# Done first: it takes seconds, and a bad pin / checksum should fail before hours of building.
log "Fetching pure-python wheels"
rm -rf "$PURE_SITE"; mkdir -p "$PURE_SITE"
for entry in "${PURE_PKGS[@]}"; do
    fetch_pure_pkg "$entry" "$PURE_SITE"
done

log "Fetching curl-cffi android wheel"
rm -rf "$CURLCFFI_SITE"; mkdir -p "$CURLCFFI_SITE"
info "$CURL_CFFI_WHEEL"
unpack_wheel_url "$CURL_CFFI_URL" "$CURLCFFI_SITE" "$CURL_CFFI_SHA256"

# Each arch is built AND packaged before the next one starts, so a finished arch can be
# tested while the others are still building (and a packaging error shows up early).
for ARCH in "${ARCHITECTURES[@]}"; do
    ########################  PHASE 2 - build native packages  ########################
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    if [ "$SKIP_BUILD" != "1" ]; then
        log "Building native packages for: $ARCH"
        pkgs=("${NATIVE_PKGS[@]}")
        if in_list "$ARCH" "${CURL_CFFI_ARCHES[@]}"; then
            pkgs+=("${NATIVE_PKGS_CURLCFFI[@]}")
        fi

        ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" python \
            || die "python build failed for $ARCH"
        info "extension packages (forced rebuild): ${pkgs[*]}"
        ./build-package.sh -f -a "$ARCH" -o "$OUTPUT_DIR" "${pkgs[@]}" \
            || die "build failed for $ARCH"

        # Defensive: collect debs that landed one level up -- but ONLY this arch's
        # (and arch-independent "_all") so we never pull another arch's debs in here.
        find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \
            \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) \
            -exec mv -t "$OUTPUT_DIR/" {} + 2>/dev/null || true
        info "built: $ARCH"
    fi

    ########################  PHASE 3 - merge into JNI zip  ########################
    log "Packaging JNI libs for: $ARCH"
    EX="${WORK}/extract-${ARCH}"
    rm -rf "$EX"; mkdir -p "$EX"

    curl_cffi_here=false
    if in_list "$ARCH" "${CURL_CFFI_ARCHES[@]}"; then
        curl_cffi_here=true
    fi

    # Unpack ALL of this arch's runtime .debs (+ arch-independent "_all"),
    # excluding "-static" dev packages. Matching only "_<arch>.deb"/"_all.deb"
    # keeps a stray wrong-arch .deb from contaminating the bundle; unpacking all
    # of them (rather than a hand-picked list) guarantees python's whole runtime
    # closure -- and every stdlib backing lib -- is present.
    got_python=false
    while IFS= read -r deb; do
        base="$(basename "$deb")"
        case "$base" in
            *-static_*.deb) continue ;;
        esac
        info "unpack $base"
        dpkg-deb -x "$deb" "$EX"
        case "$base" in python_*) got_python=true ;; esac
    done < <(latest_debs "${OUTPUT_BASE_DIR}/${ARCH}" "$ARCH")
    $got_python || die "python .deb not found for ${ARCH} (build incomplete)"

    # Warn loudly if a known-critical backing lib is missing.
    if ! compgen -G "${EX}/data/data/com.termux/files/usr/lib/libexpat.so*" >/dev/null; then
        info "WARNING: libexpat.so missing -> pyexpat/XML parsing will fail (Instagram, DASH). Was libexpat built?"
    fi

    PREFIX_DIR="${EX}/data/data/com.termux/files/usr"
    [ -d "$PREFIX_DIR" ] || die "unexpected extraction layout for $ARCH"

    # Detect the python x.y version dir. More than one means an extension .deb was built against
    # another python (stale .deb in output/<arch>/) and would be invisible to the interpreter.
    pydir=("$PREFIX_DIR"/lib/python3.*/)
    [ "${#pydir[@]}" -gt 0 ] || die "no python3.x lib dir found for $ARCH"
    [ "${#pydir[@]}" -eq 1 ] || die "several python lib dirs for $ARCH ($(for d in "${pydir[@]}"; do basename "$d"; done | tr '\n' ' ')): remove the stale .debs from output/${ARCH}/ and rebuild"
    pydir="${pydir[0]%/}"
    PYVER="$(basename "$pydir" | sed 's/^python//')"
    SITE="${pydir}/site-packages"
    mkdir -p "$SITE"
    info "python $PYVER  ->  site-packages"

    # Inject pure-python packages (all arches) and curl-cffi (arm64 only).
    cp -a "${PURE_SITE}/." "$SITE/"
    if $curl_cffi_here; then
        info "injecting curl-cffi (cffi is native, from python-cffi.deb)"
        cp -a "${CURLCFFI_SITE}/." "$SITE/"
        for so in "$SITE"/curl_cffi/_wrapper*.so; do patch_curl_cffi_libpython "$so" "$PYVER"; done
    fi

    # termux's python-pip replaces pip's vendored CA file with an absolute symlink to termux's
    # <prefix>/etc/tls/cert.pem, which doesn't exist inside the app (pip then fails every request
    # with FileNotFoundError). Give pip a real copy of the bundled certifi's CA file instead.
    pip_ca="${SITE}/pip/_vendor/certifi/cacert.pem"
    if [ -L "$pip_ca" ]; then
        [ -f "${SITE}/certifi/cacert.pem" ] || die "certifi/cacert.pem not found (is certifi still in PURE_PKGS?)"
        rm "$pip_ca"
        cp "${SITE}/certifi/cacert.pem" "$pip_ca"
        info "pip CA file -> copy of certifi's cacert.pem"
    fi

    # Prune build-only files from the zipped usr/lib (headers in usr/include are not zipped anyway).
    rm -rf "${PREFIX_DIR}/lib/pkgconfig" "${PREFIX_DIR}/lib/cmake" "${pydir}/test"
    find "${PREFIX_DIR}/lib" -type f -name '*.a' -delete

    # Sanity check: the interpreter binary must exist.
    PYBIN="${PREFIX_DIR}/bin/python${PYVER}"
    [ -f "$PYBIN" ] || die "python${PYVER} binary not found for $ARCH"

    # Package-unique library names. libpython keeps its name: native wheels pip installs
    # later on the device link against libpython3.x.so.
    if [ "$ISOLATE" = "1" ]; then
        isolate_libs "$PREFIX_DIR" python '^libpython'
    else
        info "isolate: off (ISOLATE=0), python's libs keep their plain names"
    fi

    # Every DT_NEEDED of the interpreter and its extension modules must now be bundled (or be an
    # Android system lib), otherwise a rename was missed and it would only show up on the device.
    # Wheels vendor their own libs next to the package (curl_cffi.libs/libc++_shared-<hash>.so) and
    # find them via RUNPATH $ORIGIN/../<pkg>.libs, so those count as bundled too.
    missing=()
    while IFS= read -r f; do
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            case " libc.so libm.so libdl.so liblog.so libandroid.so libz.so " in *" $n "*) continue ;; esac
            [ -e "${PREFIX_DIR}/lib/$n" ] && continue
            compgen -G "$(dirname "$f")/../*.libs/$n" >/dev/null && continue
            missing+=("$n (needed by ${f#"${PREFIX_DIR}/"})")
        done < <(patchelf --print-needed "$f" 2>/dev/null || true)
    done < <(find "${PREFIX_DIR}/bin" "${PREFIX_DIR}/lib" -type f \( -path "${PREFIX_DIR}/bin/*" -o -name '*.so' -o -name '*.so.*' \))
    [ "${#missing[@]}" -eq 0 ] || die "libraries needed by python but not in the bundle for $ARCH: $(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')"

    # No symlink in the zipped tree may point into termux's own prefix: inside the app that path
    # doesn't exist, so the link dangles and only fails on the device (like pip's CA file did).
    bad=()
    while IFS= read -r f; do
        tgt="$(readlink "$f")"
        case "$tgt" in /data/data/com.termux/*) bad+=("${f#"${PREFIX_DIR}/"} -> $tgt") ;; esac
    done < <(find "${PREFIX_DIR}/lib" "${PREFIX_DIR}/etc" -type l 2>/dev/null)
    [ "${#bad[@]}" -eq 0 ] || die "symlinks into the termux prefix (they would dangle in the app) for $ARCH: $(printf '%s\n' "${bad[@]}" | tr '\n' ' ')"

    # Build the two artifacts.
    tmp_so="${WORK}/libpython.so"
    tmp_zip="${WORK}/libpython.zip"
    rm -f "$tmp_so" "$tmp_zip"
    cp "$PYBIN" "$tmp_so"
    ( cd "${EX}/data/data/com.termux/files" && zip --symlinks -qr "$tmp_zip" usr/lib usr/etc )

    if $USE_ANDROID_ABI_NAMES; then OUT_NAME="$(android_abi "$ARCH")"; else OUT_NAME="$ARCH"; fi
    dest="${JNI_DIR}/${OUT_NAME}"
    mkdir -p "$dest"
    mv "$tmp_zip" "${dest}/libpython.zip.so"
    mv "$tmp_so"  "${dest}/libpython.so"
    info "wrote ${dest}/libpython.so  and  libpython.zip.so"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    if $USE_ANDROID_ABI_NAMES; then n="$(android_abi "$ARCH")"; else n="$ARCH"; fi
    info "$n : $(ls -1 "${JNI_DIR}/${n}" 2>/dev/null | tr '\n' ' ')"
done
