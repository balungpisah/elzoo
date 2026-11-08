Code.require_file("support/cure_consumer_case_test_helper.exs", __DIR__)

# ELZ-049: at most one async module per online scheduler. The workflow sets `+S 2:2` on
# macbook-ubuntu and `+S 4:4` on symbolic, so two consumer VMs run at once there and three here.
# Measured basis: PR #90, run 42454973591 (three concurrent VMs on two cores hit the 120 s limit).
ExUnit.start(seed: 0, timeout: 120_000, max_cases: System.schedulers_online())
