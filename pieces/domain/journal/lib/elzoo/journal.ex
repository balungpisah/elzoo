# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Journal do
  @moduledoc """
  A balanced money journal over a consumer-owned Ecto Repo on PostgreSQL 19 (ELZ-297).

  Accounts keep a stored balance in their own currency, any `domain/money` registry currency with
  an integer numeric code and minor unit. An operation posts 2..64 same-currency postings whose
  sum is zero, all or nothing, under one operation identity; a reversal posts the negation of an
  earlier operation once, linked to it. An account opened with `allow_negative: false` (a wallet)
  never goes below zero.

  Every write runs in its own transaction through `Elzoo.TenantIsolation.transact/3` at READ
  COMMITTED (a consumer Need that the journal checks and cannot set) and locks the touched
  account rows one at a time in byte order of `account_id`. The zero-sum and balance decisions
  are the Cure module `Cure.Elzoo.Journal`.

  Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount. The Piece
  emits no telemetry and no log; its queries pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.Money
  alias Elzoo.Money.{Amount, Currency}
  alias Elzoo.TenantIsolation

  @cure :"Cure.Elzoo.Journal"
  @message "invalid journal prefix or options"
  @max_postings 64
  @max_history 1000
  @max_version Integer.pow(2, 63) - 1
  @refusals [
    :invalid,
    :currency_mismatch,
    :unbalanced,
    :in_transaction,
    :conflict,
    :retired_currency,
    :unknown_account,
    :unknown_operation,
    :already_reversed,
    :not_reversible,
    :insufficient_funds,
    :amount_range,
    :isolation,
    :registry,
    :unavailable
  ]

  @enforce_keys [:repo, :prefix, :registry]
  defstruct @enforce_keys

  @doc """
  A journal value: exactly `repo:` and `prefix:`, and optionally `registry:` (the compiled
  `Elzoo.Money.Registry.default/0`, the default, or a registry or checked value that
  `Elzoo.Money.Registry.check/1` accepts). Any other registry is checked once here and the
  journal keeps its checked value. Raises `ArgumentError` with one fixed message otherwise.
  """
  def new(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.sort(Keyword.keys(opts)) in [[:prefix, :repo], [:prefix, :registry, :repo]],
         repo when is_atom(repo) and repo not in [nil, true, false] <- opts[:repo],
         {:ok, registry} <- kept(Keyword.get(opts, :registry, Money.Registry.default())) do
      prefix!(opts[:prefix])
      %__MODULE__{repo: repo, prefix: opts[:prefix], registry: registry}
    else
      _ -> raise ArgumentError, @message
    end
  end

  # The default as the compiled value (one === per Money call); any other registry checked once.
  defp kept(registry) do
    if registry === Money.Registry.default(),
      do: {:ok, Money.Registry.default()},
      else: Money.Registry.check(registry)
  end

  @doc false
  # The quoted schema name, shared with Elzoo.Journal.Migration.install/1.
  def prefix!(prefix) do
    if identifier?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  defp identifier?(name), do: is_binary(name) and name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  # The per-call registry check of journal/1; new/1 ran the deep check once. A checked value by
  # Registry.valid?/1 (constant time for it), any other value by its key shape.
  defp registry?(%Money.Registry.Checked{} = registry), do: Money.Registry.valid?(registry)
  defp registry?(registry), do: match?(%{versions: [_ | _], snapshots: %{}}, registry)

  # ── accounts ────────────────────────────────────────────────────────────

  @doc """
  Open an account `%{account_id, currency, allow_negative}` in `tenant`: `{:ok, :applied}`, or
  `{:ok, :duplicate}` when an equal account exists (also after its currency retired).
  """
  def open_account(journal, tenant, request) do
    with {:ok, j} <- journal(journal),
         {:ok, account} <- account_shape(j, tenant, request),
         :ok <- outside(j) do
      run(j, tenant, fn ->
        with :ok <- isolation(j), do: open(j, tenant, account, true)
      end)
    end
  end

  defp account_shape(j, tenant, %{account_id: id, currency: c, allow_negative: allow} = request)
       when map_size(request) == 3 and is_boolean(allow) do
    if text?(tenant, 128) and text?(id, 128) and currency?(j.registry, c),
      do: {:ok, %{account_id: id, currency: c, identity: identity(c), allow_negative: allow}},
      else: {:error, :invalid}
  end

  defp account_shape(_j, _tenant, _request), do: {:error, :invalid}

  defp open(j, tenant, account, insert?) do
    rows =
      query!(
        j,
        "SELECT currency_alpha, currency_numeric, currency_minor_unit, allow_negative FROM #{table(j, :accounts)} WHERE tenant = $1 AND account_id = $2",
        [tenant, account.account_id]
      )

    case rows do
      [[alpha, numeric, minor, allow]] ->
        if {alpha, numeric, minor} == account.identity and allow == account.allow_negative,
          do: {:ok, :duplicate},
          else: {:error, :conflict}

      [] when insert? ->
        with :ok <- active(j, account.currency) do
          {alpha, numeric, minor} = account.identity

          inserted =
            query(
              j,
              "INSERT INTO #{table(j, :accounts)} (tenant, account_id, currency_alpha, currency_numeric, currency_minor_unit, allow_negative, balance, version) VALUES ($1, $2, $3, $4, $5, $6, 0, 0) ON CONFLICT (tenant, account_id) DO NOTHING",
              [tenant, account.account_id, alpha, numeric, minor, account.allow_negative]
            )

          # A concurrent open of the same account committed first: compare with it.
          if inserted.num_rows == 1, do: {:ok, :applied}, else: open(j, tenant, account, false)
        end
    end
  end

  # ── post ────────────────────────────────────────────────────────────────

  @doc """
  Post `%{operation_id, actor_ref, reason, postings}` in `tenant`, `postings` a list of 2..64
  `%{account_id, amount}` in one currency identity with a zero sum: `{:ok, :applied}` or
  `{:ok, :duplicate}`.
  """
  def post(journal, tenant, request) do
    with {:ok, j} <- journal(journal),
         {:ok, op} <- post_shape(j, tenant, request),
         :ok <- outside(j) do
      run(j, tenant, fn ->
        with :ok <- isolation(j),
             :inserted <- identify(j, tenant, op),
             :ok <- active(j, op.currency),
             do: apply_postings(j, tenant, op.operation_id, op.identity, op.postings)
      end)
    end
  end

  defp post_shape(
         j,
         tenant,
         %{operation_id: id, actor_ref: actor, reason: reason, postings: list} = r
       )
       when map_size(r) == 4 do
    with true <- text?(tenant, 128) and text?(id, 128) and text?(actor, 128) and text?(reason, 256),
         {:ok, postings} <- postings(j.registry, list, []) do
      identities = postings |> Enum.map(&identity(&1.amount.currency)) |> Enum.uniq()
      units = Enum.map(postings, & &1.amount.minor_units)

      case apply(@cure, :postings, [units, length(identities) == 1]) do
        :JournalBalanced ->
          [first | _] = postings
          pairs = Enum.map(postings, &{&1.account_id, &1.amount.minor_units})
          [identity] = identities

          {:ok,
           %{
             operation_id: id,
             reverses: nil,
             actor_ref: actor,
             reason: reason,
             currency: first.amount.currency,
             identity: identity,
             postings: pairs,
             digest:
               digest([
                 {"kind", "post"},
                 {"operation_id", id},
                 {"actor_ref", actor},
                 {"reason", reason},
                 {"postings", postings_bytes(identity, pairs)}
               ])
           }}

        :JournalCurrencyMismatch ->
          {:error, :currency_mismatch}

        :JournalUnbalanced ->
          {:error, :unbalanced}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp post_shape(_j, _tenant, _request), do: {:error, :invalid}

  # A proper list of 2..64 postings, each account at most once, no zero amount, every amount a
  # registry member with an integer numeric code and minor unit.
  defp postings(_registry, [], acc) do
    ids = Enum.map(acc, & &1.account_id)

    if length(acc) >= 2 and length(Enum.uniq(ids)) == length(ids),
      do: {:ok, Enum.reverse(acc)},
      else: :error
  end

  defp postings(registry, [%{account_id: id, amount: amount} = p | rest], acc)
       when map_size(p) == 2 and length(acc) < @max_postings do
    if text?(id, 128) and amount?(registry, amount),
      do: postings(registry, rest, [p | acc]),
      else: :error
  end

  defp postings(_registry, _list, _acc), do: :error

  defp amount?(registry, %Amount{currency: c, minor_units: u}),
    do: is_integer(u) and u != 0 and abs(u) < Money.bound() and currency?(registry, c)

  defp amount?(_registry, _other), do: false

  defp currency?(registry, %Currency{numeric: n, minor_unit: m} = c)
       when is_integer(n) and is_integer(m),
       do: Money.member(registry, c) == :ok

  defp currency?(_registry, _other), do: false

  defp identity(%Currency{alpha: a, numeric: n, minor_unit: m}), do: {a, n, m}

  # A currency retired in the newest held version takes no new account or post.
  defp active(j, currency) do
    case Money.current_status(currency, registry: j.registry) do
      {:ok, :active} -> :ok
      {:ok, _retired} -> {:error, :retired_currency}
    end
  end

  # ── reverse ─────────────────────────────────────────────────────────────

  @doc """
  Reverse `%{operation_id, reverses, actor_ref, reason}` in `tenant`: post, as `operation_id`
  linked to `reverses`, the negation of every posting of that operation. `{:ok, :applied}` or
  `{:ok, :duplicate}`.
  """
  def reverse(journal, tenant, request) do
    with {:ok, j} <- journal(journal),
         {:ok, op} <- reverse_shape(tenant, request),
         :ok <- outside(j) do
      run(j, tenant, fn ->
        with :ok <- isolation(j),
             :inserted <- identify(j, tenant, op),
             {:ok, postings} <- original(j, tenant, op.reverses),
             do: apply_postings(j, tenant, op.operation_id, nil, postings)
      end)
    end
  end

  defp reverse_shape(
         tenant,
         %{operation_id: id, reverses: target, actor_ref: actor, reason: reason} = r
       )
       when map_size(r) == 4 do
    if text?(tenant, 128) and text?(id, 128) and text?(target, 128) and text?(actor, 128) and
         text?(reason, 256) and id != target,
       do:
         {:ok,
          %{
            operation_id: id,
            reverses: target,
            actor_ref: actor,
            reason: reason,
            digest:
              digest([
                {"kind", "reverse"},
                {"operation_id", id},
                {"reverses", target},
                {"actor_ref", actor},
                {"reason", reason}
              ])
          }},
       else: {:error, :invalid}
  end

  defp reverse_shape(_tenant, _request), do: {:error, :invalid}

  # The negated postings of an operation that is not itself a reversal.
  defp original(j, tenant, target) do
    case query!(
           j,
           "SELECT reverses FROM #{table(j, :operations)} WHERE tenant = $1 AND operation_id = $2",
           [tenant, target]
         ) do
      [] ->
        {:error, :unknown_operation}

      [[nil]] ->
        rows =
          query!(
            j,
            "SELECT account_id, minor_units::text FROM #{table(j, :postings)} WHERE tenant = $1 AND operation_id = $2",
            [tenant, target]
          )

        {:ok, Enum.map(rows, fn [id, units] -> {id, -String.to_integer(units)} end)}

      [[_]] ->
        {:error, :not_reversible}
    end
  end

  # ── shared write steps ──────────────────────────────────────────────────

  # Step 3: the level is the consumer's Need; transact/3 cannot set it.
  defp isolation(j) do
    case query!(j, "SELECT current_setting('transaction_isolation')", []) do
      [["read committed"]] -> :ok
      _ -> {:error, :isolation}
    end
  end

  # Step 4: the operation row decides the identity. ON CONFLICT without a target makes both
  # unique keys of the table, (tenant, operation_id) and (tenant, reverses), arbiters, so a
  # concurrent insert on either key waits for the other transaction and then inserts nothing
  # instead of raising. A committed row with the same ID is then a duplicate (equal digest) or a
  # conflict; already_reversed needs the committed reversal row of the same `reverses`. Any
  # other no-row outcome (a unique key this version does not create) is :unavailable.
  defp identify(j, tenant, op) do
    inserted =
      query(
        j,
        "INSERT INTO #{table(j, :operations)} (tenant, operation_id, actor_ref, reason, reverses, request_digest) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING",
        [tenant, op.operation_id, op.actor_ref, op.reason, op.reverses, op.digest]
      )

    if inserted.num_rows == 1 do
      :inserted
    else
      case query!(
             j,
             "SELECT request_digest FROM #{table(j, :operations)} WHERE tenant = $1 AND operation_id = $2",
             [tenant, op.operation_id]
           ) do
        [[digest]] when digest == op.digest -> {:ok, :duplicate}
        [[_digest]] -> {:error, :conflict}
        [] -> reversed(j, tenant, op.reverses)
      end
    end
  end

  defp reversed(j, tenant, target) when is_binary(target) do
    case query!(
           j,
           "SELECT 1 FROM #{table(j, :operations)} WHERE tenant = $1 AND reverses = $2",
           [tenant, target]
         ) do
      [[1]] -> {:error, :already_reversed}
      [] -> {:error, :unavailable}
    end
  end

  defp reversed(_j, _tenant, nil), do: {:error, :unavailable}

  # Steps 6-9 over `[{account_id, minor_units}]`. `identity` nil (a reversal) takes the
  # accounts' own identity.
  defp apply_postings(j, tenant, operation_id, identity, postings) do
    ids = Enum.map(postings, &elem(&1, 0))

    found =
      query!(
        j,
        "SELECT account_id, currency_alpha, currency_numeric, currency_minor_unit FROM #{table(j, :accounts)} WHERE tenant = $1 AND account_id = ANY($2::text[])",
        [tenant, ids]
      )
      |> Map.new(fn [id, alpha, numeric, minor] -> {id, {alpha, numeric, minor}} end)

    identity = identity || found |> Map.values() |> List.first()

    cond do
      map_size(found) != length(ids) -> {:error, :unknown_account}
      Enum.any?(found, fn {_, i} -> i != identity end) -> {:error, :currency_mismatch}
      true -> lock_and_write(j, tenant, operation_id, postings, Enum.sort(ids))
    end
  end

  # Step 7: one row lock at a time, in byte order of account_id (Elixir binary order is the
  # byte order of COLLATE "C"), never in posting order.
  defp lock_and_write(j, tenant, operation_id, postings, ordered) do
    locked =
      Map.new(ordered, fn id ->
        [[balance, version, allow]] =
          query!(
            j,
            "SELECT balance::text, version, allow_negative FROM #{table(j, :accounts)} WHERE tenant = $1 AND account_id = $2 FOR UPDATE",
            [tenant, id]
          )

        {id, {String.to_integer(balance), version, allow}}
      end)

    next =
      for {id, units} <- postings do
        {balance, version, allow} = Map.fetch!(locked, id)

        %{
          account_id: id,
          units: units,
          balance: balance + units,
          version: version + 1,
          allow: allow
        }
      end

    verdicts = Enum.map(next, &apply(@cure, :balance, [&1.balance, &1.allow, Money.bound()]))

    cond do
      :JournalAmountRange in verdicts -> {:error, :amount_range}
      :JournalInsufficientFunds in verdicts -> {:error, :insufficient_funds}
      true -> write(j, tenant, operation_id, next)
    end
  end

  # Step 9: the postings, then each account's balance and version.
  defp write(j, tenant, operation_id, next) do
    ids = Enum.map(next, & &1.account_id)
    units = Enum.map(next, & &1.units)
    versions = Enum.map(next, & &1.version)
    balances = Enum.map(next, & &1.balance)

    query!(
      j,
      "INSERT INTO #{table(j, :postings)} (tenant, operation_id, account_id, minor_units, version, balance) SELECT $1, $2, x.a, x.u, x.v, x.b FROM unnest($3::text[], $4::numeric[], $5::bigint[], $6::numeric[]) AS x(a, u, v, b)",
      [tenant, operation_id, ids, units, versions, balances]
    )

    query!(
      j,
      "UPDATE #{table(j, :accounts)} AS t SET balance = x.b, version = x.v FROM unnest($2::text[], $3::numeric[], $4::bigint[]) AS x(a, b, v) WHERE t.tenant = $1 AND t.account_id = x.a",
      [tenant, ids, balances, versions]
    )

    {:ok, :applied}
  end

  # ── reads ───────────────────────────────────────────────────────────────

  @doc "`{:ok, %Elzoo.Money.Amount{}}`: the stored balance in the account's currency."
  def balance(journal, tenant, account_id) do
    with {:ok, j} <- journal(journal),
         :ok <- valid(text?(tenant, 128) and text?(account_id, 128)),
         :ok <- outside(j) do
      run(j, tenant, fn ->
        case query!(
               j,
               "SELECT balance::text, currency_alpha, currency_numeric, currency_minor_unit FROM #{table(j, :accounts)} WHERE tenant = $1 AND account_id = $2",
               [tenant, account_id]
             ) do
          [] ->
            {:error, :unknown_account}

          [[balance, alpha, numeric, minor]] ->
            with {:ok, currency} <- currency(j, {alpha, numeric, minor}),
                 do: {:ok, amount(j, currency, balance)}
        end
      end)
    end
  end

  @doc """
  `{:ok, %{entries, next}}`: at most `limit` (1..1000) postings of one account after the version
  `after` (`nil` for the start), in ascending version, each
  `%{version, operation_id, reverses, amount, balance}`; `next` is the last version returned, or
  `nil` when no entry follows.
  """
  def history(journal, tenant, request) do
    with {:ok, j} <- journal(journal),
         {:ok, id, after_version, limit} <- history_shape(tenant, request),
         :ok <- outside(j) do
      run(j, tenant, fn ->
        # One statement: the account row, joined to at most limit + 1 postings after the
        # cursor. No row is an unknown account; one row with a NULL version is an empty page.
        case query!(
               j,
               "SELECT a.currency_alpha, a.currency_numeric, a.currency_minor_unit, h.version, h.operation_id, h.reverses, h.minor_units, h.balance FROM #{table(j, :accounts)} a LEFT JOIN LATERAL (SELECT p.version, p.operation_id, o.reverses, p.minor_units::text AS minor_units, p.balance::text AS balance FROM #{table(j, :postings)} p JOIN #{table(j, :operations)} o ON o.tenant = p.tenant AND o.operation_id = p.operation_id WHERE p.tenant = a.tenant AND p.account_id = a.account_id AND p.version > $3 ORDER BY p.version LIMIT $4) h ON true WHERE a.tenant = $1 AND a.account_id = $2 ORDER BY h.version",
               [tenant, id, after_version, limit + 1]
             ) do
          [] ->
            {:error, :unknown_account}

          [[alpha, numeric, minor | _] | _] = rows ->
            with {:ok, currency} <- currency(j, {alpha, numeric, minor}),
                 do: page(j, currency, rows, limit)
        end
      end)
    end
  end

  defp history_shape(tenant, %{account_id: id, after: after_version, limit: limit} = r)
       when map_size(r) == 3 and is_integer(limit) and limit in 1..@max_history and
              (is_nil(after_version) or
                 (is_integer(after_version) and after_version in 0..@max_version)) do
    if text?(tenant, 128) and text?(id, 128),
      do: {:ok, id, after_version || 0, limit},
      else: {:error, :invalid}
  end

  defp history_shape(_tenant, _request), do: {:error, :invalid}

  defp page(j, currency, rows, limit) do
    {entries, rest} =
      rows
      |> Enum.reject(&match?([_, _, _, nil | _], &1))
      |> Enum.split(limit)

    entries =
      Enum.map(entries, fn [_, _, _, version, operation_id, reverses, units, balance] ->
        %{
          version: version,
          operation_id: operation_id,
          reverses: reverses,
          amount: amount(j, currency, units),
          balance: amount(j, currency, balance)
        }
      end)

    next = if rest == [], do: nil, else: List.last(entries).version
    {:ok, %{entries: entries, next: next}}
  end

  # The member of the newest held version whose entry has the stored identity.
  defp currency(j, {alpha, numeric, minor}) do
    j.registry
    |> Money.Registry.versions()
    |> Enum.reverse()
    |> Enum.find_value({:error, :registry}, fn version ->
      case Money.parse(alpha, registry: j.registry, version: version) do
        {:ok, %Currency{alpha: ^alpha, numeric: ^numeric, minor_unit: ^minor} = c} -> {:ok, c}
        _ -> nil
      end
    end)
  end

  defp amount(j, currency, units) do
    {:ok, amount} = Money.from_minor_units(currency, String.to_integer(units), registry: j.registry)
    amount
  end

  # ── request digest ──────────────────────────────────────────────────────

  # SHA-256 of the canonical encoding (README "Request digest"): the tag, then each field as a
  # 32-bit big-endian byte length and bytes of its name and of its value, in a fixed order. A
  # field that a later version adds as optional is appended only when present.
  defp digest(fields),
    do: :crypto.hash(:sha256, ["elzoo-journal-request/1" | Enum.map(fields, &field/1)])

  defp field({name, value}),
    do:
      <<byte_size(name)::32, name::binary, IO.iodata_length(value)::32>> <>
        IO.iodata_to_binary(value)

  # Postings in byte order of account_id, each with the currency identity and minor units.
  defp postings_bytes({alpha, numeric, minor}, pairs) do
    for {id, units} <- Enum.sort(pairs), into: "" do
      field(
        {"posting",
         Enum.map(
           [
             {"account_id", id},
             {"alpha", alpha},
             {"numeric", Integer.to_string(numeric)},
             {"minor_unit", Integer.to_string(minor)},
             {"minor_units", Integer.to_string(units)}
           ],
           &field/1
         )}
      )
    end
  end

  # ── plumbing ────────────────────────────────────────────────────────────

  defp journal(%__MODULE__{repo: repo, prefix: prefix, registry: registry} = j)
       when is_atom(repo) and repo not in [nil, true, false] do
    if identifier?(prefix) and registry?(registry), do: {:ok, j}, else: {:error, :invalid}
  end

  defp journal(_other), do: {:error, :invalid}

  defp valid(true), do: :ok
  defp valid(false), do: {:error, :invalid}

  # Step 2: the journal opens its own transaction and never joins a caller's.
  defp outside(j), do: if(j.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # One transaction under the tenant scope. A refusal rolls back; a database failure, including
  # a lost connection, is :unavailable and says nothing about whether the operation committed.
  defp run(j, tenant, fun) do
    case TenantIsolation.transact(j.repo, %{tenant: tenant}, fun) do
      {:ok, _} = ok -> ok
      {:error, {:tenant_isolation, :in_transaction}} -> {:error, :in_transaction}
      {:error, reason} when reason in @refusals -> {:error, reason}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp table(j, name), do: ~s("#{j.prefix}".elzoo_journal_#{name})

  defp query(j, sql, params), do: SQL.query!(j.repo, sql, params, log: false)
  defp query!(j, sql, params), do: query(j, sql, params).rows

  # 1..max bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes.
  defp text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max//1 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
