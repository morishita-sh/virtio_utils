#!/usr/bin/env bash
# Read-only, one-shot inspection of x86 little-endian split virtqueues.
# Requires: bash, python3, virsh. Uses the same libvirt connection as virsh.
# Examples:
#   sudo bash vq-detail.sh DUT DEVICE_PATH 1 desc 0 16
#   sudo bash vq-detail.sh DUT DEVICE_PATH 1 rings
#   sudo bash vq-detail.sh DUT DEVICE_PATH 1 chain 0
set -euo pipefail
command -v python3 >/dev/null || { echo 'Missing command: python3' >&2; exit 1; }
exec python3 - "$@" <<'PY'
import argparse
import json
import re
import shutil
import struct
import subprocess
import sys


class InspectError(Exception):
    pass


def number(text):
    try:
        value = int(text, 16 if text.lower().startswith('0x') else 10)
        if value < 0:
            raise ValueError
        return value
    except ValueError:
        raise argparse.ArgumentTypeError('expected a nonnegative integer')


parser = argparse.ArgumentParser(
    prog='vq-detail.sh',
    description='Read one x86 split virtqueue via QEMU monitor (no guest agent).',
    epilog='Reads are live and non-atomic. Old ring entries are not a work queue or history log.')
parser.add_argument('vm')
parser.add_argument('device_path')
parser.add_argument('queue', type=number, help='QEMU queue number, e.g. TX0=1')
modes = parser.add_subparsers(dest='mode', required=True)
desc = modes.add_parser('desc', help='show a descriptor table range')
desc.add_argument('start', type=number, nargs='?', default=0)
desc.add_argument('count', type=number, nargs='?', default=16)
rings = modes.add_parser('rings', help='show avail/used slots around their next-write positions')
rings.add_argument('count', type=number, nargs='?', default=16, help='slots per ring (default 16)')
chain = modes.add_parser('chain', help='follow a main-table descriptor ID, including indirect tables')
chain.add_argument('head', type=number)
args = parser.parse_args()


