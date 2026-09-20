# virtio_utils
## vq_watch.sh
```bash
$ virsh qemu-monitor-command <vm> --hmp "info virtio"
check device_path

$ ./vq_watch.sh <vm> <device_path> [interval_seconds]
```
