# ELZ-108 — Synchronize data-stream backpressure observation

- Phase: validation defect repair, class T.
- Catalogue IDs: delivery/data-stream (existing Contract unchanged).
- Dependencies: ELZ-101, accepted.

## Outcome and grounding

Repair an unsupported ordering assumption in the existing OwnerTest named "no next block or finish is processed while a text offer is unresolved". Receiving a sink message does not fence Session publication or owner processing of its cached summary. The accepted API promises a safe status snapshot, not read-after-sink linearizability. Preserve the actual backpressure invariant and every existing assertion.

The ELZ-107 final gate failed this compound snapshot assertion without exposing its component values. A controlled scratch pause after sink-task launch and before offered-count increment/publication reproduces raw_blocks=3, offered_frames=0, source_complete=false and the original assertion failure on both unchanged baseline and candidate. This demonstrates a possible schedule, not the historical aggregate trace. Keep the failed full run and separate database-settings failures disclosed; do not infer that all failures share this cause.

## Scope and ownership

Own only pieces/delivery/data-stream/test/elzoo/data_stream_owner_test.exs, narrowly necessary test support in that Piece, this publication copy, docs/work/ELZ-108.md, and coordinator-serialized own planning row/generated views. No production source, ready Contract, Piece ID, provider/toolchain/configuration, source-copy harness, CI or runner-policy change. No timeout increase, polling-until-green, changed sink behavior, assertion removal or relaxed count. Preserve ELZ-105/106/107 frozen Contracts and all unrelated work.

After held_frame, establish completion of the current Session offer callback and processing of its prior summaries by the owner before the original authorized caller invokes public Stream.status. A test-only identity system-state callback executed by Session can send an owner system request after Session publication; same-sender ordering then fences processing without changing either process's state. Validate this approach on the actual process path rather than assuming it works. An independent caller reading owner state alone supplies no cross-sender publication fence. Avoid a new reusable runtime abstraction or test hook.

If evidence exposes a genuine production invariant violation, publish an exact reviewed scope amendment before a source fix; a ready behavioral Contract change still requires the new-Piece-ID rule. Do not silently broaden status freshness guarantees.

## Acceptance

1. Read live ELZ-101 Contract and relevant source; record why status-after-sink freshness is not promised, distinguishing summary observation from no-next-block progression.
2. Retain the original exact raw-block/offered-count/completeness assertion, sink_timeout result, acknowledged_frames=0, worker-death and no-FinishFrame assertions. Add only the minimal identity synchronization and necessary cleanup.
3. Controlled scratch validation: the original test fails the stale-summary schedule on baseline/candidate; the revised fence cannot complete while Session is held before publication; release promptly within the unchanged deadline, then the original exact status and terminal/backpressure assertions pass. Exercise ordinary ordering too. Use barriers rather than sleeps to establish ordering, with try/after cleanup.
4. Negative control: temporarily suppress post-offer publication in scratch. The fence must not synthesize counts; the revised exact public assertion must fail. Keep source seams/mutants outside committed production code and remove temporary files after retaining evidence.
5. Run pinned mix setup in the isolated checkout, changed Piece tests and mix check --affected origin/main before push. Keep failure logs and classify failures before reruns. No duplicate default full check is required for this test-only change; exact-head hosted default full remains mandatory.
6. Synchronize this task copy/hash and own planning row/views under coordinator serialization. Obtain independent actual-diff and evidence review at named SHA, dispose of automated findings, merge through the sole coordinated queue ahead of ELZ-107, verify main acceptance, clean only this merged task's refs/worktree and close its issue with evidence. ELZ-107 then merges latest main normally and reruns its final-head full gate unchanged.

Grounding: finite controlled OTP/process and copied-consumer tests, source/Contract analysis and named platform contracts. No new Cure proof, production behavior, stronger snapshot consistency or reconstruction of the historical failing schedule is claimed. No paid calls or unrelated catalogue expansion.
