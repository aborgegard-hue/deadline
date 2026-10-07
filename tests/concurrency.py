"""CI-only, real PostgreSQL connections. No Supabase keys or external packages."""
import concurrent.futures
import hashlib
import json
import os
import subprocess
import uuid

URL = os.environ['DATABASE_URL']
def sql(query):
    return subprocess.run(['psql', URL, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', query], check=True, capture_output=True, text=True).stdout

def uid(n):
    return str(uuid.UUID(hashlib.md5(f'deadline-race-{n}'.encode()).hexdigest()))

def rpc(n, action, payload):
    # Test fixture identities only; Supabase verifies real JWTs before setting auth.uid().
    body = json.dumps(payload).replace("'", "''")
    out = sql(f"begin; set local role authenticated; select set_config('request.jwt.claim.sub','{uid(n)}',true); select public.deadline('{action}','{body}'::jsonb); commit;")
    return json.loads(next(line for line in out.splitlines() if line.startswith('{')))

sql('insert into auth.users(id) values '+','.join(f"('{uid(i)}')" for i in range(1, 12)))
try:
    game = rpc(1, 'create', {'name': 'Host', 'capacity': 4})
    assert 'error' not in game, game
    code, gid = game['code'], game['id']
    def join(n): return n, rpc(n, 'join', {'code': code, 'name': f'Player {n}'})
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        joins = list(pool.map(join, range(2, 10)))
    members = [1]+[n for n, result in joins if 'error' not in result]
    assert len(members) == 4, joins
    state = rpc(1, 'state', {'game_id': gid})
    assert len(state['players']) == 4, state
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        deals = list(pool.map(lambda _: rpc(1, 'deal', {'game_id': gid}), range(2)))
    assert sum('error' not in r for r in deals) == 1, deals
    roles = [rpc(n, 'state', {'game_id': gid})['me']['role'] for n in members]
    assert len({r['name'] for r in roles}) == 4, roles
    assert sum(r['is_murderer'] for r in roles) == 1, roles
    print('PASS: 8 simultaneous joins cannot overfill a 4-player lobby.')
    print('PASS: 2 simultaneous deals assign roles once, with exactly 1 murderer.')
finally:
    sql('delete from auth.users where id in ('+','.join(f"'{uid(i)}'" for i in range(1,12))+')')
