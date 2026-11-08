#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate exhaustive proof case splits; the runtime is the separate template.

Expected labels below are independent relations, not a call to the runtime or
a Python copy of its complete transition function. Shared pure gate functions
remain an explicit proof limit; boundary tests/mutations check their arithmetic.
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVENTS = 'Admit Arm NoSend PermanentNoSend Lost TimedOut Failed Pending NoEffect ProviderUnknown Completed Resume Rearm Expired SchemaInvalid CapacityRefused Uncertain Recover Revise Contradiction Refused'.split()
PHASES = ['Empty()', 'Intended(Fresh(), n)', 'Intended(After(g), n)',
          'Dispatched(origin, n)', 'Definite(g, n)', 'Confirmed(n)', 'Stranded(n)']

def gate(p,e):
    if (p.startswith('Intended') or p.startswith('Definite')) and e=='Revise': return 'revise'
    if p.startswith('Intended') and e=='Arm': return 'arm'
    if p.startswith('Definite') and e=='Rearm': return 'rearm'
    if p.startswith('Dispatched') and e=='ProviderUnknown': return 'replay'
    if p.startswith('Dispatched') and e=='Expired': return 'expired'
    return None

def expected(projection,p,e,q,opens):
    # Creation/retention relations for labels and attempt counter. No next().
    fresh=p.startswith('Intended(Fresh')
    after=p.startswith('Intended(After')
    counter='0' if p=='Empty()' else 'n'
    if projection=='replay_label':
        return 'carry_replay(dependent, g)' if not q and p.startswith('Definite') and e=='Rearm' and opens else 'dependent'
    if projection=='ever_label':
        return 'True()' if not q and p.startswith('Intended') and e=='Arm' and opens else 'ever'
    if projection=='revision_label':
        return 'revisions + 1' if not q and (p.startswith('Intended') or p.startswith('Definite')) and e=='Revise' and opens else 'revisions'
    if projection=='quarantine_label':
        return 'True()' if q or e in ['Uncertain','Recover','Contradiction'] else 'False()'
    if projection=='empty_label':
        return 'True()' if p=='Empty()' and (q or e!='Admit') else 'False()'
    if projection=='dispatch_label':
        return 'True()' if not q and p.startswith('Intended') and e=='Arm' and opens else 'False()'
    if projection=='definite_label':
        if p.startswith('Definite') and (q or (e!='Completed' and (e!='Rearm' or not opens))): return 'Some(g)'
        if not q and p.startswith('Dispatched'):
            if e in ['NoSend', 'PermanentNoSend']: return 'Some(AdapterNoSend())'
            if e=='NoEffect': return 'Some(ProviderNoEffect())'
            if e=='ProviderUnknown' and opens: return 'Some(ProviderReplaySafe())'
        return 'no_ground()'
    if projection=='dispatch_origin':
        if not q and p.startswith('Intended') and e=='Arm' and opens:
            return 'Some(Fresh())' if fresh else 'Some(After(g))'
        return 'no_origin()'
    if projection=='fresh_label':
        created=not q and p=='Empty()' and e=='Admit'
        retained=fresh and (q or (e!='Completed' and (e!='Arm' or not opens)))
        return 'True()' if created or retained else 'False()'
    if projection=='after_label':
        created=not q and p.startswith('Definite') and e=='Rearm' and opens
        retained=after and (q or (e!='Completed' and (e!='Arm' or not opens)))
        return 'Some(g)' if created or retained else 'no_ground()'
    if projection=='attempt_label':
        return 'n + 1' if not q and p.startswith('Intended') and e=='Arm' and opens else counter
    raise AssertionError(projection)

PROJECTIONS=[('replay_history_preserved','replay_label','Bool'),
             ('possibly_sent_history_preserved','ever_label','Bool'),
             ('revision_only_on_permitted_revision','revision_label','Int'),
             ('contradiction_and_uncertainty_freeze','quarantine_label','Bool'),('empty_never_recreated','empty_label','Bool'),('dispatch_action_only_after_arm','dispatch_label','Bool'),
             ('definite_only_with_ground','definite_label','Option(Ground)'),('dispatch_only_after_arm','dispatch_origin','Option(Origin)'),
             ('fresh_only_from_empty','fresh_label','Bool'),
             ('after_only_from_definite','after_label','Option(Ground)'),
             ('attempt_changes_only_on_send','attempt_label','Int')]

def rows(proj, proof):
    lines=['    match quarantined', '      True() ->', '        match phase']
    for p in PHASES:
        v=expected(proj,p,None,True,False)
        lines.append(f'          {p} -> '+(f'reflexive({v})' if proof else v))
    lines+=['      False() ->','        match phase']
    for p in PHASES:
        lines+=[f'          {p} ->','            match event']
        for e in EVENTS:
            expr=gate(p,e)
            if expr:
                lines += [f'              {e}() ->',f'                match {expr}']
                for opened in [True,False]:
                    v=expected(proj,p,e,False,opened)
                    lines.append(f'                  {opened}() -> '+(f'reflexive({v})' if proof else v))
            else:
                v=expected(proj,p,e,False,False)
                lines.append(f'              {e}() -> '+(f'reflexive({v})' if proof else v))
    return '\n'.join(lines)+'\n'

src=HERE.joinpath('ELZ-023-policy.template').read_text()

args='phase: Phase, disarmed: Bool, quarantined: Bool, dependent: Bool, ever: Bool, revisions: Int, history: List(Outcome), event: Event, arm: Bool, rearm: Bool, replay: Bool, expired: Bool, revise: Bool'
vals='phase, disarmed, quarantined, dependent, ever, revisions, history, event, arm, rearm, replay, expired, revise'
for name,proj,ty in PROJECTIONS:
    src+=f'\n  @total true\n  @reducible\n  fn expect_{proj}({args}) -> {ty} =\n'+rows(proj,False)
for name,proj,ty in PROJECTIONS:
    src+=f'\n  fn {name}_gated({args}) -> Equivalent({ty}, {proj}(step_gated(make(phase, disarmed, quarantined, dependent, ever, revisions, history), event, arm, rearm, replay, expired, revise)), expect_{proj}({vals})) =\n'+rows(proj,True)
# Actual public laws instantiate arbitrary-Boolean lemmas with real Cure guards.
state='make(phase, disarmed, quarantined, dependent, ever, revisions, history)'
actual=f'phase, disarmed, quarantined, dependent, ever, revisions, history, event, can_arm({state}, config), can_rearm({state}, config), replay_valid(config), recovery_expired(config), can_revise({state}, config)'
for name,proj,ty in PROJECTIONS:
    src+=f'\n  fn {name}(phase: Phase, disarmed: Bool, quarantined: Bool, dependent: Bool, ever: Bool, revisions: Int, history: List(Outcome), event: Event, config: Config) -> Equivalent({ty}, {proj}(step({state}, event, config)), expect_{proj}({actual})) =\n    {name}_gated({actual})\n'
src+='end\n'
Path('pieces/delivery/effect-intent/cure/elzoo/effect_intent.cure').write_text(src)
print('Generated effect_intent.cure:',len(src.encode()),'bytes')
