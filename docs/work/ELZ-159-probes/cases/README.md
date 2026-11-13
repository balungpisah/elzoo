# Shared cases

Each .lua file is one case, shared unchanged by candidates. limit_* cover steps,
non-tail call depth, total allocation and string doubling. catch_* wrap each of
these in all four catching interfaces, then return the continuation sentinel.
escape_* follow the expression in each source; fixed_names probes standard names
and string method lookups; enumeration recursively walks the actual _ENV.
determinism includes policy pcall for error observations. plain_thread is expected
to fail at the absent coroutine global under policy; the host also runs it in a
diagnostic coroutine-enabled mode to test returned-thread rejection.
cost_* are the two fixed workloads. wall uses a diagnostic blocking helper only.
The drivers must distinguish diagnostic capabilities from policy capabilities.
