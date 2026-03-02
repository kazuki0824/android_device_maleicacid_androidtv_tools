Android TV qcow2 flow:

1) repo sync (outside container)
2) build_in_docker.sh r86s_tv_virtio
3) sudo make_selfcontained_qcow2.sh r86s_tv_virtio
4) Boot qcow2, install zip from recovery (first boot only)
