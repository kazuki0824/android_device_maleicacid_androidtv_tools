#!/bin/bash
set -euo pipefail


cd $(dirname "$0")
SCRIPTDIR=$(dirname "$(realpath "${BASH_SOURCE:-0}")")

mkdir ./build-work2 || true
pushd ./build-work2
repo init -u https://github.com/kazuki0824/android -b lineage-21.0
repo sync -j$(nproc) -c -d --force-sync
$SCRIPTDIR/docker/build_in_docker.sh r86s_tv_virtio
sudo $SCRIPTDIR/image/make_selfcontained_qcow2.sh r86s_tv_virtio
popd
