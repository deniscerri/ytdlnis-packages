#!/bin/bash
#
# Build nodejs + npm (termux) for Android and pack it into the libnode.so /
# libnode.zip.so JNI layout used by YTDLnis.
#
# RUN THIS FROM THE ROOT OF A termux-packages CHECKOUT, in two steps:
#   1. on the HOST:       PREP_ONLY=1 ./build_node.sh     (patches repo files)
#   2. in the container:  ./scripts/run-docker.sh ./build_node.sh [arch...]
# The container's AppArmor profile forbids writing to the repo (except output/),
# so the file edits must happen on the host.
#
# Output:  ./output/jniLibs/<android-abi>/{libnode.so,libnode.zip.so,manifest.json}
#
# WHY THIS SCRIPT DOES MORE THAN PACKING
# --------------------------------------
# Termux's node is built for the prefix /data/data/com.termux/files/usr and
# bakes that into the binary. Inside another app those paths don't exist, which
# is what turned into endless "permission" / ENOENT errors (deno has none of this:
# it is one self-contained binary that doesn't run install scripts). So besides
# packing, this script:
#   1. repoints the hardcoded child_process shell (termux: <prefix>/bin/sh) to
#      a shell that exists in the app (default /system/bin/sh),
#   2. ships a builtin npmrc with safe defaults (no install scripts, no
#      update-notifier, ...) -- the same defaults deno gives you for free,
#   3. audits the finished binary for leftover termux paths and for missing
#      shared libraries, and fails the build instead of shipping a broken bundle,
#   4. ships usr/share/ytdlnis/selftest.js to diagnose the remaining
#      device-specific problems in one run.

set -euo pipefail
shopt -s nullglob

#
# USAGE (termux arch names):
#   ./build_node.sh                      # all four arches
#   ./build_node.sh aarch64              # one arch (one CI job)
#   SKIP_BUILD=1 ./build_node.sh aarch64 # skip Phase 1, just re-pack existing .debs
#
# ENV:
#   NODE_SHELL=/system/bin/sh   shell node's child_process uses (exec, npm scripts)
#   ALLOW_MISSING_LIBS=1        only warn when a NEEDED shared lib isn't bundled
#
############################  CONFIG  ############################

ALL_ARCHES=("aarch64" "arm" "i686" "x86_64")
SKIP_BUILD="${SKIP_BUILD:-0}"
NODE_SHELL="${NODE_SHELL:-/system/bin/sh}"
ALLOW_MISSING_LIBS="${ALLOW_MISSING_LIBS:-0}"

PKGS=("nodejs" "npm") # termux packages to build (npm is separate since nodejs 25.3.0-1)
BIN_NAME="node"        # produced executable at usr/bin/<BIN_NAME>
LIB_PREFIX="libnode" # -> libnode.so (binary) + libnode.zip.so (usr/ tree)
TERMUX_USR="/data/data/com.termux/files/usr"

# Shared libs the Android system provides; everything else NEEDED must be bundled.
SYSTEM_LIBS=("libc.so" "libm.so" "libdl.so" "liblog.so" "libandroid.so")

USE_ANDROID_ABI_NAMES=true
OUTPUT_BASE_DIR="${PWD}/output"
JNI_DIR="${OUTPUT_BASE_DIR}/jniLibs"
WORK="${OUTPUT_BASE_DIR}/_work"

