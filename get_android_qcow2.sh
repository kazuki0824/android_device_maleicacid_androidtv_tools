#!/usr/bin/env bash
set -euo pipefail

SCRIPTDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT="${ANDROID_PRODUCT:-virtio_x86_64_tv_grub}"

# Build the Android raw disk; do not replace deployed userdata/metadata/persist.
bash "$SCRIPTDIR/build_android.sh" "$PRODUCT"

cd "$SCRIPTDIR/build-work"
"$SCRIPTDIR/image/make_disk_image.sh" \
    --product-out "out/target/product/$PRODUCT"
