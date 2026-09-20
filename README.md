# virtio_utils
check `DEVICE_PATH`
```bash
$ virsh qemu-monitor-command <VM_NAME> --hmp "info virtio"
```

## vq_watch.sh
```bash
$ ./vq_watch.sh <VM_NAME> <DEVICE_PATH> [INTERVAL_SECONDS]
```
- Monitor all virtqueues of the specified device, displaying queue sizes, available and used indices, notification flags, and event indices. Refresh every `INTERVAL_SECONDS` seconds (default: 10); set to `0` for a single snapshot. Supports x86 split virtqueues.

## vq_detail.sh
```bash
$ ./vq_detail.sh <VM_NAME> <DEVICE_PATH> <QUEUE_ID> desc [START] [COUNT]
$ ./vq_detail.sh <VM_NAME> <DEVICE_PATH> <QUEUE_ID> rings [COUNT]
$ ./vq_detail.sh <VM_NAME> <DEVICE_PATH> <QUEUE_ID> chain <DESC_ID>
```
- `desc`: Display descriptor table entries starting at `START` (default: 0), up to `COUNT` entries (default: 16).
- `rings`: Display available and used ring entries around their next-write positions, up to `COUNT` entries per ring (default: 16).
- `chain`: Follow the descriptor chain starting at `DESC_ID`, including indirect descriptor tables.
