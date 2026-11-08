# ELZ-031 G3 provider comparison: ex_money 6.3.0 versus Decimal 3.2.0

Status: **complete (attempt 3, exit 0).** Selection: **Decimal 3.2.0** (section "Selection").
Attempt 1 stopped on probe-harness defects; attempt 2 ran every scenario but its cleanup
failed; attempt 3 passed. All three are recorded below. Slot granted by the pieces
coordinator on 2026-11-08 for this comparison (targeted `mix test` only, one Mix process,
database `elzoo_pieces_4` only).

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


## Attempt 2 (2026-11-08T16:35:27Z to 16:35:28Z, `mix test` exit 2)

Fixes after attempt 1: one nonce per append batch (the Store requires every record of a
batch to carry the batch nonce; attempt 1 used one nonce per record, which the Store refuses
with `invalid_outbox_item` before any write), one Repo for the module, a database guard, and
all four axes for both candidates. All five scenarios ran and printed the same observations
as attempt 3. The module's `on_exit` cleanup then failed with
`DBConnection.Holder.checkout ... ** (EXIT) shutdown`, because the Repo linked to the
`setup_all` process was shutting down; ExUnit reported the setup_all callback failure for all
five tests. The probe schema of that run was left in the assigned database. Two integer lists
printed as charlists (inspect option).

## Attempt 3 (2026-11-08T16:35:46Z to 16:35:47Z, `mix test` exit 0, 5 passed)

Fixes after attempt 2: the Repo is unlinked from `setup_all` and stopped by the cleanup; the
guard drops leftover `elz031_probe_%` schemas after it verifies the database; integer lists
print as lists. Command, from the scratch consumer directory:

```sh
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'
unset MIX_ENV MIX_DEPS_PATH MIX_BUILD_PATH ERL_LIBS
export ELZOO_TEST_DATABASE_URL=ecto://<assigned role>@localhost:5432/elzoo_pieces_4
MIX_ENV=test mix test test/money_sql_probe_test.exs --seed 0
```

Guard: before any statement, the URL path must be `elzoo_pieces_4`; the first statement is
`SELECT current_database()`, which must also return `elzoo_pieces_4`, before any DDL.

Output (every `PROBE` line, in order; ExUnit progress dots kept where they share a line):

