# External Android persistent disks (A+B integration)

After the device PR and this tools PR are merged:

```sh
./get_android_qcow2.sh
```

Generates a fresh `disk-vda.qcow2` and creates three writable state
seeds only when absent. Connect all four as VirtIO block devices in this
order: `vda` boot, `vdb` userdata, `vdc` GPT metadata (`vdc1`),
and `vdd` raw FAT32 persist. Keep the state images across system rebuilds.

For VyOS ISO builds, call `build_android.sh r86s_virtio_tv` directly and
convert the generated `disk-vda.img` to QCOW2. Copy `persist.img` as
the initial state source for host GPT #6. The host installer creates the
metadata GPT itself; it does not need `metadata-empty.qcow2`.

The boot GPT is generated with `persist-unused` and
`metadata-unused` partitions at their original physical offsets, while
the legacy `persist.img` payload is not written into `vda4`. GRUB
discovers its boot ESP independently from the external PERSIST state.

Runtime boot/mount testing has to be done on the combined A+B tree.
Do not attach a blank metadata seed to encrypted userdata from a
previous installation. A VM must be shut down before swapping vda.
