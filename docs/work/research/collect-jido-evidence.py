"""Read-only public API snapshot; run from the repository root. No source code fetches."""
import concurrent.futures, datetime, json, subprocess, urllib.request, urllib.error
from pathlib import Path
OUT=Path('docs/work/research')
def gh(path):
    p=subprocess.run(['gh','api',path],text=True,capture_output=True)
    if p.returncode: return {'error':p.stderr.strip()}
    return json.loads(p.stdout)
def http(url):
    try:
        with urllib.request.urlopen(url,timeout=30) as r:return json.load(r)
    except Exception as e:return {'error':str(e)}
org=gh('orgs/agentjido/repos?per_page=100')
search=http('https://hex.pm/api/packages?search=jido&sort=name')
excluded={'.github','github-actions','jido_run','jido_presentations','jido_subtree_workspace','awesome-elixir-ai','jido_phx_starter','jido-skills','skills','jido_showcase','jido_delvetown','hancho','jido_agent_os'}
names={r['name']:'agentjido/'+r['name'] for r in org if r['name'] not in excluded}
for p in search:
    link=next((v for v in p['meta']['links'].values() if v.startswith('https://github.com/') and '/issues' not in v and '/blob/' not in v),None)
    if link:names[p['name']]=link.removeprefix('https://github.com/').rstrip('/')
def collect(item):
    name,repo=item
    hex_name = 'llm_db' if name == 'llmdb' else name
    h=http('https://hex.pm/api/packages/'+hex_name)
    g=gh('repos/'+repo)
    c=gh('repos/'+repo+'/commits?per_page=1')
    issues=gh('repos/'+repo+'/issues?state=open&per_page=100')
    contributors=gh('repos/'+repo+'/contributors?per_page=3')
    r={'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'package':name,'repo':repo,'hex_url':'https://hex.pm/api/packages/'+hex_name,'github_url':'https://api.github.com/repos/'+repo}
    if 'error' in h:r['hex']=h
    else:
        r['hex']={k:h.get(k) for k in ['name','meta','latest_version','latest_stable_version','retirements']}
        r['hex']['owners']=[o.get('username') for o in h.get('owners',[])]
        r['hex']['releases']=[x for x in h['releases'] if x['version'] in [h.get('latest_version'),h.get('latest_stable_version')]]
        v=h.get('latest_stable_version') or h.get('latest_version')
        rel=http('https://hex.pm/api/packages/'+hex_name+'/releases/'+v)
        r['hex']['selected_release']=rel
    r['github']={k:g.get(k) for k in ['description','archived','default_branch','license','pushed_at','open_issues_count','error']}
    r['github']['last_commit']=({'sha':c[0]['sha'],'date':c[0]['commit']['committer']['date'],'author':c[0].get('author',{}).get('login') if c[0].get('author') else None} if isinstance(c,list) and c else c)
    r['github']['open_issues_excluding_prs']=sum('pull_request' not in i for i in issues) if isinstance(issues,list) and len(issues)<100 else {'error':'Issue list incomplete or unavailable'}
    r['github']['top_contributors']=[x['login'] for x in contributors] if isinstance(contributors,list) else contributors
    return r
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    rows=list(pool.map(collect,sorted(names.items())))
result={'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'org_repository_names':[r['name'] for r in org],'search_package_names':[p['name'] for p in search],'excluded_org_repos':sorted(excluded),'records':rows}
(OUT/'jido-evidence-2026-11-08.json').write_text(json.dumps(result,indent=2)+'\n')
for r in rows:
    h,g=r['hex'],r['github']
    print(r['package'],h.get('latest_stable_version'),h.get('latest_version'),h.get('meta',{}).get('licenses'),g['last_commit'].get('date'),g['open_issues_excluding_prs'],'ARCHIVED' if g['archived'] else '',h.get('owners'))
