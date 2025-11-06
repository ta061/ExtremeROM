#!/usr/bin/env bash
#
# ExtremeROM Build Script (Optimized 2025)
# Author: Salvo Giangreco (modded version)
#
# Licensed under GPL v3

set -e

# === Load Utilities ===
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1

# === Variables ===
FORCE=false
BUILD_ROM=false
BUILD_ZIP=true
START_TIME="$(date +%s)"

SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

# === Functions ===

GET_WORK_DIR_HASH() {
    find "$SRC_DIR/unica" "$SRC_DIR/target/$TARGET_CODENAME" -type f -print0 | \
        sort -z | xargs -0 sha1sum | sha1sum | cut -d " " -f 1
}

PREPARE_SCRIPT() {
    while [ "$#" != 0 ]; do
        case "$1" in
            "-f" | "--force") FORCE=true ;;
            "--no-rom-zip") BUILD_ZIP=false ;;
            *)
                echo "Usage: make_rom [options]"
                echo " -f, --force : Force build"
                echo " --no-rom-zip : Do not build ROM zip"
                exit 1 ;;
        esac
        shift
    done
}

PRINT_BUILD_OUTCOME() {
    local EXIT_CODE="$?"
    local END_TIME="$(date +%s)"
    local ELAPSED="$((END_TIME - START_TIME))"

    if [ "$EXIT_CODE" != "0" ]; then
        echo -e "\n\033[1;31mBuild failed in $((ELAPSED / 3600))h $(((ELAPSED / 60) % 60))m $((ELAPSED % 60))s.\033[0m\n"
    else
        echo -e "\n\033[1;32mBuild completed successfully in $((ELAPSED / 3600))h $(((ELAPSED / 60) % 60))m $((ELAPSED % 60))s.\033[0m\n"
    fi
}

# === Initialize ===
PREPARE_SCRIPT "$@"
trap 'PRINT_BUILD_OUTCOME' EXIT
trap 'echo' INT

if $FORCE; then
    BUILD_ROM=true
else
    if [ -f "$WORK_DIR/.completed" ]; then
        if [[ "$(cat "$WORK_DIR/.completed")" == "$(GET_WORK_DIR_HASH)" ]]; then
            LOGW "No changes detected. Skipping full rebuild."
            BUILD_ROM=false
        else
            LOGW "Changes detected. Rebuilding ROM..."
            BUILD_ROM=true
        fi
    else
        BUILD_ROM=true
    fi
fi

# === Build Process ===
if $BUILD_ROM; then
    [ -d "$APKTOOL_DIR" ] && rm -rf "$APKTOOL_DIR"
    [ -f "$WORK_DIR/.completed" ] && rm -f "$WORK_DIR/.completed"

    # Ensure firmwares exist
    if [ ! -f "$FW_DIR/$SOURCE_FIRMWARE_PATH/.extracted" ] || [ ! -f "$FW_DIR/$TARGET_FIRMWARE_PATH/.extracted" ]; then
        if [ ! -f "$ODIN_DIR/$SOURCE_FIRMWARE_PATH/.downloaded" ] || [ ! -f "$ODIN_DIR/$TARGET_FIRMWARE_PATH/.downloaded" ]; then
            LOG_STEP_IN true "Downloading required firmwares"
            "$SRC_DIR/scripts/download_fw.sh" || exit 1
            LOG_STEP_OUT
        fi
        LOG_STEP_IN true "Extracting firmwares"
        "$SRC_DIR/scripts/extract_fw.sh" || exit 1
        LOG_STEP_OUT
    fi

    LOG_STEP_IN true "Creating work dir"
    "$SRC_DIR/scripts/internal/create_work_dir.sh" || exit 1
    LOG_STEP_OUT

    # === NFC Folder Fix (prevents ln: failed to create symbolic link) ===
    mkdir -p "$WORK_DIR/system/system/priv-app/NfcNci/lib/arm64" || true

    # === Apply Patches ===
    if [ -d "$SRC_DIR/unica/patches" ]; then
        LOG_STEP_IN true "Applying ROM patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/unica/patches" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$SRC_DIR/platform/$TARGET_PLATFORM/patches" ]; then
        LOG_STEP_IN true "Applying platform patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/platform/$TARGET_PLATFORM/patches" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$SRC_DIR/target/$TARGET_CODENAME/patches" ]; then
        LOG_STEP_IN true "Applying device patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/target/$TARGET_CODENAME/patches" || exit 1
        LOG_STEP_OUT
    fi

    # === Apply Mods ===
    if [ -d "$SRC_DIR/unica/mods" ]; then
        LOG_STEP_IN true "Applying ROM mods"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/unica/mods" || exit 1
        LOG_STEP_OUT
    fi

    # === APK / JAR Building ===
    if [ -d "$APKTOOL_DIR" ]; then
        LOG_STEP_IN true "Building APKs/JARs"
        while IFS= read -r f; do
            f="${f/$APKTOOL_DIR\//}"
            PARTITION="$(cut -d "/" -f 1 -s <<< "$f")"
            if [[ "$PARTITION" == "system" ]]; then
                "$SRC_DIR/scripts/apktool.sh" b "system" "$f" &
            else
                "$SRC_DIR/scripts/apktool.sh" b "$PARTITION" "$(cut -d "/" -f 2- -s <<< "$f")" &
            fi
        done < <(find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \))
        wait $(jobs -p) || exit 1
        LOG_STEP_OUT
    fi

    echo -n "$(GET_WORK_DIR_HASH)" > "$WORK_DIR/.completed"
fi

# === Cleanup for GitHub Actions ===
if [ -n "$GITHUB_ACTIONS" ]; then
    bash "$SRC_DIR/scripts/cleanup.sh" fw kernel || true
fi

# === ZIP Build ===
if $BUILD_ZIP; then
    LOG_STEP_IN true "Creating flashable ZIP"
    "$SRC_DIR/scripts/internal/build_flashable_zip.sh" || exit 1
    LOG_STEP_OUT
fi

exit 0
