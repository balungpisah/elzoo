#!/usr/bin/env python3
"""Reduced probe mutation: real policy owner, real PostgreSQL, no production edit."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = (Path(__file__).parent / "composition.exs").read_text()
old_auth = "def authenticate({:unknown_to_provider, _}, _), do: :error"
old_poll = "poll: fn _ -> {:unavailable, :http_404} end"
assert source.count(old_auth) == source.count(old_poll) == 1
mutant = source.replace(old_auth, "def authenticate({:unknown_to_provider, _}, _), do: :ok")
mutant = mutant.replace(old_poll, "poll: fn _ -> {:unknown_to_provider, :http_404} end")
# Preserve the checked helper dependency even though the mutant is outside the repo.
helper = str(root / "pieces/integration/sql/test/support/durable_log_postgres_test_helper.exs")
mutant = mutant.replace('"../../../pieces/integration/sql/test/support/durable_log_postgres_test_helper.exs"', repr(helper).replace("'", '"'))
env = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", MIX_ENV="test", ERL_FLAGS="+S 4:4 +SDcpu 1 +SDio 1")
assert env.get("ELZOO_TEST_DATABASE_URL"), "Own PostgreSQL URL is required"
with tempfile.TemporaryDirectory(prefix="elz011-composition-mutant-") as tmp:
    path = Path(tmp) / "mutant.exs"
    path.write_text(mutant)
    run = subprocess.run(["mix", "run", str(path)], cwd=root, env=env, capture_output=True, text=True)
    output = run.stdout + run.stderr
    print(output)
    assert run.returncode == 2, f"Expected ExUnit scenario failure, got {run.returncode}"
    assert "test PostgreSQL typed preflight rearm, 404 remains Dispatched, expiry strands" in output
    assert "Result: 6/8 passed" in output
print("404-to-ProviderUnknown mutant rejected by authentication and persisted-state scenarios")
