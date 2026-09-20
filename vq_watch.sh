#!/usr/bin/env bash
# Read actual split-ring indices from guest physical memory (x86, little endian).
# Discover the queue count on each refresh; packed rings are not supported.
# RX/TX/CTRL labels assume the contiguous virtio-net queue layout.
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
    echo "Usage: bash $0 VM_NAME DEVICE_PATH [INTERVAL_SECONDS]" >&2
    echo 'Default interval: 10 seconds. Use 0 for a single snapshot.' >&2
    exit 2
fi
vm=$1
device_path=$2
interval=${3:-10}
if [[ ! $interval =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo 'Interval must be a nonnegative number.' >&2
    exit 2
fi
for cmd in virsh jq; do
    command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

if [[ ! $interval =~ ^0+([.]0+)?$ ]]; then
    command -v watch >/dev/null || { echo 'Missing command: watch' >&2; exit 1; }
    script_path=$(readlink -f -- "${BASH_SOURCE[0]}")
    exec watch -d -n "$interval" -x bash "$script_path" "$vm" "$device_path" 0
fi

# Read two bytes rather than relying on the monitor's halfword byte order.
# Validate the entire response: a monitor error must never turn into zero.
read_u16() {
    local base=$1 address output pattern low high
    printf -v address '0x%x' "$base"
    if ! output=$(virsh qemu-monitor-command "$vm" --hmp "xp /2bx $address"); then
        return 1
    fi
    output=${output//$'\r'/}
    pattern='^[[:space:]]*(0[xX])?([[:xdigit:]]+):[[:space:]]+0x([[:xdigit:]]{2})[[:space:]]+0x([[:xdigit:]]{2})[[:space:]]*$'
    if [[ ! $output =~ $pattern ]]; then
        printf 'Memory read failed at %s: %s\n' "$address" "$output" >&2
        return 1
    fi
    if (( 16#${BASH_REMATCH[2]} != base )); then
        echo 'Unexpected address in memory response' >&2
        return 1
    fi
    low=${BASH_REMATCH[3]}
    high=${BASH_REMATCH[4]}
    printf '%d\n' "$((16#$low + (16#$high << 8)))"
}

# num-vqs describes queues exposed by QEMU, not necessarily queues in use
# by the guest. Uninitialized rings are displayed as N/A below.
req=$(jq -nc --arg path "$device_path" \
    '{execute:"x-query-virtio-status", arguments:{path:$path}}')
status=$(virsh qemu-monitor-command "$vm" "$req")
if jq -e 'has("error")' <<< "$status" >/dev/null; then
    jq -r '.error.desc' <<< "$status" >&2
    exit 1
fi
queue_count=$(jq -er '.return["num-vqs"] | select(type == "number" and . >= 0 and . == floor)' <<< "$status")
device_id=$(jq -r '.return["device-id"] // 0' <<< "$status")
if jq -e '.return["guest-features"] | .. | strings | select(contains("RING_PACKED"))' <<< "$status" >/dev/null; then
    echo 'Packed virtqueues are not supported; no split-ring memory will be read.' >&2
    exit 1
fi

event_idx=UNKNOWN
if jq -e '.return["guest-features"] | type == "object"' <<< "$status" >/dev/null; then
    event_idx=OFF
    if jq -e '.return["guest-features"] | .. | strings | select(contains("EVENT_IDX"))' <<< "$status" >/dev/null; then
        event_idx=ON
    fi
fi

printf 'VM: %s (x86 split ring, queues: %s, EVENT_IDX: %s)\n' "$vm" "$queue_count" "$event_idx"
row_format='%-7s %6s %10s %10s %12s %12s %11s %11s\n'
printf "$row_format" QUEUE SIZE AVAIL_IDX USED_IDX AVAIL_FLAGS USED_FLAGS USED_EVENT AVAIL_EVENT
for ((q=0; q<queue_count; q++)); do
    label="Q$q"
    if [[ $device_id == 1 ]]; then
        if (( queue_count % 2 == 1 && q == queue_count - 1 )); then
            label=CTRL
        elif (( q % 2 == 0 )); then
            label="RX$((q / 2))"
        else
            label="TX$((q / 2))"
        fi
    fi
    req=$(jq -nc --arg path "$device_path" --argjson q "$q" \
        '{execute:"x-query-virtio-queue-status", arguments:{path:$path, queue:$q}}')
    reply=$(virsh qemu-monitor-command "$vm" "$req")
    if jq -e 'has("error")' <<< "$reply" >/dev/null; then
        printf '%s ERROR: %s\n' "$label" "$(jq -r '.error.desc' <<< "$reply")"
        continue
    fi
    row=$(jq -er '.return | [.["vring-num"], .["vring-avail"], .["vring-used"]] | @tsv' <<< "$reply")
    IFS=$'\t' read -r size avail_addr used_addr <<< "$row"
    if [[ ! $size =~ ^[0-9]+$ || ! $avail_addr =~ ^[0-9]+$ || ! $used_addr =~ ^[0-9]+$ ]]; then
        printf '%s ERROR: missing or invalid ring address/size\n' "$label"
        continue
    fi
    if (( size == 0 || avail_addr == 0 || used_addr == 0 )); then
        printf "$row_format" "$label" "$size" N/A N/A N/A N/A N/A N/A
        continue
    fi
    avail_idx=N/A
    used_idx=N/A
    avail_flags=N/A
    used_flags=N/A
    used_event=N/A
    avail_event=N/A
    if value=$(read_u16 "$((avail_addr + 2))"); then avail_idx=$value; fi
    if value=$(read_u16 "$((used_addr + 2))"); then used_idx=$value; fi
    if value=$(read_u16 "$avail_addr"); then printf -v avail_flags '0x%04x' "$value"; fi
    if value=$(read_u16 "$used_addr"); then printf -v used_flags '0x%04x' "$value"; fi
    # Event words are meaningful only when EVENT_IDX was negotiated.
    if [[ $event_idx == ON ]]; then
        if value=$(read_u16 "$((avail_addr + 4 + 2 * size))"); then used_event=$value; fi
        if value=$(read_u16 "$((used_addr + 4 + 8 * size))"); then avail_event=$value; fi
    elif [[ $event_idx == OFF ]]; then
        used_event=-
        avail_event=-
    fi
    printf "$row_format" "$label" "$size" "$avail_idx" "$used_idx" "$avail_flags" "$used_flags" "$used_event" "$avail_event"
done
if [[ $event_idx == ON ]]; then
    printf '\nEVENT_IDX ON: event indices control notification suppression; flags bit 0 is ignored.\n'
elif [[ $event_idx == OFF ]]; then
    printf '\nEVENT_IDX OFF: AVAIL_FLAGS bit 0 = NO_INTERRUPT; USED_FLAGS bit 0 = NO_NOTIFY.\n'
fi
printf '\nIndices wrap at 65536. Reads are sequential, not an atomic snapshot.\n'
printf 'A reset during a read can invalidate addresses; retry on the next refresh.\n'