#################################################################

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[1;33m! %s\033[0m\n' "$*" >&2; }
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
    for t in zip dpkg dpkg-deb patchelf; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found on PATH."
    done
    READELF="$(command -v llvm-readelf || command -v readelf || true)"
    [ -n "$READELF" ] || warn "no readelf found: the shared-library check will be skipped."
    STRIP="$(command -v llvm-strip || command -v strip || true)"
}

# Point node's child_process shell at $NODE_SHELL instead of the termux prefix.
# The recipe applies lib-child_process.js.patch with @TERMUX_PREFIX@ substituted;
# editing the patch is the only change needed -- no node source to touch.
patch_termux_recipe() {
    local p="packages/nodejs/lib-child_process.js.patch"
    [ -f "$p" ] || die "$p not found: the termux nodejs recipe changed, update patch_termux_recipe()."

    if grep -q '@TERMUX_PREFIX@/bin/sh' "$p"; then
        sed -i "s|@TERMUX_PREFIX@/bin/sh|${NODE_SHELL}|" "$p"
        info "child_process shell -> ${NODE_SHELL}"
    elif grep -qF "file = '${NODE_SHELL}';" "$p"; then
        info "child_process shell already ${NODE_SHELL}"
    else
        die "could not find the shell line in $p (termux changed the patch). Fix patch_termux_recipe() or node will spawn a shell that doesn't exist."
    fi
}

# Print every NEEDED entry of an ELF file.
needed_libs() {
    "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'
}

# Edit tracked repo files. Must run on the HOST: the container's AppArmor profile
# (scripts/profile-restricted.apparmor) denies creating/writing files in the repo
# outside output/, which makes `sed -i` fail with "Permission denied".
prep_repo() {
    # Workaround: codeberg regenerated foot's 1.27.0 archive, drifting its sha256.
    # If ncurses is pulled into the tree it fetches foot's tarball for terminfo, so
    # the stale checksum in x11-packages/foot/build.sh breaks the build. Correct it.
    # Self-clears (no-op) once the pinned termux-packages updates the value.
    local foot="x11-packages/foot/build.sh"
    if [ -f "$foot" ] && grep -q '4e6131cc859ec6a36569f1978cf3617cc3836a681d13d228ded1b4885dab7770' "$foot"; then
        sed -i 's/4e6131cc859ec6a36569f1978cf3617cc3836a681d13d228ded1b4885dab7770/9b9568ec5a9ff728f49c77d73644e7691fe386956e2d9acbdef0fc590e5828c8/' "$foot"
        info "foot checksum fixed"
    fi
    patch_termux_recipe
}

########################  PHASE 0  ########################
if [ "${PREP_ONLY:-0}" = "1" ]; then
    log "Preparing repo (host-side edits only)"
    prep_repo
    log "Done. Now run: ./scripts/run-docker.sh ./build_node.sh [arch...]"
    exit 0
fi

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
log "Target arches: ${ARCHITECTURES[*]}   (SKIP_BUILD=${SKIP_BUILD}, NODE_SHELL=${NODE_SHELL})"

########################  PHASE 1 - build per arch  ########################
if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1 -> skipping Phase 1, reusing existing .debs in output/<arch>/"
else
    log "Checking termux recipe is patched (run PREP_ONLY=1 ./build_node.sh on the host first)"
    # No-op when already patched; only edits the file when run outside the container.
    patch_termux_recipe
fi
for ARCH in "${ARCHITECTURES[@]}"; do
    if [ "$SKIP_BUILD" = "1" ]; then continue; fi
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    for PKG in "${PKGS[@]}"; do
        log "Building $PKG for: $ARCH"
        # -f: rebuild even if termux thinks it is built, otherwise the recipe patch above is skipped.
        ./build-package.sh -f -a "$ARCH" -o "$OUTPUT_DIR" "$PKG" \
            || die "build failed for $PKG ($ARCH)"

        find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \
            \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) \
            -exec mv -t "$OUTPUT_DIR/" {} + 2>/dev/null || true
    done

    info "done: $ARCH"
done

