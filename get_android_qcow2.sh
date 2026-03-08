#!/bin/bash
set -euo pipefail


cd $(dirname "$0")
SCRIPTDIR=$(dirname "$(realpath "${BASH_SOURCE:-0}")")

VARIANT=${1:-r86s}

mkdir ./build-work || true
pushd ./build-work
repo init -u https://github.com/kazuki0824/android --git-lfs -b lineage-21.0
repo sync -j$(nproc) -c -d
$SCRIPTDIR/docker/build_in_docker.sh lineage_${VARIANT}_tv_virtio
sudo $SCRIPTDIR/image/make_selfcontained_qcow2.sh lineage_${VARIANT}_tv_virtio
popd
