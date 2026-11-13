"""Check observations, not RC-60 compliance. Standard library only."""
import json
import pathlib
import sys

GLOBALS = set("pairs ipairs next select type tostring tonumber error assert helper_echo string table math _ENV".split())
LIBRARIES = {
    "string": set("byte char find format gmatch gsub len lower match rep reverse sub upper".split()),
    "table": set("concat insert pack remove sort unpack".split()),
    "math": set("abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger min mininteger modf pi rad sin sqrt tan tointeger type".split()),
}
OUTCOMES = {"ok", "steps_exceeded", "memory_exceeded", "depth_exceeded", "value_size_exceeded", "wall_time_exceeded", "unlisted_name", "error"}


def rows(path):
    data = [json.loads(line) for line in pathlib.Path(path).read_text().splitlines()]
    result = {r["case"]: r for r in data}
    assert len(result) == len(data), "duplicate case"
    return result


def audit(result):
    a = result["host_audit:policy"]["detail"]
    assert set(a["environment"]) == GLOBALS, "unexpected policy global"
    for lib, names in LIBRARIES.items():
        assert set(a["environment"][lib]) == names, lib
    assert a["environment"]["_ENV"] == "<cycle>"
    assert a["environment_metatable"] == {"__index": "function"}
    mts = a["shared_metatables"]
    assert {k: v for k, v in mts.items() if k != "string"} == {"nil": "nil", "number": "nil", "boolean": "nil"}
    assert mts["string"] == {"__index": a["environment"]["string"]}


def check(path):
    rs = rows(path)
    for r in rs.values():
        assert {"candidate", "case", "outcome", "detail", "steps"} <= r.keys()
        assert r["candidate"] == "luerl-1.5.1" and r["outcome"] in OUTCOMES
        assert r["steps"] is None, "no native step count exists"
        assert not r.get("host_exception")
        if not r.get("beam_survived", True):
            assert r["outcome"] in {"memory_exceeded", "wall_time_exceeded"}, r
            assert r["beam_exit_code"] == -9 and "watchdog killed BEAM" in r["detail"]
            if r["outcome"] == "memory_exceeded":
                assert r["os_peak_rss_kib"] > 512 * 1024
        assert not r.get("observed_runners_alive", 0), r["case"]
        text = json.dumps(r)
        assert "/home/" not in text and "#PID<" not in text
    cases = pathlib.Path(__file__).resolve().parent.parent / "cases"
    assert {p.stem for p in cases.glob("*.lua")} <= rs.keys()
    audit(rs)
    expected = {
        "limit_steps": "steps_exceeded", "limit_memory": "memory_exceeded",
        "limit_value": "memory_exceeded", "limit_depth": "error",
        "enumeration": "error", "plain_cycle": "error",
        "plain_empty": "ok", "plain_nested": "ok",
        "plain_function": "error", "plain_nested_function": "error",
        "plain_error": "error", "unlisted": "unlisted_name",
        "unlisted:nil": "ok", "native_depth_250": "ok",
        "native_value_2m": "ok", "returned_value_2m": "value_size_exceeded",
        "plain_value_boundary": "ok", "plain_value_over": "ok",
        "wall:diagnostic_blocking_helper": "wall_time_exceeded",
        "catch_pcall_wall:diagnostic_blocking_helper": "wall_time_exceeded",
        "determinism:diagnostic": "error", "determinism_pure": "ok",
        "catch_pcall_steps:diagnostic": "steps_exceeded",
        "catch_pcall_memory:diagnostic": "memory_exceeded",
        "catch_pcall_value:diagnostic": "memory_exceeded",
        "recursive_sugar:default": "error",
        "enumeration:explicit_local": "ok",
    }
    for name, outcome in expected.items():
        assert rs[name]["outcome"] == outcome, (name, rs[name])
    for name in ["limit_depth:explicit_local", "catch_pcall_depth:explicit_local"]:
        assert rs[name]["outcome"] in ["memory_exceeded", "steps_exceeded"]
        assert not rs[name].get("continued", False)
    assert rs["native_depth_250"]["detail"] == 250
    assert rs["native_value_2m"]["detail"] == 2_097_152 and rs["native_value_2m"]["continued"]
    assert rs["plain_value_over"]["detail"] == 1_048_577
    assert rs["plain_error"]["detail"] == "fixed failure"
    assert rs["plain_empty"]["detail"] == []
    assert rs["plain_cycle"]["detail"] == "cyclic_value"
    assert rs["catch_pcall_depth:diagnostic"]["continued"] is True
    for name in ["limit_steps", "limit_memory", "limit_value",
                 "catch_pcall_steps:diagnostic", "catch_pcall_memory:diagnostic",
                 "catch_pcall_value:diagnostic"]:
        assert not rs[name].get("continued", False), name
    assert rs["limit_depth"]["detail"] == "undefined function nil"
    assert rs["recursive_sugar:default"]["detail"] == "undefined function nil"
    assert rs["lua_version:default"]["detail"] == "Lua 5.3"
    assert rs["public_G_swap"]["detail"] == [[1, "table"], [2, "nil"]]
    assert rs["unlisted:nil"]["detail"] is None
    assert rs["empty_loop:trace"]["trace_events"] == ["current_line", "fcall"]
    for name, shared in [("limit_value:default_binary_accounting", False),
                         ("limit_value:shared_binary_accounting", True)]:
        assert rs[name]["include_shared_binaries"] is shared
        assert rs[name]["outcome"] == "memory_exceeded"
    over = rs["reduction_poll_short_overshoot"]
    assert over["outcome"] == "ok" and over["sampled_reductions"] > 1_000_000
    for catcher in ["xpcall", "resume", "wrap"]:
        for limit in ["steps", "depth", "memory", "value"]:
            assert rs[f"catch_{catcher}_{limit}:diagnostic"]["outcome"] == "unlisted_name"
    env = rs["host_audit:policy"]["detail"]["environment"]
    flat = {f"{k}:{v}" for k, v in env.items() if k not in LIBRARIES and k != "_ENV"}
    for lib in LIBRARIES:
        flat.add(f"{lib}:table")
        flat.update(f"{lib}.{k}:{v}" for k, v in env[lib].items())
    inside = set()
    for _, item in rs["enumeration:explicit_local"]["detail"]:
        name, typ = item.rsplit(":", 1)
        while name.startswith("_ENV."):
            name = name[5:]
        if name != "_ENV":
            inside.add(name + ":" + typ)
    assert inside == flat, "source and host enumeration differ"
    fixed = [v for _, v in rs["fixed_names:diagnostic"]["detail"]]
    for item in fixed:
        if item.startswith("string-method."):
            name, typ = item[len("string-method."):].split(":")
            assert typ == env["string"].get(name, "nil")
        else:
            name, typ = item.split(":", 1)
            expected_type = ("function" if name == "pcall" else
                             "table" if name in LIBRARIES else
                             env.get(name, "unlisted name: " + name))
            assert typ == expected_type, (name, typ, expected_type)
    for name in ["cost_recipe", "cost_pure"]:
        assert rs[name + ":cost"]["detail"]["runs"] == 200
    assert rs["driver_completed"]["outcome"] == "ok"
    return rs


