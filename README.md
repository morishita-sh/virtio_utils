# virtio_utils
## vq_watch.sh
```bash
$ virsh qemu-monitor-command <VM_NAME> --hmp "info virtio"
check DEVICE_PATH

$ ./vq_watch.sh <VM_NAME> <DEVICE_PATH> [INTERVAL_SECONDS]
```