########################  PHASE 2 - merge, fix, verify, pack  ########################
for ARCH in "${ARCHITECTURES[@]}"; do
    log "Packaging JNI libs for: $ARCH"
    EX="${WORK}/extract-${ARCH}"
    rm -rf "$EX"; mkdir -p "$EX"

    # 1. Unpack ALL of this arch's runtime .debs (+ "_all"), excluding -static/-dev.
    NODE_DEB_VERSION=""
    while IFS= read -r deb; do
        base="$(basename "$deb")"
        case "$base" in
            *-static_*.deb|*-dev_*.deb) continue ;;
            nodejs_*.deb) NODE_DEB_VERSION="$(dpkg-deb -f "$deb" Version)" ;;
        esac
        info "unpack $base"
        dpkg-deb -x "$deb" "$EX"
    done < <(latest_debs "${OUTPUT_BASE_DIR}/${ARCH}" "$ARCH")

    FILES_DIR="${EX}/data/data/com.termux/files"
    USR="${FILES_DIR}/usr"
    [ -f "${USR}/bin/${BIN_NAME}" ] || die "usr/bin/${BIN_NAME} not found for $ARCH (build incomplete)"

    # 2. npm: ships as its own package, make sure it really is in the bundle.
    NPM_CLI_REL="lib/node_modules/npm/bin/npm-cli.js"
    NPX_CLI_REL="lib/node_modules/npm/bin/npx-cli.js"
    NPM_DIR="${USR}/lib/node_modules/npm"
    [ -f "${USR}/${NPM_CLI_REL}" ] || die "npm-cli.js not found for $ARCH (expected usr/${NPM_CLI_REL}). Check that the 'npm' package built (look for a failure for PKGS=npm above)."

    NPM_VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "${NPM_DIR}/package.json" | head -1)"
    info "node ${NODE_DEB_VERSION:-unknown}, npm ${NPM_VERSION:-unknown}"

    # 3. Audit the binary for hardcoded termux paths.
    #    Node embeds its JS library, so this also covers lib/child_process.js etc.
    info "Auditing ${BIN_NAME} for hardcoded termux paths..."
    mapfile -t LEFTOVERS < <(grep -aoE "/data/data/com\.termux/files/usr[A-Za-z0-9_./-]*" "${USR}/bin/${BIN_NAME}" | sort -u)
    for l in "${LEFTOVERS[@]}"; do info "  baked-in path: $l"; done
    if printf '%s\n' "${LEFTOVERS[@]}" | grep -qx "${TERMUX_USR}/bin/sh"; then
        die "${BIN_NAME} still spawns shells via ${TERMUX_USR}/bin/sh (child_process patch not applied). Rebuild without SKIP_BUILD=1 from a clean tree."
    fi
    grep -aqF -- "$NODE_SHELL" "${USR}/bin/${BIN_NAME}" \
        || die "${BIN_NAME} does not contain the expected shell path '${NODE_SHELL}'."
    # Anything else left (tmpdir fallback, openssl dirs, ...) is overridden at runtime by
    # TMPDIR / OPENSSL_CONF / NPM_CONFIG_* -- they are listed above so regressions are visible.

    # 4. Prune files the app never needs.
    info "Pruning unnecessary files..."
    rm -rf "${USR}/include" \
           "${USR}/share/doc" "${USR}/share/man" "${USR}/share/info" \
           "${USR}/share/locale" "${USR}/share/systemtap" "${USR}/share/bash-completion" \
           "${USR}/lib/dtrace" "${USR}/lib/pkgconfig" "${USR}/lib/cmake" \
           "${USR}/etc/bash_completion.d" \
           "${NPM_DIR}/man" "${NPM_DIR}/docs" "${NPM_DIR}/html"
    find "${USR}" -type f -name "*.a" -delete

    # 5. Builtin npmrc (lowest-priority config: user/project/env config still wins).
    #    Mirrors what deno does by default: never run install scripts (Android forbids
    #    executing files from app storage, so they can only fail), no network chatter.
    cat > "${NPM_DIR}/npmrc" <<EOF
; Written by scripts/build_node.sh -- builtin npm defaults for YTDLnis.
ignore-scripts=true
script-shell=${NODE_SHELL}
update-notifier=false
audit=false
fund=false
progress=false
EOF

    # 6. On-device diagnostics.
    mkdir -p "${USR}/share/ytdlnis"
    cat > "${USR}/share/ytdlnis/selftest.js" <<'EOF'
