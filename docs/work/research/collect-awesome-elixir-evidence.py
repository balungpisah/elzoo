"""Read-only focused survey, public Hex and GitHub metadata. No source code reads."""
import concurrent.futures,datetime,json,re,subprocess,urllib.request,sys
from pathlib import Path
ROOT=Path('docs/work/research')
NAMES='req_s3 ex_aws ex_aws_s3 aws waffle ash ash_authentication assent oidcc ueberauth guardian bodyguard let_me ash_double_entry ash_money ex_money decimal money stripity_stripe gringotts carbonite ash_paper_trail paper_trail swoosh bamboo pigeon telemetry telemetry_metrics opentelemetry opentelemetry_api opentelemetry_exporter prom_ex logger_json reactor commanded eventstore ash_state_machine ash_oban fuse external_service hammer ex_rated gen_stage broadway broadway_rabbitmq phoenix_pubsub amqp cloak hush hush_aws_secrets_manager crontab oban quantum libcluster delta_crdt horde ra khepri loom explorer flow elasticsearch phoenix_live_view nimble_options bpe fun_with_flags ex_aws_secretsmanager'.split()
INDEX=json.loads((ROOT/'awesome-elixir-index-2026-11-08.json').read_text())
def gh(path):
 p=subprocess.run(['gh','api',path],text=True,capture_output=True)
 return json.loads(p.stdout) if not p.returncode else {'error':p.stderr.strip()}
def http(url):
 try:
  with urllib.request.urlopen(url,timeout=30) as r:return json.load(r)
 except Exception as e:return {'error':str(e)}
def repo_link(h):
 links=h.get('meta',{}).get('links',{})
 for k in ['GitHub','Github','Source','Repository','Source Code','Git']:
  u=links.get(k,'')
  if 'github.com/' in u:return '/'.join(u.split('github.com/',1)[1].strip('/').removesuffix('.git').split('/')[:2])
 for u in links.values():
  if 'github.com/' in u:return '/'.join(u.split('github.com/',1)[1].strip('/').removesuffix('.git').split('/')[:2])
 return None
def collect(n):
 url='https://hex.pm/api/packages/'+n;h=http(url);repo=repo_link(h)
 r={'package':n,'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'hex_url':url,'repo':repo}
 matches=[]
 for sec,lines in INDEX['sections'].items():
  for line in lines:
   if re.search(r'\['+re.escape(n)+r'\]',line,re.I) or (repo and repo.lower() in [u.rstrip('/').removesuffix('.git').lower() for u in re.findall(r'https://github.com/([^/\s)]+/[^/\s)]+)',line)]):matches.append({'section':sec,'line':line})
 r['discovery']='listed' if matches else 'adjacent comparison (not attributed to list)';r['index_matches']=matches
 if 'error' in h:r['hex']=h
 else:
  r['hex']={k:h.get(k) for k in ['name','meta','latest_version','latest_stable_version','retirements']}
  r['hex']['owners']=[o.get('username') for o in h.get('owners',[])]
  r['hex']['releases']=[x for x in h['releases'] if x['version'] in [h.get('latest_version'),h.get('latest_stable_version')]]
  v=h.get('latest_stable_version') or h.get('latest_version');rel=http(url+'/releases/'+v)
  rel.pop('publisher',None);r['hex']['selected_release']=rel
 if not repo:r['github']={'error':'No GitHub URL in Hex metadata'};return r
 g=gh('repos/'+repo);c=gh('repos/'+repo+'/commits?per_page=1')
 r['github']={k:g.get(k) for k in ['full_name','description','archived','default_branch','license','pushed_at','open_issues_count','error']}
 r['github']['last_commit']=({'sha':c[0]['sha'],'date':c[0]['commit']['committer']['date']} if isinstance(c,list) and c else c)
 count=0
 for page in range(1,11):
  issues=gh(f'repos/{repo}/issues?state=open&per_page=100&page={page}')
  if not isinstance(issues,list):count=issues;break
  count+=sum('pull_request' not in i for i in issues)
  if len(issues)<100:break
 else:count={'error':'Pagination limit reached'}
 r['github']['open_issues_excluding_prs']=count
 return r
if __name__ == '__main__':
 target=ROOT/'awesome-elixir-evidence-2026-11-08.json'
 old=json.loads(target.read_text())['records'] if '--retry' in sys.argv and target.exists() else []
 known={r['package']:r for r in old}
 todo=[n for n in NAMES if n not in known or 'error' in known[n]['hex'] or 'error' in known[n]['hex'].get('selected_release',{})]
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  for row in pool.map(collect,todo):known[row['package']]=row
 rows=[known[n] for n in NAMES]
 target.write_text(json.dumps({'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_sha':INDEX['sha'],'records':rows},indent=2)+'\n')
 for r in rows:
  if r['package'] in todo:
   h,g=r['hex'],r['github'];print(r['package'],h.get('latest_stable_version'),h.get('meta',{}).get('licenses'),g.get('last_commit',{}).get('date'),g.get('open_issues_excluding_prs'),g.get('error'),h.get('error'))
