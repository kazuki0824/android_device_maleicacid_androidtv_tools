#!/bin/bash
set -euo pipefail

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_BUILD_TOP="$PWD"

PATCH_REPOS=()
PATCH_FILES=()
PATCH_LABELS=()
PATCH_RESULTS=()
PATCH_FAILURES=()

add_patch() {
    PATCH_REPOS+=("$1")
    PATCH_FILES+=("$2")
    PATCH_LABELS+=("$3")
}

reset_patch_repo() {
    local repo="$1"

    if git -C "$repo" reset --hard; then
        PATCH_RESULTS+=("RESET    $repo")
    else
        PATCH_RESULTS+=("FAILED   reset $repo")
        PATCH_FAILURES+=("reset $repo")
    fi
}

try_patch() {
    local repo="$1"
    local patch="$2"
    local label="$3"

    if git -C "$repo" apply --check "$patch"; then
        if git -C "$repo" apply "$patch"; then
            PATCH_RESULTS+=("APPLIED  $repo: $label")
        else
            PATCH_RESULTS+=("FAILED   $repo: $label")
            PATCH_FAILURES+=("$repo: $label: apply failed after apply --check succeeded")
        fi
    elif git -C "$repo" apply --reverse --check "$patch"; then
        PATCH_RESULTS+=("PRESENT  $repo: $label")
    else
        PATCH_RESULTS+=("FAILED   $repo: $label")
        PATCH_FAILURES+=("$repo: $label: neither forward nor reverse dry-run applies")
    fi
}

# Single source of truth for patch target, file and application order.
add_patch \
    hardware/interfaces/tv/tuner \
    "$ANDROID_BUILD_TOP/vendor/maleicacid/tv/tuner_hal2/platform_patches/lineage-22.1/android_hardware_tv_tuner_nullable_current.patch" \
    "Tuner nullable AIDL source"

add_patch \
    frameworks/base \
    "$ANDROID_BUILD_TOP/vendor/maleicacid/tv/tuner_hal2/platform_patches/lineage-22.1/android_frameworks_base_tuner_filter_null_data_source.patch" \
    "Tuner Filter null data source"

add_patch \
    frameworks/av \
    "$ANDROID_BUILD_TOP/vendor/maleicacid/tv/tuner_hal2/platform_patches/lineage-22.1/android_frameworks_av_tuner_filter_null_data_source.patch" \
    "Tuner Filter null data source"

add_patch \
    frameworks/base \
    "$PATCH_DIR/frameworks_base_dropbox_early_boot_guard.patch" \
    "DropBox early-boot guard"

declare -A RESET_REPOS=()
for repo in "${PATCH_REPOS[@]}"; do
    if [[ -z "${RESET_REPOS[$repo]+x}" ]]; then
        reset_patch_repo "$repo"
        RESET_REPOS["$repo"]=1
    fi
done

patch_count=${#PATCH_REPOS[@]}
for i in "${!PATCH_REPOS[@]}"; do
    printf '[*] Patch %d/%d: %s: %s\n' \
        "$((i + 1))" \
        "$patch_count" \
        "${PATCH_REPOS[$i]}" \
        "${PATCH_LABELS[$i]}"

    try_patch \
        "${PATCH_REPOS[$i]}" \
        "${PATCH_FILES[$i]}" \
        "${PATCH_LABELS[$i]}"
done

echo "[+] Patch phase summary:"
printf "    %s\n" "${PATCH_RESULTS[@]}"

if (( ${#PATCH_FAILURES[@]} > 0 )); then
    echo "[!] Patch phase failed; all patch attempts completed. Failures:" >&2
    printf "    - %s\n" "${PATCH_FAILURES[@]}" >&2
    exit 1
fi