// Run with the same environment the app uses:  libnode.so <unzipped>/usr/share/ytdlnis/selftest.js
// Prints one PASS/FAIL line per check, so a permission problem names the exact operation.
const fs = require('fs'), os = require('os'), path = require('path'), cp = require('child_process');
const dns = require('dns'), https = require('https');
let failed = 0;
const report = (name, ok, detail) => { if (!ok) failed++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + detail : ''}`); };
const check = async (name, fn) => { try { report(name, true, String((await fn()) ?? '')); } catch (e) { report(name, false, e.code ? `${e.code}: ${e.message}` : e.message); } };
const writable = (dir) => { fs.mkdirSync(dir, { recursive: true }); const f = path.join(dir, `.selftest-${process.pid}`); fs.writeFileSync(f, 'x'); fs.unlinkSync(f); return dir; };

(async () => {
  console.log(`node ${process.version}  execPath=${process.execPath}`);
  await check('HOME writable', () => writable(os.homedir()));
  await check('TMPDIR writable', () => writable(os.tmpdir()));
  if (process.env.NPM_CONFIG_CACHE) await check('npm cache writable', () => writable(process.env.NPM_CONFIG_CACHE));
  if (process.env.NPM_CONFIG_PREFIX) await check('npm prefix writable', () => writable(process.env.NPM_CONFIG_PREFIX));
  await check('os.userInfo()', () => os.userInfo().username);
  await check('cpu count > 0', () => { const n = os.availableParallelism(); if (!n) throw new Error('0'); return n; });
  await check('shell exec', () => cp.execSync('echo ok').toString().trim());
  await check('spawn self', () => cp.spawnSync(process.execPath, ['-v'], { encoding: 'utf8' }).stdout.trim());
  await check('dns.lookup', () => new Promise((res, rej) => dns.lookup('registry.npmjs.org', (e, a) => e ? rej(e) : res(a))));
  await check('https GET registry', () => new Promise((res, rej) =>
    https.get('https://registry.npmjs.org/is-number', (r) => { r.resume(); r.statusCode === 200 ? res(r.statusCode) : rej(new Error('HTTP ' + r.statusCode)); }).on('error', rej)));
  await check('npm install is-number', () => {
    const npmCli = process.env.NPM_CLI_PATH || path.join(__dirname, '../../lib/node_modules/npm/bin/npm-cli.js');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'selftest-'));
    fs.writeFileSync(path.join(dir, 'package.json'), '{"name":"selftest","version":"1.0.0"}');
    const r = cp.spawnSync(process.execPath, [npmCli, 'install', 'is-number'], { cwd: dir, encoding: 'utf8' });
    const ok = r.status === 0 && fs.existsSync(path.join(dir, 'node_modules/is-number/package.json'));
    fs.rmSync(dir, { recursive: true, force: true });
    if (!ok) throw new Error((r.stderr || r.error || 'exit ' + r.status).toString().trim().split('\n').slice(-5).join(' | '));
  });
  console.log(failed ? `\n${failed} check(s) failed` : '\nall checks passed');
  process.exit(failed ? 1 : 0);
})();
EOF

    # 7. Strip symbols.
    if [ -n "$STRIP" ]; then
        info "Stripping symbols..."
        "$STRIP" --strip-unneeded "${USR}/bin/${BIN_NAME}" 2>/dev/null || true
        find "${USR}/lib" -maxdepth 1 -type f -name "*.so*" -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true
    fi

    # 7b. Package-unique library names. After stripping: strip rewrites the files patchelf just laid out.
    info "Isolating shared libraries..."
    isolate_libs "$USR" node

    # 8. Every NEEDED lib must be bundled (or provided by Android).
    if [ -n "$READELF" ]; then
        info "Checking shared library dependencies..."
        MISSING=()
        while IFS= read -r lib; do
            in_list "$lib" "${SYSTEM_LIBS[@]}" && continue
            [ -e "${USR}/lib/${lib}" ] || MISSING+=("$lib")
        done < <({ needed_libs "${USR}/bin/${BIN_NAME}"
                   for so in "${USR}"/lib/*.so*; do [ -f "$so" ] && needed_libs "$so"; done; } | sort -u)
        if [ "${#MISSING[@]}" -gt 0 ]; then
            if [ "$ALLOW_MISSING_LIBS" = "1" ]; then
                warn "missing from bundle: ${MISSING[*]}"
            else
                die "libraries needed by node but not in the bundle for $ARCH: ${MISSING[*]} (ALLOW_MISSING_LIBS=1 to ignore)"
            fi
        fi
    fi

    # 9. Pack.
    if $USE_ANDROID_ABI_NAMES; then OUT_NAME="$(android_abi "$ARCH")"; else OUT_NAME="$ARCH"; fi
    dest="${JNI_DIR}/${OUT_NAME}"
    mkdir -p "$dest"

    # The executable (run directly from jniLibs by the app).
    cp "${USR}/bin/${BIN_NAME}" "${dest}/${LIB_PREFIX}.so"

    # The shared tree the binary dlopens: lib + etc + share (ICU, openssl.cnf, npm, selftest).
    # usr/bin is skipped: the binary is copied above and npm's shell shims can't be exec'd
    # on Android -- run npm as: libnode.so <usr>/lib/node_modules/npm/bin/npm-cli.js ...
    tmp_zip="${WORK}/${LIB_PREFIX}.zip"
    rm -f "$tmp_zip"
    zdirs=()
    for d in lib etc share; do [ -d "${USR}/${d}" ] && zdirs+=("usr/${d}"); done
    ( cd "$FILES_DIR" && zip -9 --symlinks -qr "$tmp_zip" "${zdirs[@]}" )
    mv "$tmp_zip" "${dest}/${LIB_PREFIX}.zip.so"

    cat > "${dest}/manifest.json" <<EOF
{
  "abi": "${OUT_NAME}",
  "node_version": "${NODE_DEB_VERSION:-unknown}",
  "node_binary": "${LIB_PREFIX}.so",
  "bundle_zip": "${LIB_PREFIX}.zip.so",
  "npm_version": "${NPM_VERSION:-unknown}",
  "npm_cli": "usr/${NPM_CLI_REL}",
  "npx_cli": "usr/${NPX_CLI_REL}",
  "node_modules_prefix": "usr/lib/node_modules",
  "child_process_shell": "${NODE_SHELL}",
  "selftest": "usr/share/ytdlnis/selftest.js"
}
EOF

    info "wrote ${dest}/{${LIB_PREFIX}.so,${LIB_PREFIX}.zip.so,manifest.json}"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    if $USE_ANDROID_ABI_NAMES; then n="$(android_abi "$ARCH")"; else n="$ARCH"; fi
    info "$n : $(ls -1 "${JNI_DIR}/${n}" 2>/dev/null | tr '\n' ' ')"
done

cat <<'EOF'

===============================================================================
 Running node / npm from the app
===============================================================================
Unzip libnode.zip.so to app storage, then spawn the node binary directly
(usr/bin shims can't be exec'd on Android):

    <nativeLibraryDir>/libnode.so <unzipped>/usr/lib/node_modules/npm/bin/npm-cli.js install

Environment (what the app's RuntimeManager.getEnvironment() should provide):

    LD_LIBRARY_PATH=<unzipped>/usr/lib:<nativeLibraryDir>
    OPENSSL_CONF=<unzipped>/usr/etc/tls/openssl.cnf
    HOME=<app-writable-dir>                 (node + npm write config/cache here)
    TMPDIR=<app-writable-dir>/tmp
    NPM_CONFIG_PREFIX=<app-writable-dir>/.npm-global
    NPM_CONFIG_CACHE=<app-writable-dir>/.npm-cache

Behaviour baked in at build time:
  * child_process (exec, spawn shell:true, npm scripts) uses NODE_SHELL (see manifest.json)
  * npm ignores install/lifecycle scripts by default (usr/lib/node_modules/npm/npmrc);
    run build tools explicitly, e.g.  libnode.so node_modules/typescript/bin/tsc
  * packages needing a native build (node-gyp) are not supported

Diagnose any device problem with:
    libnode.so <unzipped>/usr/share/ytdlnis/selftest.js
===============================================================================
EOF
