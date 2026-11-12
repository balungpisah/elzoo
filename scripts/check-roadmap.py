#!/usr/bin/env python3
"""Check the planning manifest and derive its views; never promote catalogue readiness."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / 'docs/plans/release-plan.json'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique(rows, label):
    result = {row['id']: row for row in rows}
    require(len(result) == len(rows), f'duplicate {label}')
    return result


def dependencies(body):
    line = re.search(r'^- Dependencies: (.+)$', body, re.M)
    require(line is not None, 'missing published dependency declaration')
    return re.findall(r'ELZ-\d+', line[1])


def check(d, live=False):
    jobs = unique(d['jobs'], 'job')
    entries = unique(d['entries'], 'catalogue mapping')
    candidates = unique(d['candidate_gaps'], 'candidate')
    products = unique(d['products'], 'product')
    registry = unique(json.loads((ROOT / 'registry/catalogue.json').read_text())['entries'], 'registry ID')
    baseline = json.loads(subprocess.check_output(['git', 'show', d['baseline'] + ':registry/catalogue.json'], cwd=ROOT, text=True))['entries']
    require(len(baseline) == 97, 'original baseline must contain 97 entries')
    require(set(entries) == set(registry), 'current catalogue IDs differ from roadmap; reconcile additions explicitly')
    require(set(x['id'] for x in baseline) <= set(entries), 'lost original baseline entry')
    for original in baseline:
        if 'manifest' in original:
            manifest = json.loads(subprocess.check_output(['git', 'show', d['baseline'] + ':' + original['manifest']], cwd=ROOT, text=True))
            status = manifest['status']
        else:
            status = original['status']
        require(entries[original['id']]['baseline_status'] == status, 'original baseline status changed')
    require(len(candidates) == 2 and not set(candidates) & set(entries), 'candidate gaps must remain separate')
    require(d['published_aliases'] == {'RC-00': 'ELZ-033'}, 'only RC-00 is published by adoption')
    order = []
    active = set()
    done = set()

    def visit(key):
        require(key in jobs, f'dangling job {key}')
        require(key not in active, f'dependency cycle at {key}')
        if key in done:
            return
        active.add(key)
        j = jobs[key]
        require(j['status'] and j['owner_role'], f'missing planning state/owner: {key}')
        for dep in j['dependencies']:
            require(dep in jobs, f'{key}: dangling dependency {dep}')
            require(jobs[dep]['release'] <= j['release'], f'{key}: prerequisite in later release')
            visit(dep)
        active.remove(key)
        done.add(key)
        order.append(key)

    for key in jobs:
        visit(key)
    output_owners = {}
    for j in jobs.values():
        for output in j['outputs']:
            require(output not in output_owners, f'duplicate primary job output {output}')
            output_owners[output] = j['id']
        for contribution in j.get('contributions', []):
            require(contribution['id'] in entries and contribution['role'], 'invalid secondary contribution')
            require(entries[contribution['id']]['job'] != j['id'], 'primary output also marked secondary')
        require(j['product_aims'] and set(j['product_aims']) <= set(products), f"{j['id']}: invalid product mapping")
        require(all(j['release'] <= products[p]['release'] for p in j['product_aims']), f"{j['id']}: product precedes job release")
        require(set(j['outputs']) <= set(entries) | set(candidates), f"{j['id']}: unknown output")
        if j['kind'] == 'published':
            require(len(j['paths']) == 1, f"{j['id']}: one publication file required")
            require((ROOT / j['paths'][0]).is_file(), f"missing task path {j['paths'][0]}")
            body = (ROOT / j['paths'][0]).read_text()
            require(set(dependencies(body)) == set(j['dependencies']), f"{j['id']}: published dependencies drift")
        else:
            require(j['id'].startswith('RC-') and not j.get('url'), 'proposal accidentally published')
            require(j['blockers'] and j.get('contract') and j.get('acceptance') and j.get('reuse'), f"{j['id']}: incomplete admission brief")
    for e in entries.values():
        require(e['job'] in jobs and e['disposition'] and e['note'], f"incomplete mapping {e['id']}")
        require(e['id'] in jobs[e['job']]['outputs'], f"owner does not name output {e['id']}")
        require(e.get('manifest') == registry[e['id']].get('manifest'), f"catalogue readiness changed: reconcile {e['id']}")
        if 'manifest' in e:
            p = ROOT / e['manifest']
            m = json.loads(p.read_text())
            require(m['id'] == e['id'] and m['status'] == 'ready', f"ready reference drift {e['id']}")
            require(hashlib.sha256(p.read_bytes()).hexdigest() == e['manifest_sha256'], f"ready Contract changed: reconcile {e['id']}")
            require(m['contract'] == e['note'], f"ready Contract summary drift {e['id']}")
    for c in candidates.values():
        require(c['job'] in jobs and c['id'] in jobs[c['job']]['outputs'], 'candidate owner drift')
    for p in products.values():
        for key in p['jobs']:
            require(key in jobs and jobs[key]['release'] <= p['release'], f"{p['id']}: invalid product job")
    gate_ids = {g['id'] for g in d['release_gates'].values()}
    for release, gate in d['release_gates'].items():
        require(gate['job_selector']['release'] == release, 'gate release mismatch')
        require(gate['prior_release_gate'] is None or gate['prior_release_gate'] in gate_ids, 'unknown prior release gate')
        require(gate['prior_release_gate'] is None or gate['prior_release_gate'][:2] < release, 'backwards/cyclic release gate')
    for a in d['dependency_acceptance']:
        subprocess.run(['git', 'merge-base', '--is-ancestor', a['merge_sha'], d['observations']['main']], cwd=ROOT, check=True)
        require(a['review'] and a['acceptance'] and a['merge_checks'], 'missing acceptance references')
        require(all(c['conclusion'] == 'success' for c in a['merge_checks']), 'unsuccessful recorded prerequisite check')
    if live:
        rows = json.loads(subprocess.check_output(['gh', 'issue', 'list', '-R', 'balungpisah/elzoo', '--state', 'all', '--limit', '200', '--json', 'number,body'], text=True))
        by_number = {r['number']: r for r in rows}
        for j in jobs.values():
            if j['kind'] != 'published':
                continue
            body = by_number[j['issue']]['body']
            require(hashlib.sha256(body.encode()).hexdigest() == j['issue_body_sha256'], f"{j['id']}: live task changed; reconcile")
            require(set(dependencies(body)) == set(j['dependencies']), f"{j['id']}: live dependencies differ")
        task = ROOT / jobs['ELZ-033']['paths'][0]
        require(task.read_text() == by_number[55]['body'], 'ELZ-033 must exactly match live #55 body')
    return jobs, entries, candidates, products, order


def gate_jobs(d, jobs, gate):
    s = gate['job_selector']
    return [j['id'] for j in jobs.values() if j['release'] == s['release'] and j['stage'] not in s['exclude_stages']]


def render(d, jobs, entries, candidates, products, order):
    def cell(x):
        return str(x).replace('|', '\\|').replace('\n', ' ')

    def row(*xs):
        return '| ' + ' | '.join(cell(x) for x in xs) + ' |\n'

    md = '# Roadmap views\n\nGenerated by `python3 scripts/check-roadmap.py --write` from [release-plan.json](release-plan.json). Do not edit this view. Read [policy and dispositions](roadmap.md) and [first-wave preflights](preflight.md). Planning snapshots do not lock claims or establish runtime readiness.\n\n'
    md += f"Baseline `{d['baseline']}`; captured {d['captured_at']}.\n\n"
    md += f"Reconciled main `{d['observations']['main']}`. Original baseline status remains in each mapping.\n\n"
    md += '## Products\n\n' + row('Aim', 'Release', 'Outcome / design case', 'Jobs', 'Limit') + row('---', '---', '---', '---', '---')
    for p in products.values():
        md += row(p['id'], p['release'], p['outcome'] + ' / ' + p['coverage_case'], ', '.join(p['jobs']), p['limit'])
    md += '\n## Jobs and published issues\n\n' + row('Job', 'Release / stage', 'Prerequisites', 'Planning status', 'Owner role') + row('---', '---', '---', '---', '---')
    for key in order:
        j = jobs[key];label = f"[{key}]({j['url']})" if j.get('url') else key
        md += row(label, j['release'] + ' / ' + j['stage'], ', '.join(j['dependencies']) or 'none', j['status'], j['owner_role'])
    md += '\n## Catalogue accounting\n\nBaseline status is immutable inventory history, not a current planning status. Ready summaries below are checked against their actual manifests. Primary owner is a planning responsibility, not exhaustive authorship.\n\n'
    md += row('ID', 'Baseline', 'Release / stage', 'Primary owner / product aims', 'Disposition and scoped Contract / gap') + row('---', '---', '---', '---', '---')
    for e in entries.values():
        j = jobs[e['job']];label = f"[{e['id']}](../../{e['manifest']})" if e.get('manifest') else e['id']
        md += row(label,e['baseline_status'],j['release']+' / '+j['stage'],e['job']+' / '+', '.join(j['product_aims']),e['disposition']+': '+e['note'])
    md += '\n## Separate candidate gaps\n\n'
    for c in candidates.values():
        md += f"- `{c['id']}` — {c['job']}: {c['resolution']}\n"
    md += '\n## Release gates\n\nDerived from selectors in the manifest; changing the selected scope changes the gate. No automatic issue publication.\n\n'
    for gate in d['release_gates'].values():
        md += f"### {gate['id']}\n\n{gate['status']}. {gate['acceptance']}\n\nPrerequisites: " + ', '.join(gate_jobs(d, jobs, gate)) + '.\n\n'
        if gate['prior_release_gate']:
            md += 'Prior release gate: ' + gate['prior_release_gate'] + '.\n\n'
    md += '## Agent and workspace registry\n\n'
    for a in d['agent_registry']:
        md += '**' + a['role'] + ':** ' + '; '.join(k.replace('_', ' ') + '=' + str(v) for k, v in a.items() if k != 'role') + '\n\n'
    md += '## Scoped job briefs\n\nPublished acceptance remains in live issue bodies. Proposal briefs are admission inputs, not implementation permission.\n\n'
    for j in jobs.values():
        md += f"### {j['id']}\n\n{j['title']}\n\n"
        if j['kind'] == 'published':
            md += 'Publication copy: ' + ', '.join(f'[{p}](../../{p})' for p in j['paths']) + '.\n\n'
        md += '**Product aims:** ' + ', '.join(j['product_aims']) + '. ' + j.get('product_role', '') + '\n\n'
        for field in ['contract','acceptance','reuse']:
            if j.get(field):
                md += f"**{field.capitalize()}:** {j[field]}\n\n"
        for contribution in j.get('contributions', []):
            md += '**Secondary contribution:** ' + contribution['id'] + ' — ' + contribution['role'] + '\n\n'
        for field in ['selection_gates','blockers']:
            if j.get(field):
                md += f"**{field.replace('_', ' ').capitalize()}:**\n\n" + ''.join('- '+s+'\n' for s in j[field]) + '\n'
    graph = '%% Generated by scripts/check-roadmap.py; edit release-plan.json only.\nflowchart TD\n'
    ident = lambda key: key.replace('-', '_')
    for key in order:
        graph += f'    {ident(key)}["{key}"]\n'
        for dep in jobs[key]['dependencies']:
            graph += f'    {ident(dep)} --> {ident(key)}\n'
    for gate in d['release_gates'].values():
        graph += f'    {ident(gate["id"])}["{gate["id"]}"]\n'
        for dep in gate_jobs(d,jobs,gate) + ([gate['prior_release_gate']] if gate['prior_release_gate'] else []):
            graph += f'    {ident(dep)} --> {ident(gate["id"])}\n'
    md = '\n'.join(line.rstrip() for line in md.splitlines()).rstrip() + '\n'
    return {'views.md': md, 'dependencies.mmd': graph}


def links(paths):
    checked = 0
    for path in paths:
        for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', path.read_text()):
            if re.match(r'^[a-z][a-z0-9+.-]*:', target):
                continue
            location = target.split('#', 1)[0]
            require(not location or (path.parent / location).exists(), f'{path.relative_to(ROOT)}: broken link {target}')
            checked += 1
    return checked


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--write', action='store_true', help='regenerate only the roadmap views')
    p.add_argument('--self-test', action='store_true', help='exercise invalid plan negative controls in memory')
    p.add_argument('--live', action='store_true', help='compare all published dependency declarations and body hashes with GitHub')
    args = p.parse_args()
    d = json.loads(PLAN.read_text())
    result = check(d, args.live)
    if args.self_test:
        mutations = {
            'duplicate primary output': lambda x: x['jobs'][0]['outputs'].append('core/operator'),
            'duplicate entry': lambda x: x['entries'].append(copy.deepcopy(x['entries'][0])),
            'dangling owner': lambda x: x['entries'][0].update(job='NO-JOB'),
            'cycle': lambda x: x['jobs'][0]['dependencies'].append(x['jobs'][0]['id']),
            'later-release prerequisite': lambda x: x['jobs'][0]['dependencies'].append('RC-33'),
            'candidate counted as baseline': lambda x: x['entries'].append({'id': x['candidate_gaps'][0]['id']}),
            'rewritten baseline status': lambda x: x['entries'][0].update(baseline_status='ready'),
            'published dependency drift': lambda x: next(j for j in x['jobs'] if j['id'] == 'ELZ-026')['dependencies'].append('ELZ-004'),
            'invalid product': lambda x: x['jobs'][0]['product_aims'].append('P99'),
        }
        for label, mutate in mutations.items():
            bad = copy.deepcopy(d)
            mutate(bad)
            try:
                check(bad)
            except ValueError:
                continue
            raise ValueError('negative control accepted: ' + label)
        print(f'{len(mutations)} invalid-plan negative controls rejected')
    for name, content in render(d, *result).items():
        path = PLAN.parent / name
        if args.write:
            path.write_text(content)
        else:
            require(path.is_file() and path.read_text() == content, f'stale {name}; run --write')
    paths = list(PLAN.parent.glob('*.md')) + [ROOT / f for f in ['AGENTS.md','GOAL.md','docs/development/01-workflow.md','docs/development/02-task-dag.md','docs/capability-model.md','docs/capability-coverage.md','docs/architecture.md']]
    count = links(paths)
    print(f'ROADMAP CHECK PASSED: {len(result[1])} catalogue IDs; {len(result[2])} separate candidates; {len(result[0])} jobs; {len(result[3])} products; acyclic and release-ordered; generated views agree; {count} local links checked' + ('; live Contracts match' if args.live else ''))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'ROADMAP CHECK FAILED: {error}', file=sys.stderr)
        sys.exit(1)
