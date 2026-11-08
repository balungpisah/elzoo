#!/usr/bin/env python3
"""Render docs/plans/catalogue-dispositions.md from hand-authored records and check coverage.

Usage: python3 render_dispositions.py <repo_root> <records_dir> <hex_json> <out_md> <out_check_json>
"""
import json, sys, re, datetime, hashlib
from pathlib import Path
root=Path(sys.argv[1]); recdir=Path(sys.argv[2]); hexp=Path(sys.argv[3]); out_md=Path(sys.argv[4]); out_json=Path(sys.argv[5])
RECORDS=[]
for part in sorted(recdir.glob("records_part*.py")):
    ns={}; exec(part.read_text(), ns); RECORDS+=ns["RECORDS"]
NOTES=[]
if (recdir/"records_notes.py").exists():
    ns={}; exec((recdir/"records_notes.py").read_text(), ns); NOTES=ns["NOTES"]
cat=json.loads((root/"registry/catalogue.json").read_text())["entries"]
cat = cat if isinstance(cat,dict) else {e["id"]:e for e in cat}
plan=json.loads((root/"docs/plans/release-plan.json").read_text())
job_of={e["id"]:e for e in plan["entries"]}
jobs={j["id"]:j for j in plan["jobs"]}
hexd=json.loads(hexp.read_text())["packages"]
rank=json.loads((root/"docs/work/research/ecosystem-ranking-table-2026-11-08.json").read_text())
rank_of={r["id"]:r for r in rank}
OD={
 "OD-A":("the owner's admission rule (every planned and deferred entry is open for development; library-first; demand-led only for gaps outside the catalogue)","owner-decisions-on-the-ecosystem-ranking--2026-11-08"),
 "OD-Q1":("owner answer 1: next admitted batch telemetry, object store, notification, audit log, then ReqLLM, then MCP client, text chunking and pgvector","answers-to-the-six-open-questions-in-ecosystem-ranking-2026-11-08md"),
 "OD-Q2":("owner answer 2: S3-only caller behind an Adapter, req_s3 first; ExAws S3 only if multipart requires it; no Jido VFS now","answers-to-the-six-open-questions-in-ecosystem-ranking-2026-11-08md"),
 "OD-Q3":("owner answer 3: first model Adapter is Anthropic over the hosted API; first tool boundary is an MCP client (ExMCP)","answers-to-the-six-open-questions-in-ecosystem-ranking-2026-11-08md"),
 "OD-Q4":("owner answer 4: first email provider is plain SMTP through Swoosh","answers-to-the-six-open-questions-in-ecosystem-ranking-2026-11-08md"),
 "OD-Q5":("owner answer 5: first audited mutation is the ELZ-023 effect-intent decision record in its PostgreSQL store","answers-to-the-six-open-questions-in-ecosystem-ranking-2026-11-08md"),
 "OD-Q6":("owner answer 6: replication, CRDT, FHIR, media and the UI host have no current caller and stay conditional","answers-to-the-six-open-questions-in-ecosystem-ranking-2026-11-08md"),
 "OD-F1":("product fact 1: object store is MinIO through the S3 API, S3-only caller, req_s3 first","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F2":("product fact 2: ReqLLM calls Anthropic directly, provider key as a Need, no gateway process; TensorZero archived and not used","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F3":("product fact 3: identity is AshAuthentication in the application, OIDC strategy later","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F4":("product fact 4: agent runners are the Claude Code CLI and the Codex CLI as OS processes through the ELZ-029 boundary; no Elixir SDK dependency","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F5":("product fact 5: payments provider deferred until the owner names one","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F6":("product fact 6: message broker deferred; no caller; Broadway when one appears","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F7":("product fact 7: metering source is ReqLLM per-call usage stored through the ready Store","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F8":("product fact 8: observability sink is TimescaleDB on the owner's host; OpenTelemetry export later","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F9":("product fact 9: replication, CRDT, FHIR and media are conditional; no caller","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-F10":("product fact 10: UI host is Phoenix LiveView; the Lustre experiment stays optional","product-facts-for-the-catalogue-tail-owner-2026-11-08-afternoon-wib"),
 "OD-G":("the model gateway is built as Pieces, not run as a service","the-model-gateway-is-built-as-pieces-not-run-as-a-service"),
 "OD-C":("copy, clean-room or adopt: the rule (Jido module by module)","copy-clean-room-or-adopt-the-rule"),
}
ODFILE="../work/research/owner-decisions-2026-11-08.md"
def slug(h):
    h=h.lower().strip(); h=re.sub(r"[^\w\s-]","",h); return re.sub(r"\s","-",h)
od_text=(root/"docs/work/research/owner-decisions-2026-11-08.md").read_text()
anchors={slug(m.group(1)) for m in re.finditer(r"^#+\s+(.*)$",od_text,re.M)}
problems=[]
for k,(t,a) in OD.items():
    if a not in anchors: problems.append(f"owner-decision anchor missing: {k} -> {a}")
targets={k for k,e in cat.items() if e.get("status") in ("planned","deferred")}
ids=[r["id"] for r in RECORDS]
dups={i for i in ids if ids.count(i)>1}
missing=sorted(targets-set(ids)); extra=sorted(set(ids)-targets)
if dups: problems.append(f"duplicate records: {sorted(dups)}")
if missing: problems.append(f"missing records: {missing}")
if extra: problems.append(f"records for non-planned/deferred IDs: {extra}")
REQ=["id","responsibility","disposition","reason","conditions","libraries","ideas","copying","owner","inference","depends_on","caller","invariant","needs","limits","open"]
DISP={"ADOPT","WRAP","FORK","CLEAN-ROOM","REJECT"}
for r in RECORDS:
    for f in REQ:
        if f not in r: problems.append(f"{r['id']}: missing field {f}")
    if r["disposition"] not in DISP: problems.append(f"{r['id']}: bad disposition {r['disposition']}")
    if not r["owner"]: problems.append(f"{r['id']}: no owner decision reference")
    for k in r["owner"]:
        if k not in OD: problems.append(f"{r['id']}: unknown owner key {k}")
    for d in r["depends_on"]:
        if d not in cat: problems.append(f"{r['id']}: unknown dependency {d}")
    for name,ver in r["libraries"]:
        h=hexd.get(name)
        if not h: problems.append(f"{r['id']}: package {name} not in hex record"); continue
        if h.get("latest_stable_version")!=ver: problems.append(f"{r['id']}: {name} {ver} != hex latest stable {h.get('latest_stable_version')}")
        if h.get("selected_retired"): problems.append(f"{r['id']}: {name} {ver} is retired on Hex")
# acyclic over planned/deferred graph
graph={r["id"]:[d for d in r["depends_on"] if d in targets] for r in RECORDS}
state={}
def visit(n,stack):
    if state.get(n)==1: problems.append("cycle: "+" -> ".join(stack+[n])); return
    if state.get(n)==2: return
    state[n]=1
    for m in graph.get(n,[]): visit(m,stack+[n])
    state[n]=2
for n in graph: visit(n,[])
utc=datetime.datetime.now(datetime.timezone.utc).isoformat()
# render
by_fam={}
for r in RECORDS: by_fam.setdefault(r["id"].split("/")[0],[]).append(r)
md=[]
md.append("# Catalogue dispositions for planned and deferred entries\n")
md.append(f"Generated by `docs/work/ELZ-050-tools/render_dispositions.py` from the hand-authored records in `docs/work/ELZ-050-records/`; do not edit by hand. One record for each of the {len(targets)} entries whose status is `planned` or `deferred` in `registry/catalogue.json` ({sum(1 for k in targets if cat[k]['status']=='planned')} planned, {sum(1 for k in targets if cat[k]['status']=='deferred')} deferred). Rendered {utc}.\n")
md.append("These are admission decisions a builder reads before claiming an entry. They promote nothing to ready, change no registry status and publish no task. Each later task still needs its own issue, Contract review, evidence and merge under AGENTS.md. **Owner decisions** are quoted from [the owner record](" + ODFILE + ") with the anchor given; everything marked *reviewer inference* comes from the [consolidated ranking](../work/research/ecosystem-ranking-2026-11-08.md) and the coverage cases, not from the owner. Library versions and licenses are re-read from Hex ([record](../work/ELZ-050-evidence/hex-reverify.json)); a version here is the latest stable release at that time, not a tested pin. Dispositions follow the ranking's definitions: **ADOPT** a pinned dependency behind an Adapter; **WRAP** a narrow Contract or Recipe over an upstream or ready boundary; **CLEAN-ROOM** an independently specified decision with no copied implementation; **FORK** a maintained balungpisah fork with notices (none chosen); **REJECT** a package for a stated use.\n")
md.append("## Build order the owner set\n")
md.append("1. `runtime/telemetry`, 2. `integration/object-store`, 3. `integration/notification`, 4. `state/audit-log` (owner answer 1); then the first `integration/ai-model` boundary; then the `integration/sdk` MCP client and the `integration/search-data` chunking and pgvector slices. Published tasks that were open with the ready label and had no remote task branch when observed at 2026-11-08T13:40Z: `delivery/trigger` (ELZ-027, #44), `state/lease` (ELZ-028, #45), `runtime/os-isolation` (ELZ-029, #46), `domain/money` (ELZ-031, #48); recheck the live issue and `git ls-remote --heads origin task/ELZ-0NN` before claiming, because this snapshot is not a claim lock. The owner order is a priority, not a statement that each task's prerequisites are ready; see the disagreements below. The explicit open owner choices are the payments provider and the message broker; entries that depend on them stay conditional.\n")
md.append("## Disagreements between the ranking, the canonical plan and the owner order\n")
md.append("Recorded as the task Contract requires; nothing is reordered or published automatically.\n")
for t,o,own,nxt in NOTES:
    md.append(f"- **{t}.** {o} Decision owner: {own}. Next: {nxt}")
md.append("")
md.append("## Summary\n")
md.append("| ID | Status | Planning job | Disposition | Chosen library or idea source | Owner decision | Open |\n| --- | --- | --- | --- | --- | --- | --- |")
for fam in sorted(by_fam):
    for r in sorted(by_fam[fam],key=lambda x:x["id"]):
        libs=", ".join(f"{n} {v}" for n,v in r["libraries"]) or (r["ideas"][0] if r["ideas"] else "none")
        md.append(f"| [`{r['id']}`](#{slug(r['id'].replace('/',' '))}) | {cat[r['id']]['status']} | {job_of[r['id']]['job']} | {r['disposition']} | {libs} | {', '.join(r['owner'])} | {'yes' if r['open'] else 'no'} |")
md.append("")
for fam in sorted(by_fam):
    md.append(f"## {fam}\n")
    for r in sorted(by_fam[fam],key=lambda x:x["id"]):
        e=cat[r["id"]]; j=job_of[r["id"]]; rk=rank_of.get(r["id"])
        md.append(f"### {r['id'].replace('/',' ')}\n")
        md.append(f"`{r['id']}` — status **{e['status']}**, planning job {j['job']} ({jobs[j['job']].get('release')}), roadmap disposition `{j['disposition']}`" + (f", ranking R{rk['rank']:02d}" if rk else "") + ".\n")
        md.append(f"- **Responsibility:** {r['responsibility']}")
        md.append(f"- **Disposition:** **{r['disposition']}**. {r['reason']}")
        md.append(f"- **Conditions:** {r['conditions']}")
        if r["libraries"]:
            parts=[]
            for n,v in r["libraries"]:
                h=hexd[n]; parts.append(f"`{n}` {v} ({', '.join(h.get('licenses') or ['license unknown'])}; released {h.get('latest_release_at','')[:10]})")
            md.append("- **Libraries (Hex, re-read):** "+"; ".join(parts)+".")
        if r["ideas"]: md.append("- **Idea sources / comparisons:** "+"; ".join(r["ideas"])+".")
        md.append(f"- **Copying:** {r['copying']}")
        md.append("- **Owner decision:** "+"; ".join(f"[{k}]({ODFILE}#{OD[k][1]}) — {OD[k][0]}" for k in r["owner"])+".")
        inf=r['inference']; inf=inf[len("Reviewer inference: "):] if inf.startswith("Reviewer inference: ") else inf
        md.append(f"- **Reviewer inference:** {inf}")
        deps=", ".join(f"`{d}` ({cat[d].get('status') or 'ready via manifest'})" for d in r["depends_on"]) or "none"
        md.append(f"- **Depends on:** {deps}.")
        md.append(f"- **Caller:** {r['caller']}")
        md.append(f"- **Invariant:** {r['invariant']}")
        md.append(f"- **Needs:** {r['needs']}")
        md.append(f"- **Limits:** {r['limits']}")
        if r["open"]:
            md.append("- **Open questions:** "+" ".join(f"{q} (owner: {o}; next: {n}.)" for q,o,n in r["open"]))
        else:
            md.append("- **Open questions:** none beyond the conditions above.")
        md.append("")
out_md.write_text("\n".join(md).rstrip("\n")+"\n")
check={"utc":utc,"targets":len(targets),"records":len(RECORDS),"missing":missing,"duplicates":sorted(dups),"extra":extra,
       "problems":problems,"pass":not problems,"hex_record_sha256":hashlib.sha256(hexp.read_bytes()).hexdigest(),
       "note":"Documentation coverage check only; not runtime evidence. Owner-decision anchors verified against headings in the merged research file."}
out_json.write_text(json.dumps(check,indent=2)+"\n")
print("records",len(RECORDS),"targets",len(targets),"problems",len(problems)); [print(" -",p) for p in problems]
sys.exit(0 if not problems else 1)
