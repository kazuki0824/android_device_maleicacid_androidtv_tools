# Android TV build tools (maleicacid)

This directory provides build scripts that meet:
- 7* (single qcow2 deliverable; first boot can be recovery; install from within qcow2)
- 8  (two products: r86s_tv_virtio / qemu_tv_virtio)
- 11 (repo sync outside container, build inside openstf/docker-aosp container)
- 13 (Soong builds OS; qcow2 is created by separate script)

## Files

- docker/build_in_docker.sh
  Builds `espimage-install` and a flashable zip (otapackage or bacon) inside `openstf/docker-aosp`.

- image/make_selfcontained_qcow2.sh
  Creates ONE qcow2 that:
  - boots the installer environment (converted from espimage-install .img)
  - contains an INSTALL FAT volume with the flashable zip copied into it

- run/run_qemu_tv_virtio.sh
  Convenience command to boot the qcow2 under QEMU (no passthrough). For r86s_tv_virtio, boot via your VyOS host script.

## Typical flow

1) (Already done) `repo sync` outside containers.

2) Build inside container:
   ```
   device/maleicacid/androidtv-tools/docker/build_in_docker.sh r86s_tv_virtio
   ```

3) Create single-file qcow2 (run on Linux host, needs qemu-nbd + sgdisk + mkfs.vfat):
   ```
   sudo device/maleicacid/androidtv-tools/image/make_selfcontained_qcow2.sh r86s_tv_virtio --size 32G
   ```

4) First boot (user side):
   - Boot the qcow2
   - In recovery:
     - Factory reset -> Format data
     - Apply update -> Choose INSTALL -> select the zip
   - Reboot system now

After that, the same qcow2 should boot Android without needing extra files.