def run_virsh(*tail):
    try:
        result = subprocess.run(['virsh', 'qemu-monitor-command', args.vm, *tail],
                                capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        raise InspectError('virsh timed out after 30 seconds')
    if result.returncode:
        raise InspectError(result.stderr.strip() or result.stdout.strip() or 'virsh failed')
    return result.stdout


def qmp(command, **parameters):
    raw = run_virsh(json.dumps({'execute': command, 'arguments': parameters}))
    try:
        response = json.loads(raw)
    except ValueError:
        raise InspectError('invalid QMP JSON response: ' + raw[:200])
    if 'error' in response:
        raise InspectError(response['error'].get('desc', str(response['error'])))
    if not isinstance(response.get('return'), dict):
        raise InspectError('QMP did not return an object')
    return response['return']


def integer(obj, name):
    value = obj.get(name)
    if type(value) is not int or value < 0:
        raise InspectError('missing or invalid field: ' + name)
    return value


def strings(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)
    elif isinstance(value, str):
        yield value


def read_memory(address, length):
    if not 0 <= address < 2**64 or length < 0 or address + length > 2**64:
        raise InspectError('memory range outside 64-bit address space')
    data = bytearray()
    # Bound each monitor reply; no command per descriptor/byte.
    while len(data) < length:
        start = address + len(data)
        count = min(4096, length - len(data))
        output = run_virsh('--hmp', f'xp /{count}bx 0x{start:x}')
        block = bytearray()
        for line in output.splitlines():
            if not line.strip():
                continue
            match = re.fullmatch(r'\s*(?:0[xX])?([0-9a-fA-F]+):\s*(.*?)\s*', line)
            if not match or int(match[1], 16) != start + len(block):
                raise InspectError(f'unexpected memory response at 0x{start:x}: {line}')
            tokens = match[2].split()
            if not tokens or any(not re.fullmatch(r'0[xX][0-9a-fA-F]{2}', t) for t in tokens):
                raise InspectError('invalid memory byte response: ' + line)
            block.extend(int(t, 16) for t in tokens)
        if len(block) != count:
            raise InspectError(f'short/long memory read at 0x{start:x}: {len(block)} != {count}')
        data.extend(block)
    return bytes(data)


def flags_text(flags):
    parts = [name for bit, name in [(1, 'NEXT'), (2, 'WRITE'), (4, 'INDIRECT')] if flags & bit]
    if flags & ~7:
        parts.append(f'UNKNOWN(0x{flags & ~7:x})')
    return '|'.join(parts) or '-'


def print_desc_header():
    print(f'{"TABLE":<10} {"DESC_ID":>7} {"BUFFER_ADDR":>18} {"LEN":>10} {"FLAGS":<28} {"NEXT":>7}')


def print_descriptor(table, index, value):
    address, length, flags, nxt = value
    print(f'{table:<10} {index:7d} 0x{address:016x} {length:10d} '
          f'{flags_text(flags):<28} {str(nxt) if flags & 1 else "-":>7}')


def queue_state():
    return qmp('x-query-virtio-queue-status', path=args.device_path, queue=args.queue)


def main():
    if not shutil.which('virsh'):
        raise InspectError('Missing command: virsh')
    device = qmp('x-query-virtio-status', path=args.device_path)
    features = device.get('guest-features')
    if not isinstance(features, dict):
        raise InspectError('guest-features unavailable; cannot verify split-ring format')
    feature_names = list(strings(features))
    if any('RING_PACKED' in name for name in feature_names):
        raise InspectError('packed virtqueues are not supported')
    # ACCESS_PLATFORM permits IOVAs rather than guest physical addresses.
    if any('IOMMU_PLATFORM' in name or 'ACCESS_PLATFORM' in name for name in feature_names):
        raise InspectError('ACCESS_PLATFORM/IOMMU address translation is not supported')
    if device.get('device-endian', 'little') != 'little':
        raise InspectError('only little-endian x86 split rings are supported')
    queue_count = integer(device, 'num-vqs')
    if args.queue >= queue_count:
        raise InspectError(f'queue {args.queue} outside 0..{queue_count - 1}')
    state = queue_state()
    size = integer(state, 'vring-num')
    desc_addr = integer(state, 'vring-desc')
    avail_addr = integer(state, 'vring-avail')
    used_addr = integer(state, 'vring-used')
    if not size or not desc_addr or not avail_addr or not used_addr:
        raise InspectError('queue is not initialized (zero size or ring address)')
    if size > 32768 or size & (size - 1):
        raise InspectError('invalid split-ring size')
    if args.mode in ('desc', 'rings') and args.count == 0:
        raise InspectError('count must be positive')
    if args.mode == 'desc' and args.start >= size:
        raise InspectError(f'descriptor ID must be smaller than {size}')
    if args.mode == 'chain' and args.head >= size:
        raise InspectError(f'head descriptor ID must be smaller than {size}')

    av_header = read_memory(avail_addr, 4)
    us_header = read_memory(used_addr, 4)
    av_flags, av_idx = struct.unpack('<HH', av_header)
    us_flags, us_idx = struct.unpack('<HH', us_header)
    event_idx = any('EVENT_IDX' in name for name in feature_names)
    print(f'VM={args.vm} QUEUE={args.queue} SIZE={size} EVENT_IDX={"ON" if event_idx else "OFF"}')
    print(f'DESC=0x{desc_addr:x} AVAIL=0x{avail_addr:x} USED=0x{used_addr:x}')
    print(f'AVAIL_IDX={av_idx} USED_IDX={us_idx} AVAIL_FLAGS=0x{av_flags:04x} USED_FLAGS=0x{us_flags:04x}')
    print('Live non-atomic read. Entries can be stale/reused; no ownership classification.\n')

    if args.mode == 'desc':
        count = min(args.count, size - args.start)
        data = read_memory(desc_addr + 16 * args.start, 16 * count)
        print_desc_header()
        for offset in range(count):
            print_descriptor('main', args.start + offset, struct.unpack_from('<QIHH', data, offset * 16))

    elif args.mode == 'rings':
        count = min(args.count, size)
        for name, base, idx, width in [('AVAIL', avail_addr, av_idx, 2), ('USED', used_addr, us_idx, 8)]:
            next_slot = idx % size
            start = (next_slot - count // 2) % size
            first = min(count, size - start)
            data = read_memory(base + 4 + start * width, first * width)
            if first < count:
                data += read_memory(base + 4, (count - first) * width)
            print(f'{name}: next-write slot={next_slot} (sampled IDX={idx})')
            print(f'{"MARK":<6} {"SLOT":>6} {"HEAD_DESC_ID":>13} {"WRITTEN_LEN":>12}')
            for offset in range(count):
                slot = (start + offset) % size
                if name == 'AVAIL':
                    head, = struct.unpack_from('<H', data, offset * width)
                    length = '-'
                else:
                    head, length = struct.unpack_from('<II', data, offset * width)
                mark = 'NEXT' if slot == next_slot else ''
                invalid = ' [ID out of range]' if head >= size else ''
                print(f'{mark:<6} {slot:6d} {head:13d} {str(length):>12}{invalid}')
            print()
        print('NEXT marks the next write slot, not the next work item to process.')

    else:
        print_desc_header()
        visited = set()
        main_cache = {}
        total = 0

        def walk(base, limit, index, table, indirect=False):
            nonlocal total
            while True:
                if not 0 <= index < limit:
                    raise InspectError(f'{table}: descriptor ID {index} outside 0..{limit - 1}')
                key = (table, base, index)
                if key in visited:
                    raise InspectError(f'cycle detected at {table} descriptor {index}')
                visited.add(key)
                total += 1
                if total > size + 1:
                    raise InspectError('chain exceeds the queue-size traversal limit')
                # Cache small blocks for direct chains; only reached entries are displayed.
                block_index = index // 16 * 16
                cache_key = (base, limit, block_index)
                if cache_key not in main_cache:
                    main_cache[cache_key] = read_memory(base + block_index * 16,
                                                       min(16, limit - block_index) * 16)
                value = struct.unpack_from('<QIHH', main_cache[cache_key], (index - block_index) * 16)
                address, length, flags, nxt = value
                print_descriptor(table, index, value)
                if flags & ~7:
                    raise InspectError('unknown descriptor flag bits')
                if flags & 4:
                    if indirect:
                        raise InspectError('nested indirect descriptor')
                    if flags & 1:
                        raise InspectError('INDIRECT and NEXT are both set')
                    if not any('INDIRECT_DESC' in name for name in feature_names):
                        raise InspectError('INDIRECT descriptor without negotiated INDIRECT_DESC')
                    if not address or not length or length % 16 or length // 16 > size:
                        raise InspectError('invalid indirect table address/length')
                    print(f'  Indirect table at 0x{address:x}, {length // 16} entries; traversal starts at ID 0')
                    walk(address, length // 16, 0, 'indirect', True)
                    return
                if not flags & 1:
                    return
                index = nxt

        walk(desc_addr, size, args.head, 'main')

    # A simple end check can detect some races, not prove snapshot consistency.
    end_state = queue_state()
    changed = any(end_state.get(k) != state.get(k) for k in
                  ('vring-num', 'vring-desc', 'vring-avail', 'vring-used'))
    if changed:
        print('\nWARNING: ring addresses/size changed during capture; discard this snapshot.')
    elif read_memory(avail_addr, 4) != av_header or read_memory(used_addr, 4) != us_header:
        print('\nNOTE: ring indices/flags changed during capture; rows span different instants.')


try:
    main()
except (InspectError, OSError) as exc:
    print(f'ERROR: {exc}', file=sys.stderr)
    print('A live update/reset can also invalidate a read; retry before diagnosing corruption.', file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    sys.exit(130)
PY
