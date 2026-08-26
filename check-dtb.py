#!/usr/bin/env python3
"""Verify a built device tree actually enables the external display controller.

This exists because the failure mode is silent: if dcp@271c00000 stays
"disabled", everything installs cleanly and the monitor simply stays dark.
Exit 0 = external display enabled.
"""
import struct
import sys


def nodes(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\xd0\x0d\xfe\xed':
        sys.exit(f"{path}: not a device tree blob")
    hdr = struct.unpack('>10I', d[:40])
    off_struct, off_str, size_str, size_struct = hdr[2], hdr[3], hdr[8], hdr[9]
    strs = d[off_str:off_str + size_str]
    i, stack, out, cur = off_struct, [], [], {}
    while i < off_struct + size_struct:
        tok = struct.unpack('>I', d[i:i + 4])[0]
        i += 4
        if tok == 1:                                    # FDT_BEGIN_NODE
            e = d.index(b'\0', i)
            stack.append(d[i:e].decode())
            i = (e + 4) & ~3
            cur = {}
            out.append(('/'.join(stack), cur))
        elif tok == 2:                                  # FDT_END_NODE
            stack.pop()
        elif tok == 3:                                  # FDT_PROP
            ln, no = struct.unpack('>II', d[i:i + 8])
            i += 8
            e = strs.index(b'\0', no)
            cur[strs[no:e].decode()] = d[i:i + ln]
            i = (i + ln + 3) & ~3
        elif tok == 9:                                  # FDT_END
            break
    return out


def main():
    path = sys.argv[1]
    found = {}
    for p, props in nodes(path):
        name = p.split('/')[-1]
        if name in ('dcp@231c00000', 'dcp@271c00000') or name.startswith('mux@'):
            status = props.get('status', b'okay\0').replace(b'\0', b'').decode()
            found[name] = status

    ext = found.get('dcp@271c00000')
    print(f"  {path}")
    for name, status in sorted(found.items()):
        label = {'dcp@231c00000': 'internal display',
                 'dcp@271c00000': 'EXTERNAL display'}.get(name, 'DP crossbar')
        print(f"    {name:16s} {label:17s} status={status}")

    if ext is None:
        print("\n  FAIL: no external display controller in this device tree.")
        return 1
    if ext != 'okay':
        print(f"\n  FAIL: external display controller is '{ext}', expected 'okay'.")
        print("  The fairydust device tree patch did not take effect.")
        return 1
    print("\n  PASS: external display controller is enabled.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
