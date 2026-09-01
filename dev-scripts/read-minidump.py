"""Minimal MINIDUMP reader: what faulted, where, in which module -- and, since 2026-09-01,
whose CODE was on the crashed thread's stack and what our own PDB calls it.

Written 2026-08-30 because Pseudoregalia's "reset to last save" crash produces an
EXCEPTION_ACCESS_VIOLATION with an empty CallStack element in CrashContext.runtime-xml, no
debugger is installed, and six hypotheses have already been refuted by measurement. The one thing
the dump can settle cheaply is whether the faulting address lies inside the mod's own DLL or in
the game's executable -- which decides who the next question is for.

Extended 2026-09-01, the day that lesson was completed (pitfalls/by-lesson.md, "The
reset-to-save crash"): a use-after-free crashes WHEREVER the garbage points, so "the fault is in
the game's code" exonerates nothing. What IS attributable is the crashed thread's STACK, and the
dump carries it:

  --stack       scavenge the crash thread's stack for return addresses that land inside any
                loaded module, printed in stack order as module+offset. Not a real unwind (stale
                frames appear), but your own module showing up near the top is the lead.
  --symbolize <dll> <offset...>
                resolve module offsets to function+line via dbghelp against the PDB next to the
                given DLL image. Works with zero tools installed -- dbghelp ships with Windows.
                Use the build-output DLL (e.g. build/Mod/Game__Shipping__Win64/main.dll), whose
                .pdb sits beside it; hash-match it against the deployed copy first.

The one-move version of the 2026-09-01 diagnosis:
  python read-minidump.py UEMinidump.dmp --stack
  python read-minidump.py --symbolize <path>/main.dll 0x55564 0x5DCF0

Format per Microsoft's MINIDUMP_HEADER / MINIDUMP_DIRECTORY / MINIDUMP_MODULE /
MINIDUMP_THREAD documentation. (The module-name RVA lives at offset 20 of MINIDUMP_MODULE, after
BaseOfImage/SizeOfImage/CheckSum/TimeDateStamp -- the first version of this read it at 12, which
"worked" by printing the bytes the checksum pointed at, i.e. garbage that looked like a broken
dump rather than a broken reader.)
"""
import re
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


def sanitize(name):
    # A wrong RVA decodes to non-ASCII soup; keep output greppable regardless.
    return re.sub(r'[^\x20-\x7e]', '?', name)


def load_streams(b):
    assert b[:4] == b'MDMP', 'not a minidump: %r' % b[:4]
    stream_count = read_u32(b, 8)
    stream_dir_rva = read_u32(b, 12)
    streams = {}
    for i in range(stream_count):
        off = stream_dir_rva + i * 12
        stype = read_u32(b, off)
        size = read_u32(b, off + 4)
        rva = read_u32(b, off + 8)
        streams.setdefault(stype, (size, rva))
    return streams


def load_modules(b, streams):
    modules = []
    if MODULE_LIST_STREAM in streams:
        _, rva = streams[MODULE_LIST_STREAM]
        count = read_u32(b, rva)
        for i in range(count):
            # MINIDUMP_MODULE is 108 bytes: BaseOfImage u64, SizeOfImage u32, CheckSum u32,
            # TimeDateStamp u32, ModuleNameRva u32, then VS_FIXEDFILEINFO and two locators.
            m = rva + 4 + i * 108
            base = read_u64(b, m)
            size = read_u32(b, m + 8)
            name_rva = read_u32(b, m + 20)
            try:
                name = sanitize(read_minidump_string(b, name_rva))
            except Exception:
                # Some dumps carry a stripped name RVA. That module is still usable for the
                # address-range test, which is the part that matters.
                name = '<unnamed module #%d>' % i
            modules.append((base, size, name))
    return modules


def module_of(modules, addr):
    for base, size, name in modules:
        if base <= addr < base + size:
            return (base, size, name)
    return None


