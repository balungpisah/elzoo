Code.require_file("support/cure_consumer_case_test_helper.exs", __DIR__)

# ELZ-049: `max_cases` caps how many async test modules run at once, for every async module in
# test/ and pieces/, not only the consumer groups. The workflow sets `+S 2:2` on machine B
# and `+S 4:4` on machine A, so the cap is 2 there and 4 on machine A; the three consumer group
# modules therefore run at most two at a time on machine B and up to three on machine A (bounded
# by the module count, not by this cap). Measured basis: PR #90, run 42454973591, where three
# concurrent consumer VMs on two cores hit the 120 s limit.
#
# ELZ-152: `changed_piece_consumer` is excluded by default. test/export_test.exs holds one such test for
# each ready ID that has no per-ID consumer; only the small gate (`mix check --piece`) includes it, for
# the changed IDs. The full check and its five parts never run these tests: the aggregate consumer
# already holds every ready Piece.
ExUnit.start(
  seed: 0,
  timeout: 120_000,
  max_cases: System.schedulers_online(),
  exclude: [:changed_piece_consumer]
)