if sys.argv[1] == "--audit-only":
    audit(rows(sys.argv[2]))
    print("Policy audit: PASS")
else:
    a, b = map(check, sys.argv[1:3])
    print(f"Schema/shared cases, three-path policy audit, host isolation and plain-data checks: PASS ({len(a)}/{len(b)} lines)")
    for name in ["determinism_pure", "determinism:diagnostic"] + ["determinism_component:" + n for n in ["traversal", "identities", "holes", "numbers", "integer_overflow", "patterns", "errors"]]:
        assert {k: v for k, v in a[name].items() if k != "os_peak_rss_kib"} == {k: v for k, v in b[name].items() if k != "os_peak_rss_kib"}, name
    print("Fresh-BEAM pure and seven isolated determinism components: equal")
    counts = [r[k]["reductions"] for r in [a, b] for k in ["limit_steps"] + [f"limit_steps:repeat:{i}" for i in range(1, 4)]]
    print("Reduction stop samples (host outcomes): " + ",".join(map(str, counts)))
    print("Finite over-budget source accepted at reductions: " + ",".join(str(r["reduction_poll_short_overshoot"]["sampled_reductions"]) for r in [a, b]))
    for name in ["limit_value:default_binary_accounting", "limit_value:shared_binary_accounting"]:
        print(name + " BEAM survival across runs: " + ",".join(str(r[name]["beam_survived"]) for r in [a, b]))
    print("Shared broad determinism records division-by-zero error; explicit recursion distinguishes semantics from depth")
    print("Observed gaps: no native step/depth/value budget; five missing policy functions; shared recursion sugar and division-by-zero incompatibilities")