def read_exception(b, streams):
    """Returns (thread_id, code, fault_addr, params) or None."""
    if EXCEPTION_STREAM not in streams:
        return None
    _, rva = streams[EXCEPTION_STREAM]
    # MINIDUMP_EXCEPTION_STREAM: ThreadId(4), __align(4), then MINIDUMP_EXCEPTION
    tid = read_u32(b, rva)
    exc = rva + 8
    code = read_u32(b, exc)
    addr = read_u64(b, exc + 16)
    num_params = read_u32(b, exc + 12)
    params = [read_u64(b, exc + 24 + 8 * i) for i in range(min(num_params, 15))]
    return tid, code, addr, params


def stack_scavenge(b, streams, modules, max_hits=60):
    """Scan the crashed thread's dumped stack, from RSP up, for values that land inside a
    loaded module. Stack order, module+offset per hit. Stale frames appear -- treat it as a
    lead-generator, not an unwind."""
    exc = read_exception(b, streams)
    if not exc:
        print('no exception stream -- nothing to scavenge')
        return
    exc_tid = exc[0]
    # ThreadContext location follows the 152-byte MINIDUMP_EXCEPTION record.
    _, erva = streams[EXCEPTION_STREAM]
    ctx_size, ctx_rva = struct.unpack_from('<II', b, erva + 8 + 152)
    # x64 CONTEXT: Rsp at 0x98, Rip at 0xF8.
    rsp = read_u64(b, ctx_rva + 0x98)
    rip = read_u64(b, ctx_rva + 0xF8)
    o = module_of(modules, rip)
    print('crash thread %d  rip %s  rsp 0x%016X' %
          (exc_tid, ('%s+0x%X' % (os.path.basename(o[2]), rip - o[0])) if o else hex(rip), rsp))

    if THREAD_LIST_STREAM not in streams:
        print('no thread list stream')
        return
    _, trva = streams[THREAD_LIST_STREAM]
    tcount = read_u32(b, trva)
    stack_mem = None
    off = trva + 4
    for _ in range(tcount):
        # MINIDUMP_THREAD (48 bytes): ThreadId, SuspendCount, PriorityClass, Priority, Teb u64,
        # Stack{Start u64, DataSize u32, Rva u32}, ThreadContext{u32,u32}.
        tid = read_u32(b, off)
        s_start = read_u64(b, off + 24)
        s_size = read_u32(b, off + 32)
        s_rva = read_u32(b, off + 36)
        if tid == exc_tid:
            stack_mem = (s_start, s_size, s_rva)
            break
        off += 48
    if not stack_mem:
        print('crash thread has no stack memory in this dump')
        return
    s_start, s_size, s_rva = stack_mem

    begin = max(rsp, s_start)
    data_off = s_rva + (begin - s_start)
    remain = min(s_size - (begin - s_start), len(b) - data_off)
    hits = 0
    for i in range(0, max(remain - 7, 0), 8):
        val = read_u64(b, data_off + i)
        o = module_of(modules, val)
        if o:
            print('  rsp+0x%04X  %s+0x%X' % (i, os.path.basename(o[2]), val - o[0]))
            hits += 1
            if hits >= max_hits:
                print('  ... (capped at %d hits)' % max_hits)
                break


