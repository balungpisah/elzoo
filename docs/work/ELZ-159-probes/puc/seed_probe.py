"""Compare hash traversal and identity over 50 fresh OS processes per build."""
import json
import pathlib
import struct
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent
SOURCE = b"""local t={}; for i=1,64 do t['key'..i]=i end
local p={}; for k,v in pairs(t) do p[#p+1]=k end
local n={}; local k=nil; repeat k=next(t,k); if k~=nil then n[#n+1]=k end until k==nil
return {pairs=table.concat(p,','),next=table.concat(n,','),identity=tostring({})}"""


def sample(executable):
    p = subprocess.Popen(['prlimit', '--as=268435456', '--', str(ROOT / executable), 'policy'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        assert json.loads(p.stdout.readline()) == {'ready': True}
        p.stdin.write(struct.pack('>I', len(SOURCE)) + SOURCE)
        p.stdin.flush()
        row = json.loads(p.stdout.readline())
        assert row['outcome'] == 'ok', row
        return dict(row['detail'])
    finally:
        p.stdin.close()
        p.wait(timeout=3)


for executable in ['host', 'host-fixed-seed']:
    samples = [sample(executable) for _ in range(50)]
    print(json.dumps({'candidate': 'puc-5.4.9', 'case': 'seed:' + executable,
                      'outcome': 'ok', 'steps': None, 'detail': {
                          'fresh_processes': 50,
                          'distinct_pairs_orders': len({s['pairs'] for s in samples}),
                          'distinct_next_orders': len({s['next'] for s in samples}),
                          'distinct_table_identities': len({s['identity'] for s in samples})}}))
