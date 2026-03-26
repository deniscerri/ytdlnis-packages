#!/bin/bash

# PHASE 1 - BUILD
ARCHITECTURES=("aarch64" "arm" "i686" "x86_64")
OUTPUT_BASE_DIR="${PWD}/output"
packages=("deno" "libandroid-support" "libandroid-stub" "libffi" "libsqlite" "zlib")

for ARCH in "${ARCHITECTURES[@]}"; do
    echo "--- Building for $ARCH ---"
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    # Build nodejs
    ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" deno

    # Move generated .deb files
    find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \( -name "*$ARCH*" -o -name "*all*" \) -exec mv {} "$OUTPUT_DIR/" \;
done

# PHASE 2 - EXTRACTION
# Use absolute path for jniLibs to avoid variable confusion
JNI_OUT_DIR="${PWD}/jniLibs"
mkdir -p "$JNI_OUT_DIR"

for ARCH in "${ARCHITECTURES[@]}"; do
    echo "Processing $ARCH..."

    case $ARCH in
        "aarch64") JNI_ARCH="arm64-v8a" ;;
        "arm")     JNI_ARCH="armeabi-v7a" ;;
        "i686")    JNI_ARCH="x86" ;;
        "x86_64")  JNI_ARCH="x86_64" ;;
    esac

    # Create a fresh extraction directory for this arch
    EXTRACT_DIR="${OUTPUT_BASE_DIR}/extract_$ARCH"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    # Extract ALL packages into the SAME folder
    for package in "${packages[@]}"; do
        # Find the deb in the arch folder
        deb_file=$(find "${OUTPUT_BASE_DIR}/$ARCH" -name "${package}_*.deb" | head -n 1)
        
        if [[ -f "$deb_file" ]]; then
            echo "Extracting $deb_file..."
            # Extracting into $EXTRACT_DIR
            dpkg-deb -x "$deb_file" "$EXTRACT_DIR"
        else
            echo "Warning: Could not find deb for $package"
        fi
    done

    # Navigate to the ACTUAL Termux usr folder
    # This path is standard for all Termux debs
    USR_ROOT="$EXTRACT_DIR/data/data/com.termux/files/usr"

    if [ -d "$USR_ROOT" ]; then
        echo "Creating Zip and Binary for $JNI_ARCH"
        mkdir -p "$JNI_OUT_DIR/$JNI_ARCH"

        # 1. Handle the Binary
        if [ -f "$USR_ROOT/bin/deno" ]; then
            cp "$USR_ROOT/bin/deno" "$JNI_OUT_DIR/$JNI_ARCH/libdeno.so"
        fi

        # 2. Handle the Zip (Bootstrap)
        # We 'cd' into the usr folder so the zip contains lib, etc, share at its root
        cd "$USR_ROOT"
        
        # This zip command is safer: it only adds folders that actually exist
        # We use 'usr/...' naming if you want to keep the usr prefix, 
        # but your previous code zipped 'lib etc share' directly.
        # Let's zip 'usr' itself so the zip root has 'usr/'
        cd .. # Go up to 'files' folder
        zip --symlinks -r "$JNI_OUT_DIR/$JNI_ARCH/libdeno.zip.so" usr/
        
        echo "Successfully packaged $JNI_ARCH"
    else
        echo "Error: USR_ROOT not found at $USR_ROOT"
    fi

    # Return to project root
    cd "$PWD"
done

echo "Done! Check: $JNI_OUT_DIR"
