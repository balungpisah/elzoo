Code.require_file("support/cure_consumer_case_test_helper.exs", __DIR__)

# ELZ-049: `max_cases` caps how many async test modules run at once, for every async module in
# test/ and pieces/, not only the consumer groups. The workflow sets `+S 2:2` on macbook-ubuntu
# and `+S 4:4` on symbolic, so the cap is 2 there and 4 on symbolic; the three consumer group
# modules therefore run two at a time on macbook-ubuntu and all three on symbolic (bounded by the
# module count, not by this cap). Measured basis: PR #90, run 42454973591, where three
# concurrent consumer VMs on two cores hit the 120 s limit.
ExUnit.start(seed: 0, timeout: 120_000, max_cases: System.schedulers_online())
