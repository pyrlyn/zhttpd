# gdb -q -batch -p PID -x trace.py   (env: TRACE_BIN, TRACE_OUT), called by regen.sh
# One temporary breakpoint per function: records every function the process
# enters from now on, each once.
import gdb, os, subprocess
binary, out = os.environ['TRACE_BIN'], os.environ['TRACE_OUT']
gdb.execute('set pagination off'); gdb.execute('set confirm off')
gdb.execute('set breakpoint always-inserted on')
gdb.execute('handle all nostop noprint pass')
gdb.execute('handle SIGTRAP stop noprint nopass')
names = {}
for line in subprocess.run(['nm', '-S', '-n', '--defined-only', binary], capture_output=True, text=True).stdout.splitlines():
    f = line.split()
    if len(f) == 4 and f[2] in 'tTwW' and int(f[1], 16):
        names.setdefault(int(f[0], 16), (f[3], int(f[1], 16)))
gdb.execute('set python print-stack full')
for addr in names:
    gdb.Breakpoint('*0x%x' % addr, temporary=True, internal=True)
print('armed', len(names), flush=True)
open(out + '.armed', 'w').close()
hits = []
while True:
    try:
        gdb.execute('continue', to_string=True)
        pc = int(gdb.parse_and_eval('$pc'))
    except gdb.error:
        break
    if pc in names:
        hits.append(pc)
with open(out, 'w') as o:
    for pc in hits:
        o.write('%s\t%d\n' % names[pc])
print('hit', len(hits), flush=True)