```text
PROBE guard: URL path and current_database() both elzoo_pieces_4
PROBE guard: dropped leftover probe schema elz031_probe_4966df0b
PROBE guard: dropped leftover probe schema elz031_probe_536df954
PROBE PostgreSQL observed: server_version=17.11 (Homebrew) fsync=on synchronous_commit=on
PROBE construct "EUR" "1.00": A=Money.new(:EUR, "1.00") | B={:ok, {"EUR", 978, 2, 100}}
PROBE construct "eur" "1.00": A=Money.new(:EUR, "1.00") | B={:ok, {"EUR", 978, 2, 100}}
PROBE construct " EUR" "1.00": A={:error, {Money.UnknownCurrencyError, "The currency \" EUR\" is not known."}} | B={:error, {:malformed_code, " EUR"}}
PROBE construct "EU" "1": A={:error, {Money.UnknownCurrencyError, "The currency \"EU\" is not known."}} | B={:error, {:malformed_code, "EU"}}
PROBE construct "E$R" "1": A={:error, {Money.UnknownCurrencyError, "The currency \"E$R\" is not known."}} | B={:error, {:malformed_code, "E$R"}}
PROBE construct "XYZ" "1": A={:error, {Money.UnknownCurrencyError, "The currency \"XYZ\" is not known."}} | B={:error, {:unknown_currency, "XYZ"}}
PROBE construct "978" "1": A={:error, {Money.UnknownCurrencyError, "The currency \"1\" is not known."}} | B={:error, {:malformed_code, "978"}}
PROBE construct "EUR" "1.005": A=Money.new(:EUR, "1.005") | B={:error, {:scale_overflow, %{code: "EUR", exponent: 2, scale: 3}}}
PROBE construct "JPY" "1.5": A=Money.new(:JPY, "1.5") | B={:error, {:scale_overflow, %{code: "JPY", exponent: 0, scale: 1}}}
PROBE construct "BHD" "1.2345": A=Money.new(:BHD, "1.2345") | B={:error, {:scale_overflow, %{code: "BHD", exponent: 3, scale: 4}}}
PROBE construct "EUR" "1e3": A=Money.new(:EUR, "1E+3") | B={:error, {:malformed_amount, "1e3"}}
PROBE construct "EUR" "+1.00": A=Money.new(:EUR, "1.00") | B={:error, {:malformed_amount, "+1.00"}}
PROBE construct "EUR" " 1.00 ": A=Money.new(:EUR, "1.00") | B={:error, {:malformed_amount, " 1.00 "}}
PROBE construct "EUR" "1,00": A={:error, {Money.Invalid, "Unable to create money from \"EUR\" and \"1,00\""}} | B={:error, {:malformed_amount, "1,00"}}
PROBE construct "EUR" "": A={:error, {Money.Invalid, "Unable to create money from \"EUR\" and \"\""}} | B={:error, {:malformed_amount, ""}}
PROBE construct "EUR" "NaN": A={:error, {Money.InvalidAmountError, "Invalid money amount. Found Decimal.new(\"NaN\")."}} | B={:error, {:malformed_amount, "NaN"}}
PROBE float: A new={:error, {Money.InvalidAmountError, "Float amounts are not supported in new/2 due to potential rounding and precision issues.  If absolutely required, use Money.from_float/2"}} | B is_integer guard: probe accepts only strings and integers
.PROBE allocate EUR 100 [1, 1, 1]: A split(3)={Money.new(:EUR, "0.33"), Money.new(:EUR, "0.01")} (ratios ignored) | B=%{first: {[34, 33, 33], 1}, last: {[33, 33, 34], 1}, spread: {[34, 33, 33], 1}}
PROBE allocate EUR 200 [1, 1, 1]: A split(3)={Money.new(:EUR, "0.66"), Money.new(:EUR, "0.02")} (ratios ignored) | B=%{first: {[68, 66, 66], 2}, last: {[66, 66, 68], 2}, spread: {[67, 67, 66], 2}}
PROBE allocate EUR -100 [1, 1, 1]: A split(3)={Money.new(:EUR, "-0.33"), Money.new(:EUR, "-0.01")} (ratios ignored) | B=%{first: {[-34, -33, -33], -1}, last: {[-33, -33, -34], -1}, spread: {[-34, -33, -33], -1}}
PROBE allocate EUR 100 [1, 2]: A split(2)={Money.new(:EUR, "0.50"), Money.new(:EUR, "0.00")} (ratios ignored) | B=%{first: {[34, 66], 1}, last: {[33, 67], 1}, spread: {[34, 66], 1}}
PROBE allocate JPY 1000 [1, 1, 1]: A split(3)={Money.new(:JPY, "333"), Money.new(:JPY, "1")} (ratios ignored) | B=%{first: {[334, 333, 333], 1}, last: {[333, 333, 334], 1}, spread: {[334, 333, 333], 1}}
PROBE allocate BHD 1234 [1, 1, 1]: A split(3)={Money.new(:BHD, "0.411"), Money.new(:BHD, "0.001")} (ratios ignored) | B=%{first: {[412, 411, 411], 1}, last: {[411, 411, 412], 1}, spread: {[412, 411, 411], 1}}
.PROBE JPY 1000: A to_integer_exp={:JPY, 1000, 0, Money.new(:JPY, "0")} json={"currency":"JPY","amount":"1000"} | B={"JPY", 392, 0, 1000} decimal=1000
PROBE BHD 1.234: A to_integer_exp={:BHD, 1234, -3, Money.new(:BHD, "0.000")} json={"currency":"BHD","amount":"1.234"} | B={"BHD", 48, 3, 1234} decimal=1.234
.PROBE probe-a append => {:committed, 7}
PROBE probe-a read 7 rows; every record digest validates
PROBE A Money.new(:EUR, "1.00") bytes={"currency":"EUR","amount":"1.00"} decoded=Money.new(:EUR, "1.00") equal?=true struct==true
PROBE A Money.new(:EUR, "1.0") bytes={"currency":"EUR","amount":"1.0"} decoded=Money.new(:EUR, "1.0") equal?=true struct==true
PROBE A Money.new(:JPY, "1000") bytes={"currency":"JPY","amount":"1000"} decoded=Money.new(:JPY, "1000") equal?=true struct==true
PROBE A Money.new(:BHD, "1.234") bytes={"currency":"BHD","amount":"1.234"} decoded=Money.new(:BHD, "1.234") equal?=true struct==true
PROBE A Money.new(:HRK, "1.00") bytes={"currency":"HRK","amount":"1.00"} decoded=Money.new(:HRK, "1.00") equal?=true struct==true
PROBE A Money.new(:EUR, "1.005") bytes={"currency":"EUR","amount":"1.005"} decoded=Money.new(:EUR, "1.005") equal?=true struct==true
PROBE A Money.new(:EUR, "-0.05") bytes={"currency":"EUR","amount":"-0.05"} decoded=Money.new(:EUR, "-0.05") equal?=true struct==true
PROBE A EUR 1.00 vs 1.0: Money.equal?=true same_bytes?=false
.PROBE probe-b append => {:committed, 6}
PROBE probe-b read 6 rows; every record digest validates
PROBE B EUR "1.00" bytes="elzoo-money/1 2026-09-17 EUR 978 2 100" decoded={"EUR", 978, 2, 100} decimal=1.00
PROBE B EUR "1.0" bytes="elzoo-money/1 2026-09-17 EUR 978 2 100" decoded={"EUR", 978, 2, 100} decimal=1.00
PROBE B JPY "1000" bytes="elzoo-money/1 2026-09-17 JPY 392 0 1000" decoded={"JPY", 392, 0, 1000} decimal=1000
PROBE B BHD "1.234" bytes="elzoo-money/1 2026-09-17 BHD 048 3 1234" decoded={"BHD", 48, 3, 1234} decimal=1.234
PROBE B HRK "1.00" bytes="elzoo-money/1 2026-09-17 HRK 191 2 100" decoded={"HRK", 191, 2, 100} decimal=1.00
PROBE B EUR "-0.05" bytes="elzoo-money/1 2026-09-17 EUR 978 2 -5" decoded={"EUR", 978, 2, -5} decimal=-0.05
PROBE B EUR 1.00 vs 1.0: same_bytes?=true
.PROBE cleanup: dropped schema elz031_probe_d71fa16f
Result: 5 passed
```

