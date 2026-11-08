#!/usr/bin/env python3
"""Re-read Hex metadata (read-only GET) for every package named by the disposition records.

Usage: python3 hex_reverify.py <records_dir> <out_json>
Records: latest stable version, licenses, latest release date, whether the latest stable release is retired.
"""
import json, sys, urllib.request, datetime, time
from pathlib import Path
recdir=Path(sys.argv[1]); out=Path(sys.argv[2])
names=set()
for part in sorted(recdir.glob("records_part*.py")):
    ns={}; exec(part.read_text(), ns)
    for r in ns["RECORDS"]:
        for n,_ in r["libraries"]: names.add(n)
res={}
for n in sorted(names):
    req=urllib.request.Request(f"https://hex.pm/api/packages/{n}",headers={"User-Agent":"elzoo-elz050-hex-reverify","Accept":"application/json"})
    try:
        with urllib.request.urlopen(req,timeout=30) as f: d=json.load(f)
    except urllib.error.HTTPError as e:
        res[n]={"error":f"HTTP {e.code}"}; print("ERROR",n,e.code); continue
    latest=d.get("latest_stable_version"); rels={r["version"]:r for r in d.get("releases",[])}
    res[n]={"latest_stable_version":latest,"latest_version":d.get("latest_version"),"licenses":d.get("meta",{}).get("licenses"),
            "latest_release_at":rels.get(latest,{}).get("inserted_at"),"selected_retired":latest in (d.get("retirements") or {}),
            "repo":d.get("meta",{}).get("links",{}).get("GitHub")}
    time.sleep(0.2)
out.write_text(json.dumps({"utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),"source":"https://hex.pm/api/packages/<name>","packages":res},indent=2)+"\n")
print("packages",len(res))
