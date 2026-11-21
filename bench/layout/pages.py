#!/usr/bin/env python3
"""pages.py PID BINARY [--syms OUT]: which pages of BINARY are mapped in PID, by ELF section.
With --syms, writes the symbols that overlap a mapped page (name, section, size, kind) and,
to OUT.literals, the numbers of the mapped .rodata.lit.N sections of a probe build.
Called by regen.sh; needs root to read the page map."""
import os, re, struct, subprocess, sys
# The operator names the process and the files. The pid has to be a number and the
# paths are made absolute, so no argument reaches another file under /proc or is
# taken for an option by readelf or nm.
pid, binary = int(sys.argv[1]), os.path.abspath(sys.argv[2])
out = os.path.abspath(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[3] == '--syms' else None
PAGE = 4096
present = set()
with open(f'/proc/{pid}/maps') as maps, open(f'/proc/{pid}/pagemap', 'rb') as pm:
    for line in maps:
        f = line.split()
        if len(f) < 6 or f[5] != binary:
            continue
        a, b = (int(x, 16) for x in f[0].split('-'))
        pm.seek(a // PAGE * 8)
        data = pm.read((b - a) // PAGE * 8)
        for i in range(len(data) // 8):
            if struct.unpack_from('<Q', data, i * 8)[0] >> 63:
                present.add(a + i * PAGE)
sections = []
for line in subprocess.run(['readelf', '-SW', binary], capture_output=True, text=True).stdout.splitlines():  # NOSONAR(S8705) - the local CLI operator explicitly selects this file.
    m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)\s+\S+\s+(\S+)', line)
    if m and 'A' in m.group(4) and int(m.group(2), 16) and m.group(1) != '.tbss':
        sections.append((int(m.group(2), 16), int(m.group(3), 16), m.group(1)))
print(f'{"section":18} {"size":>8} {"touched":>8}  KiB')
for addr, size, name in sections:
    pages = {p for p in range(addr // PAGE * PAGE, addr + size, PAGE)}
    t = len(pages & present)
    if (size >= 4096 or t) and not name.startswith('.rodata.lit.'):
        print(f'{name:18} {size // 1024:8} {t * 4:8}')
print(f'total mapped pages: {len(present) * 4} KiB')
if out:
    syms = []
    for line in subprocess.run(['nm', '-S', '-n', '--defined-only', binary], capture_output=True, text=True).stdout.splitlines():  # NOSONAR(S8705) - the local CLI operator explicitly selects this file.
        f = line.split()
        if len(f) == 4:
            syms.append((int(f[0], 16), int(f[1], 16), f[2], f[3]))
    hot = total = 0
    with open(out, 'w') as o:  # NOSONAR(S8707) - the local CLI operator explicitly selects this file.
        for addr, size, kind, name in syms:
            if not size:
                continue
            total += 1
            if any(p in present for p in range(addr // PAGE * PAGE, addr + size, PAGE)):
                sec = next((n for a, s, n in sections if a <= addr < a + s), '?')
                o.write(f'{name}\t{sec}\t{size}\t{kind}\n'); hot += 1
    print(f'symbols on mapped pages: {hot} of {total} -> {out}')
    with open(out + '.literals', 'w') as o:  # NOSONAR(S8707) - the local CLI operator explicitly selects this file.
        for addr, size, name in sections:
            if name.startswith('.rodata.lit.') and any(p in present for p in range(addr // PAGE * PAGE, addr + size, PAGE)):
                o.write(name.rsplit('.', 1)[1] + '\n')
