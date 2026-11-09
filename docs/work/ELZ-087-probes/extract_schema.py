# ELZ-087: mechanical extract of the pinned OpenAI OpenAPI document into a
# self-contained JSON Schema 2020-12 bundle for request/response conformance.
# Usage: python3 -I extract_schema.py <openapi.json> <out.json>
# Rule: the transitive components/schemas closure of CreateResponse, Response and
# ErrorResponse; "#/components/schemas/X" -> "#/$defs/X"; annotation-only keys
# removed (description, example, discriminator, x-*); "oneOf" renamed "anyOf"
# (the document's oneOf branches overlap and OpenAPI tooling selects a branch by
# discriminator; JSON Schema exclusivity would reject the document's own minimal
# request shapes). No other validation keyword is changed.
import hashlib, json, re, sys

COMMIT = "59f5565459caae84f43c49a738248cf2b268a70f"
ROOTS = ["CreateResponse", "Response", "ErrorResponse"]
NAME_MAPS = {"properties", "patternProperties", "$defs", "dependentSchemas"}

src = open(sys.argv[1], "rb").read()
doc = json.loads(src)
schemas = doc["components"]["schemas"]

seen, todo = set(), list(ROOTS)
while todo:
    n = todo.pop()
    if n in seen:
        continue
    seen.add(n)
    todo += re.findall(r'"#/components/schemas/([^"]+)"', json.dumps(schemas[n]))

def clean(o, names=False):
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            if names:
                out[k] = clean(v)
            elif k in ("description", "example", "discriminator") or k.startswith("x-"):
                continue
            elif k == "oneOf":
                out["anyOf"] = clean(v)
            elif k == "$ref" and isinstance(v, str):
                out[k] = v.replace("#/components/schemas/", "#/$defs/")
            else:
                out[k] = clean(v, names=(k in NAME_MAPS))
        return out
    if isinstance(o, list):
        return [clean(x) for x in o]
    return o

bundle = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$comment": "Extract of openai/openai-openapi openapi.json at commit %s (fetched 2026-11-09, source SHA-256 %s, MIT, Copyright (c) OpenAI). Closure of %s; refs rewritten to $defs; description, example, discriminator and x-* keys removed; oneOf renamed anyOf (overlapping branches; exclusivity not checked)."
    % (COMMIT, hashlib.sha256(src).hexdigest(), ", ".join(ROOTS)),
    "$defs": {n: clean(schemas[n]) for n in sorted(seen)},
}
with open(sys.argv[2], "w") as f:
    json.dump(bundle, f, sort_keys=True, separators=(",", ":"))
    f.write("\n")
print(len(seen), "schemas")
