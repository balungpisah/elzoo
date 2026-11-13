"""Check two fresh probe runs; no third-party dependencies."""
import json
import pathlib
import sys

OUTCOMES = {
    "ok", "steps_exceeded", "memory_exceeded", "depth_exceeded",
    "value_size_exceeded", "wall_time_exceeded", "unlisted_name", "error",
}
GLOBALS = set("pairs ipairs next select type tostring tonumber error assert helper_echo string table math".split())


def load(path):
    rows = [json.loads(line) for line in pathlib.Path(path).read_text().splitlines()]
    by_name = {r["case"]: r for r in rows}
    assert len(rows) == len(by_name), "duplicate case"
    for r in rows:
        assert r["candidate"] == "lua-1.0.2"
        assert r["outcome"] in OUTCOMES
        assert {"candidate", "case", "outcome", "detail", "steps"} <= r.keys()
        assert r.get("beam_survived", True)
        text = json.dumps(r)
        assert "/home/" not in text and "#PID<" not in text, "private error text"
    cases = pathlib.Path(__file__).resolve().parent.parent / "cases"
    assert {p.stem for p in cases.glob("*.lua")} <= by_name.keys()
    expected = {
        "limit_steps": "steps_exceeded", "limit_depth": "depth_exceeded",
        "limit_memory": "memory_exceeded", "limit_value": "value_size_exceeded",
        "wall:diagnostic_blocking_helper": "wall_time_exceeded",
        "catch_pcall_wall:diagnostic_blocking_helper": "wall_time_exceeded",
        "unlisted": "unlisted_name", "plain_function": "error",
        "plain_nested_function": "error", "plain_cycle": "error",
        "plain_empty": "ok", "plain_nested": "ok", "helper": "ok",
        "helper_number": "ok", "plain_error": "error",
        "plain_value_boundary": "ok", "plain_value_over": "value_size_exceeded",
    }
    for name, outcome in expected.items():
        assert by_name[name]["outcome"] == outcome, name
    assert by_name["limit_steps"]["steps"] == 1_000_000
    assert by_name["plain_error"]["detail"] == "Lua runtime error: fixed failure (at probe:1)"
    audit = by_name["host_allowlist_audit"]["detail"]
    assert set(audit["environment"]) == GLOBALS, "unexpected policy global"
    assert set(audit["environment_metatable"]) == {"__index"}
    string_mt = audit["shared_metatables"]["string"]
    assert set(audit["shared_metatables"]) == {"string"}
    assert set(string_mt) == {"__index"}
    assert string_mt["__index"] == audit["environment"]["string"]
    assert "dump" not in string_mt["__index"]
    assert not {"random", "randomseed"} & audit["environment"]["math"].keys()
    assert by_name["unlisted:nil"]["detail"] is None
    assert by_name["lua_version:default"]["detail"] == "Lua 5.3"
    assert "sandboxed" in by_name["blocked_loader:default"]["detail"]
    for catcher in ["pcall", "xpcall"]:
        for limit in ["steps", "depth", "value"]:
            r = by_name[f"catch_{catcher}_{limit}:diagnostic"]
            assert r["outcome"] == "ok" and r["continued"] is True
        assert by_name[f"catch_{catcher}_memory:diagnostic"]["outcome"] == "memory_exceeded"
    for name in ["table_concat", "string_gsub", "string_format", "string_pack"]:
        r = by_name[f"value_bypass:{name}"]
        assert r["outcome"] == "ok" and r["detail"] == 2_097_152
    for name in ["cost_recipe", "cost_pure"]:
        assert by_name[name + ":cost"]["detail"]["runs"] == 200
    assert by_name["driver_completed"]["outcome"] == "ok"
    return by_name


a, b = map(load, sys.argv[1:3])
print(f"Schema/shared cases, bounds, policy audits, plain data, catchability and BEAM survival: PASS ({len(a)}/{len(b)} lines)")
for name in ["limit_steps", "limit_depth", "limit_memory", "limit_value", "determinism_pure"]:
    assert a[name] == b[name], name
    print(f"Fresh-BEAM comparison {name}: equal")
da, db = (dict(r["determinism:with_pcall"]["detail"]) for r in [a, b])
different = sorted(k for k in da if da[k] != db[k])
print("Fresh-BEAM broad determinism differing fields: " + ",".join(different))
print("Observed gaps: pcall/xpcall continue after runtime limits; four string-size bypasses build 2097152 bytes")