PostgreSQL settings above are a named local observation only, not a production claim.

## Reading of the observations

| Axis | ex_money 6.3.0 (A) | Decimal 3.2.0 integer form (B, probe-local) |
| --- | --- | --- |
| Untrusted code strings | one `Money.UnknownCurrencyError` for `" EUR"`, `"EU"`, `"E$R"`, `"XYZ"`; `"978"` reported as `"1"` | `malformed_code` for `" EUR"`, `"EU"`, `"E$R"`, `"978"`; `unknown_currency` for `"XYZ"` |
| Untrusted amount strings | `"1.005"` EUR, `"1.5"` JPY, `"1.2345"` BHD, `"1e3"`, `"+1.00"`, `" 1.00 "` accepted | finer scale gives `scale_overflow`; `"1e3"`, `"+1.00"`, `" 1.00 "`, `"1,00"`, `""`, `"NaN"` give `malformed_amount` |
| Allocation | `Money.split/2` takes a count, not ratios; `[1, 2]` becomes an even split; remainder returned apart | ratios honoured; every placement sums to the total; residual placed per the rule |
| 0/3 exponents | `to_integer_exp` gives JPY exponent 0, BHD -3 | JPY 1000 and BHD 1234 minor units; Decimal renders `1000` and `1.234` |
| integration/sql | committed and read back; digests validate; equal values `EUR 1.00` and `EUR 1.0` persist as different bytes | committed and read back; digests validate; `EUR 1.00` and `EUR 1.0` persist as the same bytes |

The B column is a probe-local implementation of the proposed design, not the Piece. Its
results show that the design is workable over Decimal 3.2.0 and integration/sql; the Piece's
own tests must establish its behaviour.

## Selection

