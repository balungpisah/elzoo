# ELZ-054 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)  
Reviewed SHA: `910feec787a54da0b099215675e2ad7940665c34`

Inputs read: live issue #110 Contract; `docs/work/ELZ-054.md` at the reviewed
SHA; the reviewed-SHA diff against `origin/main`; `AGENTS.md`;
`docs/plans/catalogue-dispositions.md` (including the integration/secrets
disagreement); `docs/operational-contracts.md`; `docs/capability-model.md`;
`docs/development/12-change-class-flow.md`; ready `core/effect` and
`delivery/effect-intent` manifests, READMEs, sources and tests; and the pinned
Swoosh 1.29.3 and gen_smtp 1.3.0 package sources.

## Findings

1. **blocking — `docs/work/ELZ-054.md:231-245` and
   `docs/development/12-change-class-flow.md`, class X row.** The proposal says
   `mix.exs`, `mix.lock`, and `config/config.exs` change in the final step of
   the notification Piece. Those are class X changes, and the published flow
   expressly says class X is never combined with a Piece change. Split the
   dependency/runtime-configuration decision into its own class-X change and
   evidence run, then implement the Piece in a separate P change; revise the
   record's class and changed-path sections accordingly.

2. **blocking — `docs/work/ELZ-054.md:325-339`; live issue #110, “Interface
   and invariant”.** `unknown{credentials_unavailable}` and
   `unknown{connect_failed}` are not honest public outcomes when the Adapter
   attests that it never opened a transaction or sent bytes. The issue limits
   `unknown` to a lost connection after handover, while neither listed refusal
   reason covers these known no-send failures. Before implementation, amend the
   issue Contract and synchronize the task record. Exact outcome-set change:

   - Before: `refused{invalid_address | rejected_recipient | too_large | throttled | authentication_failed}`
   - After: `refused{invalid_address | rejected_recipient | too_large | throttled | authentication_failed | credentials_unavailable | connect_failed}`

   Rows 13 and 14 should use those refused reasons while retaining their
   attested `not_dispatched` binding pairs. For Q3, keep
   `unknown{unclassified_reply}` with `dispatched/unclassified` and no rearm:
   gen_smtp collapses transaction-stage failures into one `send` result, so the
   Adapter cannot safely turn every other 5xx into a specific refusal. Amend
   the issue's `unknown` wording exactly as follows so this is within Contract:

   - Before: ``unknown{reason}` when the connection was lost after the message was handed over, mapped to the ELZ-011 delivery result.`
   - After: ``unknown{reason}` when the connection was lost after the message was handed over or the Adapter cannot safely classify a transaction-stage provider response into a listed refusal, mapped to the ELZ-011 delivery result.`

3. **blocking — `docs/work/ELZ-054.md:184-221`, 302-305, and T16.** The
   proposed non-loopback mode requires STARTTLS but does not require peer
   certificate verification. Swoosh's SMTP documentation distinguishes
   `tls: :always` from supplying verification options; gen_smtp's default TLS
   options do not state peer verification. Make verified TLS a construction
   invariant for every non-loopback relay, with an explicit trust/hostname
   configuration Need or safe fixed configuration, reject an absent or unsafe
   setting before the credential Need is called, and add an in-process test
   that an untrusted certificate cannot reach AUTH, MAIL, RCPT, or DATA.

4. **blocking — `docs/work/ELZ-054.md:20-31`, 184-221, T10-T12.** The
   credential Need promises only a tuple, but Swoosh's SMTP adapter raises an
   argument error that inspects a non-binary username, password, or relay
   option. A malformed or hostile Need value could therefore place credential
   material in an exception before the proposed fixed-atom translation. Define
   the Need's accepted value shape and bounds, validate it without interpolation
   or inspection before passing it to Swoosh, catch all downstream exceptions
   at the boundary, and add T12 cases for non-binary and oversize return
   values. The returned error, status, evidence, logs, telemetry, and Config
   inspection must still contain only the fixed classification atom.

