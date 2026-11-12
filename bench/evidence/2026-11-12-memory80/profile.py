import asyncio, json, os, pathlib, re, signal, subprocess, time
root=pathlib.Path.home()/'zhttpd-memory-nginx-10'
out=root/'memory80-profile'
out.mkdir(exist_ok=True)
(out/'logs').mkdir(exist_ok=True)
source=(root/'candidate/bench/results/20261112-032814/nginx.conf').read_text()
source=source.replace('49880','49890').replace('49881','49891')
conf=out/'nginx.conf';conf.write_text(source)
header=re.compile(r'^[0-9a-f]+-[0-9a-f]+\s+(\S+)\s+\S+\s+\S+\s+\S+\s*(.*)$')
def snapshot(pid,name,stage):
    pids=[pid]+[int(p) for p in pathlib.Path(f'/proc/{pid}/task/{pid}/children').read_text().split()]
    processes=[]
    for index,p in enumerate(pids):
        raw=pathlib.Path(f'/proc/{p}/smaps').read_text()
        (out/f'{name}-{stage}-{index}.smaps').write_text(raw)
        entries=[]
        for line in raw.splitlines():
            match=header.match(line)
            if match:
                entries.append({'permissions':match[1],'path':match[2] or '[anonymous]','rss':0,'pss':0})
            elif entries and line.startswith(('Rss:', 'Pss:')):
                k,_,value=line.partition(':');entries[-1][k.lower()]=int(value.split()[0])
        groups={}
        for e in entries:
            group=e['path']
            g=groups.setdefault(group,{'rss':0,'pss':0})
            for k in g:g[k]+=e[k]
        processes.append({'role':'master' if index==0 else 'worker','rss':sum(e['rss'] for e in entries),'pss':sum(e['pss'] for e in entries),'mappings':groups})
    result={'binary':name,'stage':stage,'rss':sum(p['rss'] for p in processes),'pss':sum(p['pss'] for p in processes),'processes':processes}
    print(json.dumps(result),flush=True)
    return result
async def run(name,binary):
    import ssl
    clients=[]
    with (out/f'{name}.log').open('w') as log:
        proc=subprocess.Popen([str(binary),'-p',str(out)+'/', '-c',str(conf),'-g','daemon off;'],start_new_session=True,stdout=log,stderr=log)
        try:
            await asyncio.sleep(.3)
            assert proc.poll() is None,(name,log.name)
            results=[snapshot(proc.pid,name,'idle')]
            context=ssl._create_unverified_context()
            async def connect(tls):
                reader,writer=await asyncio.open_connection('127.0.0.1',49891 if tls else 49890,ssl=context if tls else None)
                writer.write(b'GET /static/small.html HTTP/1.1\r\nHost: localhost\r\n\r\n')
                head=await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'),5)
                assert b'200 OK' in head,head
                assert len(await reader.readexactly(612))==612
                return writer
            for tls,stage in ((False,'http64'),(True,'tls64')):
                clients.extend(await asyncio.gather(*(connect(tls) for _ in range(64))))
                await asyncio.sleep(.1)
                results.append(snapshot(proc.pid,name,stage))
            return results
        finally:
            for writer in clients:writer.close()
            os.killpg(proc.pid,signal.SIGTERM)
            proc.wait(timeout=10)
async def main():
    binaries=[('optimized',root/'candidate/.run/gc/bin/zhttpd'),('nginx',pathlib.Path.home()/'zhttpd-perf-h2-h3/nginx/sbin/nginx')]
    small=root/'candidate/.run/small80/bin/zhttpd'
    if small.exists():binaries.append(('release-small',small))
    results=[]
    for name,binary in binaries:results.extend(await run(name,binary))
    (out/'profile.json').write_text(json.dumps(results,indent=2)+'\n')
asyncio.run(main())