**Decimal 3.2.0 is selected; ex_money 6.3.0 is not adopted for `domain/money`.** Reasons,
each from the table above: ex_money does not distinguish malformed from unknown codes,
accepts sub-minor-unit and non-canonical amount strings without a rejection, has no ratio
allocation, and persists equal values as different bytes through integration/sql. Each of
these would need an Elzoo layer over ex_money, and that layer would be the whole Contract;
ex_money would then add its dependencies and a CLDR currency table that differs from the
ISO data. This selects the provider for this Piece; it is not a judgement of ex_money for
formatting or exchange rates, which are out of scope. Under the coordinator's conditional
authorization, this selection enables the `mix.exs` pin `{:decimal, "== 3.2.0"}`, the
`registry/providers.json` entry and the root test `test/elz031_money_persistence_test.exs`.

## Probe source (scratch consumer `test/money_sql_probe_test.exs`)

```elixir
# ELZ-031 G3 provider comparison, attempt 2. Scratch consumer only: the copied
# state/event-log + integration/sql bundle, real PostgreSQL on the assigned database.
Code.require_file("support/durable_log_postgres_test_helper.exs", __DIR__)

defmodule MoneySqlProbeTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, Record, TestMigration, TestRepo}

  @url PostgresHarness.database_url!()
  @assigned "elzoo_pieces_4"
  @limits %{max_record_bytes: 256, max_batch_size: 16, max_checkpoint_bytes: 10_000}

  def reduce(n, _, _, _), do: n + 1

  defp fold,
    do: %{initial: 0, kinds: %{"amount" => :state_bearing}, versions: [1], destinations: ["sink"], reduce: &__MODULE__.reduce/4}

  defp out(line), do: IO.puts("PROBE " <> line)

  # ── candidate B: Decimal 3.2.0 with integer minor units (probe-local) ──
  @registry %{"EUR" => {978, 2}, "JPY" => {392, 0}, "BHD" => {48, 3}, "HRK" => {191, 2}}
  @version "2026-09-17"

  defp b_parse_code(text) do
    cond do
      not Regex.match?(~r/\A[A-Za-z]{3}\z/, text) -> {:error, {:malformed_code, text}}
      not Map.has_key?(@registry, String.upcase(text)) -> {:error, {:unknown_currency, String.upcase(text)}}
      true -> {:ok, String.upcase(text)}
    end
  end

  defp b_from_string(code, text) do
    with {:ok, alpha} <- b_parse_code(code),
         {numeric, exponent} = Map.fetch!(@registry, alpha),
         true <- (byte_size(text) <= 40 and Regex.match?(~r/\A-?(0|[1-9][0-9]*)(\.[0-9]+)?\z/, text)) || {:error, {:malformed_amount, text}},
         [int | frac] = String.split(text, "."),
         frac = List.first(frac, ""),
         true <- byte_size(frac) <= exponent || {:error, {:scale_overflow, %{code: alpha, exponent: exponent, scale: byte_size(frac)}}} do
      {sign, digits} = if String.starts_with?(int, "-"), do: {-1, String.trim_leading(int, "-")}, else: {1, int}
      minor = sign * String.to_integer(digits <> String.pad_trailing(frac, exponent, "0"))
      {:ok, {alpha, numeric, exponent, minor}}
    end
  end

  defp b_encode({alpha, numeric, exponent, minor}),
    do: "elzoo-money/1 #{@version} #{alpha} #{String.pad_leading(Integer.to_string(numeric), 3, "0")} #{exponent} #{minor}"

  defp b_decode(bytes) do
    ["elzoo-money/1", @version, alpha, numeric, exponent, minor] = String.split(bytes, " ")
    {alpha, String.to_integer(numeric), String.to_integer(exponent), String.to_integer(minor)}
  end

  defp b_to_decimal({_a, _n, exponent, minor}),
    do: Decimal.new(if(minor < 0, do: -1, else: 1), abs(minor), -exponent)

  defp b_allocate(total, ratios, placement) do
    sum = Enum.sum(ratios)
    shares = Enum.map(ratios, &div(total * &1, sum))
    residual = total - Enum.sum(shares)
    positive = for {r, i} <- Enum.with_index(ratios), r > 0, do: i
    step = if residual < 0, do: -1, else: 1

    deltas =
      case placement do
        :first -> %{hd(positive) => residual}
        :last -> %{List.last(positive) => residual}
        :spread -> positive |> Enum.take(abs(residual)) |> Map.new(&{&1, step})
      end

    parts = shares |> Enum.with_index() |> Enum.map(fn {s, i} -> s + Map.get(deltas, i, 0) end)
    {parts, residual}
  end

  # ── candidate A: ex_money 6.3.0 default persisted form ──
  defp a_encode(money), do: Jason.encode!(money)

  defp a_decode(bytes) do
    %{"currency" => c, "amount" => a} = Jason.decode!(bytes)
    Money.new(c, a)
  end

  # ── database guard and store ──
  defp guard! do
    target = URI.parse(@url).path |> to_string() |> String.trim_leading("/")
    if target != @assigned, do: raise("refusing: ELZOO_TEST_DATABASE_URL targets #{inspect(target)}, not #{@assigned}")
    {:ok, repo} = TestRepo.start_link(url: @url, pool_size: 2, log: false)
    Process.unlink(repo)
    [[db]] = SQL.query!(TestRepo, "SELECT current_database()", [], log: false).rows
    if db != @assigned, do: raise("refusing: connected to #{inspect(db)}, not #{@assigned}")
    out("guard: URL path and current_database() both #{db}")

    leftovers =
      SQL.query!(TestRepo, "SELECT nspname FROM pg_namespace WHERE nspname LIKE 'elz031_probe_%' ORDER BY 1", [], log: false).rows
      |> List.flatten()

    for name <- leftovers do
      SQL.query!(TestRepo, "DROP SCHEMA #{Postgres.identifier(name)} CASCADE", [], log: false)
      out("guard: dropped leftover probe schema #{name}")
    end

    repo
  end

  setup_all do
    repo = guard!()
    prefix = "elz031_probe_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    SQL.query!(TestRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix, log: false)

    observations =
      for name <- ["server_version", "fsync", "synchronous_commit"] do
        [[value]] = SQL.query!(TestRepo, "SHOW #{name}", [], log: false).rows
        "#{name}=#{value}"
      end

    out("PostgreSQL observed: " <> Enum.join(observations, " "))

    on_exit(fn ->
      SQL.query!(TestRepo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [], log: false)
      out("cleanup: dropped schema #{prefix}")
      Supervisor.stop(repo)
    end)

    store = Postgres.store(TestRepo, prefix: prefix, fold: fold(), limits: @limits)
    %{store: store}
  end

  defp round_trip(store, stream, payloads) do
    nonce = :crypto.strong_rand_bytes(16)

    rows =
      payloads
      |> Enum.with_index(1)
      |> Enum.map(fn {payload, seq} ->
        r = %Record{stream: stream, sequence: seq, kind: "amount", schema_version: 1, payload: payload, nonce: nonce}
        %{r | digest: Log.digest(r)}
      end)

    result = Postgres.append(store, stream, 0, rows, [])
    out("#{stream} append => #{inspect(result)}")
    assert {:committed, n} = result
    assert n == length(rows)
    assert {:ok, read, _head} = Postgres.read(store, stream, 1, 100)
    for r <- read, do: assert(:ok == Log.validate_row(r, fold(), @limits))
    out("#{stream} read #{length(read)} rows; every record digest validates")
    Enum.map(read, & &1.payload)
  end

  test "axis 1: construction from untrusted strings" do
    inputs = [{"EUR", "1.00"}, {"eur", "1.00"}, {" EUR", "1.00"}, {"EU", "1"}, {"E$R", "1"}, {"XYZ", "1"}, {"978", "1"},
              {"EUR", "1.005"}, {"JPY", "1.5"}, {"BHD", "1.2345"}, {"EUR", "1e3"}, {"EUR", "+1.00"}, {"EUR", " 1.00 "}, {"EUR", "1,00"}, {"EUR", ""}, {"EUR", "NaN"}]

    for {c, t} <- inputs do
      a = try do Money.new(c, t) rescue e -> {:raised, Exception.message(e)} end
      out("construct #{inspect(c)} #{inspect(t)}: A=#{inspect(a)} | B=#{inspect(b_from_string(c, t))}")
    end

    out("float: A new=#{inspect(Money.new(:EUR, 1.5))} | B is_integer guard: probe accepts only strings and integers")
  end

  test "axis 2: allocation residuals" do
    for {code, total, ratios} <- [{:EUR, 100, [1, 1, 1]}, {:EUR, 200, [1, 1, 1]}, {:EUR, -100, [1, 1, 1]}, {:EUR, 100, [1, 2]}, {:JPY, 1000, [1, 1, 1]}, {:BHD, 1234, [1, 1, 1]}] do
      m = Money.from_integer(total, code)
      a = Money.split(m, length(ratios))
      b = for p <- [:first, :last, :spread], into: %{}, do: {p, b_allocate(total, ratios, p)}
      for {_p, {parts, _r}} <- b, do: assert(Enum.sum(parts) == total)
      out("allocate #{code} #{total} #{inspect(ratios)}: A split(#{length(ratios)})=#{inspect(a)} (ratios ignored) | B=#{inspect(b, charlists: :as_lists)}")
    end
  end

  test "axis 3: 0- and 3-exponent currencies" do
    jpy = Money.from_integer(1000, :JPY)
    bhd = Money.from_integer(1234, :BHD)
    {:ok, bjpy} = b_from_string("JPY", "1000")
    {:ok, bbhd} = b_from_string("BHD", "1.234")
    out("JPY 1000: A to_integer_exp=#{inspect(Money.to_integer_exp(jpy))} json=#{a_encode(jpy)} | B=#{inspect(bjpy)} decimal=#{Decimal.to_string(b_to_decimal(bjpy), :normal)}")
    out("BHD 1.234: A to_integer_exp=#{inspect(Money.to_integer_exp(bhd))} json=#{a_encode(bhd)} | B=#{inspect(bbhd)} decimal=#{Decimal.to_string(b_to_decimal(bbhd), :normal)}")
    assert elem(bjpy, 3) == 1000 and elem(bbhd, 3) == 1234
  end

  test "axis 4a: ex_money 6.3.0 default form through integration/sql", %{store: store} do
    monies = [Money.new(:EUR, "1.00"), Money.new(:EUR, "1.0"), Money.new(:JPY, 1000), Money.new(:BHD, "1.234"), Money.new(:HRK, "1.00"), Money.new(:EUR, "1.005"), Money.new(:EUR, "-0.05")]
    payloads = Enum.map(monies, &a_encode/1)
    back = round_trip(store, "probe-a", payloads)
    assert back == payloads

    for {m, bytes} <- Enum.zip(monies, back) do
      d = a_decode(bytes)
      out("A #{inspect(m)} bytes=#{bytes} decoded=#{inspect(d)} equal?=#{Money.equal?(m, d)} struct==#{m == d}")
    end

    [e100, e10 | _] = monies
    out("A EUR 1.00 vs 1.0: Money.equal?=#{Money.equal?(e100, e10)} same_bytes?=#{a_encode(e100) == a_encode(e10)}")
  end

  test "axis 4b: Decimal 3.2.0 integer form through integration/sql", %{store: store} do
    inputs = [{"EUR", "1.00"}, {"EUR", "1.0"}, {"JPY", "1000"}, {"BHD", "1.234"}, {"HRK", "1.00"}, {"EUR", "-0.05"}]
    amounts = Enum.map(inputs, fn {c, t} -> {:ok, a} = b_from_string(c, t); a end)
    payloads = Enum.map(amounts, &b_encode/1)
    back = round_trip(store, "probe-b", payloads)
    assert back == payloads
    assert Enum.map(back, &b_decode/1) == amounts

    for {{c, t}, bytes} <- Enum.zip(inputs, back),
        do: out("B #{c} #{inspect(t)} bytes=#{inspect(bytes)} decoded=#{inspect(b_decode(bytes))} decimal=#{Decimal.to_string(b_to_decimal(b_decode(bytes)), :normal)}")

    [e100, e10 | _] = payloads
    out("B EUR 1.00 vs 1.0: same_bytes?=#{e100 == e10}")
  end
end
```
