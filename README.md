# Android TV build tools

## Policy (requirements 11/13)
* Source sync: run `repo init` / `repo sync` outside containers.
* Build: run inside `openstf/docker-aosp`.
* qcow2 generation: done by shell scripts.

## Build
```bash
./device/maleicacid/androidtv-tools/docker/build_in_docker.sh r86s_tv_virtio
```

## Create installed qcow2 (requirement 7)
```bash
./device/maleicacid/androidtv-tools/image/make_installed_qcow2.sh r86s_tv_virtio 16
```
