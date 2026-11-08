# ELZ-031 G3 persistence comparison through integration/sql — attempt 1 (incomplete)

Status: **incomplete. No comparison result is claimed.** The run stopped after attempt 1
because the pieces coordinator capped host load (no further Mix commands until CLEAR).

## Setup (2026-11-08, Elixir 1.20.4 / OTP 29.1.2)

- Scratch consumer project outside the repository. The `integration/sql` closure
  (`state/event-log`, `state/checkpoint`, `state/outbox`, `integration/sql`) was copied with
  `Elzoo.Export.plan!/3` and `Elzoo.Export.write!/1` from base `5374b96`.
- Dependencies: Cure at `208248063d64e621782cd26dd30698ee42850a89`, `ecto_sql == 3.14.0`,
  `postgrex == 0.22.4`, `jason == 1.4.5`, `decimal == 3.2.0`, `ex_money == 6.3.0`;
  `config :ex_money, auto_start_exchange_rate_service: false`.
- Database: the assigned disposable database through `ELZOO_TEST_DATABASE_URL` (not printed);
  each test creates and drops its own schema.
- Build: `MIX_ENV=test mix deps.get` and `mix compile`, 2026-11-08T15:13:35Z to 15:27:22Z, exit 0.

## Scenarios planned

- Candidate A (ex_money 6.3.0 default form, `Jason.encode!(%Money{})`): EUR `"1.00"`,
  EUR `"1.0"`, JPY 1000, BHD `"1.234"`, HRK `"1.00"`, EUR `"1.005"`, EUR `"-0.05"`.
- Candidate B (Decimal 3.2.0, integer minor units with identity and version):
  EUR `"1.00"`, EUR `"1.0"`, JPY `"1000"`, BHD `"1.234"`, HRK `"1.00"`, EUR `"-0.05"`;
  plus `"1.005"` EUR, `"1.5"` JPY and `"1e3"` EUR at construction.
- Each: append the payloads as records through `Elzoo.DurableLog.Postgres.append/5`, read
  back with `read/4`, validate each record digest with `Elzoo.DurableLog.validate_row/3`,
  decode, compare value and bytes.

## Attempt 1 result (2026-11-08T15:27:46Z to 15:27:47Z, `mix test` exit 2)

Both failures are defects of my probe harness, not observations of either candidate:

```text
  1) test A: ex_money 6.3.0 default form through integration/sql (MoneySqlProbeTest)
     code:  assert {:committed, n} = Postgres.append(store, stream, 0, rows, [])
     right: {:rejected, :invalid_outbox_item}

  2) test B: Decimal 3.2.0 integer minor-unit form through integration/sql (MoneySqlProbeTest)
     ** (MatchError) no match of right hand side value:
         {:error, {:already_started, #PID<0.318.0>}}
     test/money_sql_probe_test.exs:72: MoneySqlProbeTest.__ex_unit_setup_0/1
```

- Failure 1: the probe passed records without the outbox items the Store's append
  validation expects for this fold (it rejected before any write). The fix is to supply
  items as the existing integration/sql tests do (`Elzoo.Outbox.new/6` per record).
- Failure 2: the probe's `on_exit` started a second Repo under the same name while the first
  was still alive. The fix is to reuse or stop the first Repo before cleanup.

## Next action

After CLEAR, fix both harness defects, rerun attempt 2 on the assigned database, and record
the full output here. The provider decision in ELZ-031.md §2.3 does not rest on this file
until then.
