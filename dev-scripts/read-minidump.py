"""Minimal MINIDUMP reader: what faulted, where, and in which module.

Written 2026-08-30 because Pseudoregalia's "reset to last save" crash produces an
EXCEPTION_ACCESS_VIOLATION with an empty CallStack element in CrashContext.runtime-xml, no
debugger is installed, and six hypotheses have already been refuted by measurement. The one thing
the dump can settle cheaply is whether the faulting address lies inside the mod's own DLL or in
the game's executable -- which decides who the next question is for.

Format per Microsoft's MINIDUMP_HEADER / MINIDUMP_DIRECTORY documentation.
"""
import struct
import sys
import os

EXCEPTION_STREAM = 6
MODULE_LIST_STREAM = 4
THREAD_LIST_STREAM = 3
SYSTEM_INFO_STREAM = 7


def read_u32(b, off):
    return struct.unpack_from('<I', b, off)[0]


def read_u64(b, off):
    return struct.unpack_from('<Q', b, off)[0]


def read_minidump_string(b, rva):
    length = read_u32(b, rva)  # bytes, not chars
    raw = b[rva + 4: rva + 4 + length]
    return raw.decode('utf-16-le', errors='replace')


def main(path):
    with open(path, 'rb') as f:
        b = f.read()

    assert b[:4] == b'MDMP', 'not a minidump: %r' % b[:4]
    stream_count = read_u32(b, 8)
    stream_dir_rva = read_u32(b, 12)

    streams = {}
    for i in range(stream_count):
        off = stream_dir_rva + i * 12
        stype = read_u32(b, off)
        size = read_u32(b, off + 4)
        rva = read_u32(b, off + 8)
        streams[stype] = (size, rva)

    fault_addr = None
    exc_code = None
    if EXCEPTION_STREAM in streams:
        _, rva = streams[EXCEPTION_STREAM]
        # MINIDUMP_EXCEPTION_STREAM: ThreadId(4), __align(4), then MINIDUMP_EXCEPTION
        exc = rva + 8
        exc_code = read_u32(b, exc)
        exc_addr = read_u64(b, exc + 16)
        num_params = read_u32(b, exc + 12)
        params = [read_u64(b, exc + 24 + 8 * i) for i in range(min(num_params, 15))]
        fault_addr = exc_addr
        print('exception code      : 0x%08X' % exc_code)
        print('faulting address    : 0x%016X' % exc_addr)
        if len(params) >= 2:
            kind = {0: 'read', 1: 'write', 8: 'execute'}.get(params[0], str(params[0]))
            print('access violation    : %s of 0x%016X' % (kind, params[1]))

    modules = []
    if MODULE_LIST_STREAM in streams:
        _, rva = streams[MODULE_LIST_STREAM]
        count = read_u32(b, rva)
        for i in range(count):
            # MINIDUMP_MODULE is 108 bytes
            m = rva + 4 + i * 108
            base = read_u64(b, m)
            size = read_u32(b, m + 8)
            name_rva = read_u32(b, m + 12)
            try:
                name = read_minidump_string(b, name_rva)
            except Exception:
                # Some dumps carry a stripped name RVA. That module is still usable for the
                # address-range test, which is the part that matters.
                name = '<unnamed module #%d>' % i
            modules.append((base, size, name))

    print('modules loaded      : %d' % len(modules))
    if fault_addr is not None:
        owner = None
        for base, size, name in modules:
            if base <= fault_addr < base + size:
                owner = (base, size, name)
                break
        if owner:
            print('FAULT IS IN MODULE  : %s' % os.path.basename(owner[2]))
            print('  module base       : 0x%016X' % owner[0])
            print('  offset in module  : 0x%X' % (fault_addr - owner[0]))
        else:
            print('FAULT IS IN MODULE  : <no loaded module covers that address>')

    # Is the mod even loaded, and where?
    for base, size, name in modules:
        low = os.path.basename(name).lower()
        if low in ('main.dll', 'ue4ss.dll') or 'pseudoregalia' in low:
            print('  loaded: %-34s base 0x%016X size 0x%X' % (os.path.basename(name), base, size))


if __name__ == '__main__':
    main(sys.argv[1])
