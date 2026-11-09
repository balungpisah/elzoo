# ELZ-054 follow-up independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `4de63da764a8383b37dd7ac0de74a5f4f9f87dfc`

Inputs: live issue #110 body and approved amendment comment; `docs/work/ELZ-054.md`
at the reviewed SHA; the diff from `910feec787a54da0b099215675e2ad7940665c34`;
the earlier review at the reviewed SHA; and the pinned Swoosh and gen_smtp
sources.

## Findings

1. **should-fix — `docs/work/ELZ-054.md:85-89`, Contract reading / Outputs.**
   This summary still limits `refused` to the original five reasons, although
   the amended live Contract and the outcome table correctly include
   `credentials_unavailable` and `connect_failed`. This leaves one public
   Contract summary inconsistent with the binding table. Replace that summary
   with the amended seven-reason set and retain the amended `unknown` wording.

## Earlier-finding disposition

1. **Blocking 1 (E1 change-class departure): resolved.** The revision explicitly
   records the one-PR departure, its reason, the required full local check, the
   no-configuration default, the fallback condition and the dependency-diff
   review condition. `runtime: false` is credible for the proposed direct path:
   Swoosh's application is what initializes its API client, while
   `Swoosh.Adapters.SMTP.deliver/2` directly builds gen_smtp options and calls
   `:gen_smtp_client.send_blocking/2`; no application startup occurs in that
   path. T18 remains the necessary executable evidence that the root and Piece
   start without the Swoosh application and that direct SMTP delivery works.

2. **Blocking 2 (E2 outcomes): partly resolved.** The current live body exactly
   matches the approved replacement, and rows 11, 13 and 14 use the approved
   outcomes and binding pairs. It correctly keeps
   `unknown{unclassified_reply}` as dispatched/unclassified with no resend and
   maps a pre-AUTH TLS verification failure to
   `refused{connect_failed}`. Finding 1 above is the remaining stale summary.

3. **Blocking 3 (verified TLS): resolved.** Non-loopback construction requires
   explicit verified trust before the credential function can be called; the
   fixed STARTTLS options require peer verification, a trust set and hostname
   verification. This matches Swoosh's SMTP adapter, which passes
   `tls_options` through, and gen_smtp, which upgrades STARTTLS with those
   options before it attempts AUTH. T16 covers rejection before the Need, and
   T17 covers trusted, untrusted, hostname-mismatched and no-STARTTLS cases
   with no AUTH, MAIL, RCPT or DATA.

4. **Blocking 4 (credential Need and exception boundary): resolved.** The
   accepted shape, binary bounds and control-byte prohibition are explicit;
   validation precedes Swoosh's inspecting configuration check, and the
   downstream boundary is specified to translate exceptions to fixed atoms.
   T12 covers malformed, non-binary, oversize and exceptional Need returns and
   checks both no connection and redaction.

5. **Blocking 5 (Piece layout): resolved.** Every proposed implementation,
   Cure, example and test source is listed under
   `pieces/integration/notification/`.

6. **Should-fix 6 (API-client wording): resolved.** The revision accurately
   distinguishes the Swoosh application API-client initialization from direct
   SMTP adapter use, and records the global effect of the configuration fallback.

7. **Note 7 (evidence terminology): resolved.** The package-source and finite
   probe claims are now labeled as upstream/test evidence, not proof.

8. **Note 8 (operational applicability): resolved.** No further change was
   required; the declarations remain bounded to the stated Adapter behavior.

## Verdict

**Proceed after fixes.** Apply finding 1, then implement and execute T12,
T16, T17 and T18; this review makes no claim that planned tests have run.