5. **blocking — `docs/work/ELZ-054.md:174`, `231-237`; `AGENTS.md`, “Source
   catalogue rules”.** The text says the interface is under
   `pieces/integration/notification/`, but the proposed files instead place
   implementation, Cure, examples, and tests at repository-root `lib/`,
   `cure/`, `examples/`, and `test/` paths. This conflicts with the required
   per-Piece conventional layout and unnecessarily expands the ownership
   surface. Put the listed sources beneath
   `pieces/integration/notification/{lib,cure,examples,test}` and adjust the
   evidence paths and manifest file list to match.

6. **should-fix — `docs/work/ELZ-054.md:116-120, 342-346`.** The source
   evidence is directionally correct but the wording is imprecise: Swoosh
   provides a default API-client application environment, then its default
   client raises when the optional dependency is unavailable; it does not simply
   lack an `api_client` setting. `api_client: false` is plausible because the
   initializer only calls a loaded client, but it is a global Swoosh setting
   that affects other adapters. In the separate class-X decision, state this
   accurately and prove the chosen option with a startup/direct-SMTP smoke
   test; also evaluate `runtime: false`, since direct SMTP does not use the API
   client and that avoids a global application setting.

7. **note — `docs/work/ELZ-054.md:77-120, 262-305`.** The upstream findings
   are substantially verified. `Swoosh.Mailer` creates telemetry metadata with
   the email and supplied config, while direct `Swoosh.Adapters.SMTP.deliver/2`
   does not add that span; `mimemail:get_header_value/3` debug-logs its complete
   header list and Swoosh's SMTP helper calls that encoder in the caller
   process; gen_smtp defaults to one session retry and uses a twenty-minute
   reply timeout; and Swoosh application start initializes its API client.
   Keep the dedicated process-level log suppression and its redaction tests,
   but label the package source and finite local tests as upstream/test
   evidence, not a proof.

8. **note — `docs/work/ELZ-054.md:307-321, 262-305`.** The operational
   applicability declaration and evidence taxonomy are otherwise well scoped:
   Telemetry is correctly `planned` at this base, Config is explicitly
   construction/per-call rather than hot update, and Control belongs to
   `delivery/effect-intent`. The record also correctly keeps provider
   acceptance distinct from delivery, keeps EffectIntent identity stable across
   attempts, disallows blind resend after unknown, avoids real mail in tests,
   and separates proof, type/contract check, test, monitored behavior,
   upstream contract, and unverified assumptions.

## Open-question answers

**Q1 — amend the Contract.** A credential-Need error before connection is an
attested known no-send, not an unknown handover outcome. Use
`refused{credentials_unavailable}` and the exact outcome-set amendment in
finding 2; retain the existing no-send binding mapping so only the owner may
explicitly rearm.

**Q2 — amend the Contract.** A refused connection or a session-stage loss
before transaction commands is also an attested known no-send. Use
`refused{connect_failed}` and the same exact outcome-set amendment; do not
represent it as `unknown` merely because the transport failed.

**Q3 — accept only with the exact wording amendment in finding 2.** For an
unclassified transaction-stage reply, including another 5xx, the adapter lacks
enough stage detail to assert a listed refusal and bytes may already have been
handed over. `unknown{unclassified_reply}` with dispatched/unclassified and no
resend is conservative and honest once the Contract explicitly permits this
form of unknown.

**Q4 — keep proof optional.** The issue requires no proof, and Cure type and
totality checking plus exhaustive table tests are appropriate grounding for the
translation. The offered finite law is useful but must be described as a
selected law over its actual finite input domain, not proof of transport
behavior.

**Q5 — class X, separate from the Piece.** The Swoosh initialization concern
is real, but the configuration/dependency choice has global scope and triggers
class X. Decide and test it in a standalone class-X change with the required
full local check; do not place it in the notification Piece change.

**Q6 — coordinator decision; no copy by default.** The live issue is the
Contract source of truth and its scope does not require a `tasks/` copy. Do not
add one merely for bookkeeping. If the coordinator deliberately elects to
carry a byte-identical copy, it may travel only with the implementation change
after the approved Contract amendment, not with the separate class-X change.

## Verdict

**Proceed after fixes.** Resolve the five blocking findings and obtain the
coordinator's approved live-issue amendment before implementation begins; the
remaining proposal has a sound upstream-reuse direction and a properly bounded
evidence plan.