def symbolize(dll_path, offsets):
    """Resolve module offsets to symbol+line using dbghelp against the PDB beside dll_path.
    Windows-only by nature; dbghelp.dll needs no install."""
    import ctypes
    from ctypes import wintypes

    dbghelp = ctypes.WinDLL('dbghelp')
    proc = ctypes.c_void_p(4242)
    SYMOPT_LOAD_LINES = 0x10
    dbghelp.SymSetOptions(SYMOPT_LOAD_LINES)
    if not dbghelp.SymInitializeW(proc, os.path.dirname(os.path.abspath(dll_path)), False):
        sys.exit('SymInitialize failed')
    dbghelp.SymLoadModuleExW.restype = ctypes.c_uint64
    dbghelp.SymLoadModuleExW.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wintypes.LPCWSTR,
                                         wintypes.LPCWSTR, ctypes.c_uint64, ctypes.c_uint32,
                                         ctypes.c_void_p, ctypes.c_uint32]
    base = dbghelp.SymLoadModuleExW(proc, None, os.path.abspath(dll_path), None,
                                    0x10000000, os.path.getsize(dll_path), None, 0)
    if not base:
        sys.exit('SymLoadModuleEx failed -- is the .pdb beside the DLL?')

    class SYMBOL_INFOW(ctypes.Structure):
        _fields_ = [('SizeOfStruct', ctypes.c_uint32), ('TypeIndex', ctypes.c_uint32),
                    ('Reserved', ctypes.c_uint64 * 2), ('Index', ctypes.c_uint32),
                    ('Size', ctypes.c_uint32), ('ModBase', ctypes.c_uint64),
                    ('Flags', ctypes.c_uint32), ('Value', ctypes.c_uint64),
                    ('Address', ctypes.c_uint64), ('Register', ctypes.c_uint32),
                    ('Scope', ctypes.c_uint32), ('Tag', ctypes.c_uint32),
                    ('NameLen', ctypes.c_uint32), ('MaxNameLen', ctypes.c_uint32),
                    ('Name', ctypes.c_wchar * 1024)]

    class IMAGEHLP_LINEW64(ctypes.Structure):
        _fields_ = [('SizeOfStruct', ctypes.c_uint32), ('Key', ctypes.c_void_p),
                    ('LineNumber', ctypes.c_uint32), ('FileName', ctypes.c_wchar_p),
                    ('Address', ctypes.c_uint64)]

    for text in offsets:
        off = int(text, 16) if text.lower().startswith('0x') else int(text, 16)
        addr = base + off
        sym = SYMBOL_INFOW()
        sym.SizeOfStruct = 88  # sizeof up to and including MaxNameLen
        sym.MaxNameLen = 1024
        disp = ctypes.c_uint64(0)
        if dbghelp.SymFromAddrW(proc, ctypes.c_uint64(addr), ctypes.byref(disp), ctypes.byref(sym)):
            line = IMAGEHLP_LINEW64()
            line.SizeOfStruct = ctypes.sizeof(IMAGEHLP_LINEW64)
            ldisp = ctypes.c_uint32(0)
            where = ''
            if dbghelp.SymGetLineFromAddrW64(proc, ctypes.c_uint64(addr), ctypes.byref(ldisp), ctypes.byref(line)):
                where = '  (%s:%d)' % (line.FileName, line.LineNumber)
            print('+0x%X: %s+0x%X%s' % (off, sym.Name, disp.value, where))
        else:
            print('+0x%X: <no symbol>' % off)


def main(argv):
    if argv and argv[0] == '--symbolize':
        symbolize(argv[1], argv[2:])
        return

    path = argv[0]
    want_stack = '--stack' in argv[1:]
    with open(path, 'rb') as f:
        b = f.read()
    streams = load_streams(b)
    modules = load_modules(b, streams)

    exc = read_exception(b, streams)
    fault_addr = None
    if exc:
        _, code, fault_addr, params = exc
        print('exception code      : 0x%08X' % code)
        print('faulting address    : 0x%016X' % fault_addr)
        if len(params) >= 2:
            kind = {0: 'read', 1: 'write', 8: 'execute'}.get(params[0], str(params[0]))
            print('access violation    : %s of 0x%016X' % (kind, params[1]))

    print('modules loaded      : %d' % len(modules))
    if fault_addr is not None:
        owner = module_of(modules, fault_addr)
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

    if want_stack:
        print()
        stack_scavenge(b, streams, modules)


if __name__ == '__main__':
    main(sys.argv[1:])
