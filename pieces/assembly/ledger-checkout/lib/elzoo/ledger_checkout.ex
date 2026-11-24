# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LedgerCheckout do
  @moduledoc """
  A durable checkout over a consumer-owned Ecto Repo on PostgreSQL 16 (ELZ-378): pay one
  invoice or top up one wallet through steps that belong to the ready Pieces
  `domain/payment-lifecycle`, `domain/invoice` and `domain/journal`, plus an optional host
  allowance step for a top-up.

  Each step is recorded `started` before its first call and is idempotent by its key; a
  succeeded step's compensation is written in the same checkout transaction as its result.
  After a definite failure the compensations of the succeeded steps run in reverse order of
  their position. A step whose outcome is unknown records nothing and the checkout waits at it.
  `resume/3` holds a session advisory lock per checkout on one checked-out connection for the
  whole call; a caller that does not get it calls nothing and answers `:busy`.

  Every own write runs in its own transaction through `Elzoo.TenantIsolation.transact/3` at
  READ COMMITTED (a consumer Need that the Piece checks); calls to other Pieces and Needs run
  outside those transactions. Errors are fixed atoms that never echo an ID or amount.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.{Invoice, Journal, Money, PaymentLifecycle}
  alias Elzoo.Money.{Amount, Codec, Currency}
  alias Elzoo.TenantIsolation

  @message "invalid ledger checkout prefix"
  @tables ~w(elzoo_checkout_checkouts elzoo_checkout_steps)
  @tag "elzoo-ledger-checkout/1"
  @settle "elzoo.ledger-checkout settle"
  @wallet "elzoo.ledger-checkout wallet"
  @compensate "elzoo.ledger-checkout compensate"
  @max_list 256
  @refusals [:invalid, :in_transaction, :isolation, :unknown_checkout, :unavailable, :conflict]
  @states ~w(running compensating completed compensated needs_operator)a
  @step_states ~w(started succeeded failed compensated compensation_failed)a
  @steps ~w(charge invoice settle wallet allowance)a
  @results ~w(succeeded applied duplicate granted)a
  # The fixed reasons a step or a compensation records: the refusals of the reused Pieces, a
  # failed charge or comp/charge refund, a refused Need; anything else is :unexpected.
  @reasons ~w(invalid conflict unknown_payment approval_mismatch currency over_refund
              nothing_to_refund unknown_invoice incomplete_charge invalid_total over_payment
              over_reversal nothing_applied paid_amount credited over_credit stale_revision
              currency_mismatch unbalanced retired_currency unknown_account unknown_operation
              already_reversed not_reversible insufficient_funds amount_range registry
              payment_failed refund_failed refused unexpected)a
  @piece_states ~w(created pending unknown succeeded failed draft open paid void issued)a
  @text Map.new(
          @states ++ @step_states ++ @steps ++ @results ++ @reasons,
          &{Atom.to_string(&1), &1}
        )
  @state_text Map.new(@piece_states, &{"state:" <> Atom.to_string(&1), {:state, &1}})

  @enforce_keys [:repo, :prefix, :payments, :invoices, :journal, :allowance]
  defstruct @enforce_keys

  @doc """
  A binding from exactly `repo:`, `prefix:`, `payments:` (an `%Elzoo.PaymentLifecycle{}`),
  `invoices:` (an `%Elzoo.Invoice{}`), `journal:` (an `%Elzoo.Journal{}`) and optionally
  `allowance:`, `%{grant, revoke}` of one-arity host Needs. `{:ok, binding}` or
  `{:error, :invalid}`.
  """
  def new(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Enum.sort(Keyword.keys(opts)),
         true <- keys -- [:allowance] == [:invoices, :journal, :payments, :prefix, :repo],
         repo when is_atom(repo) and repo not in [nil, true, false] <- opts[:repo],
         true <- identifier?(opts[:prefix]),
         %PaymentLifecycle{} <- opts[:payments],
         %Invoice{} <- opts[:invoices],
         %Journal{} <- opts[:journal],
         {:ok, allowance} <- allowance(keys, opts[:allowance]) do
      {:ok,
       %__MODULE__{
         repo: repo,
         prefix: opts[:prefix],
         payments: opts[:payments],
         invoices: opts[:invoices],
         journal: opts[:journal],
         allowance: allowance
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp allowance([:allowance | _], %{grant: g, revoke: r} = a)
       when map_size(a) == 2 and is_function(g, 1) and is_function(r, 1),
       do: {:ok, a}

  defp allowance([:invoices | _], nil), do: {:ok, nil}
  defp allowance(_, _), do: :error

  @doc false
  # The quoted schema name, shared with Elzoo.LedgerCheckout.Migration.install/1.
  def prefix!(prefix) do
    if identifier?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  @doc false
  def tables, do: @tables

  defp identifier?(name), do: is_binary(name) and name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  # ── open ────────────────────────────────────────────────────────────────

  @doc """
  Store a checkout `:running` for its declaration (README "Interface"): `{:ok, :applied}`,
  `{:ok, :duplicate}` for an equal declaration under the same `checkout_id`, else
  `{:error, :conflict}`. Every field is checked against the bound of the Piece that takes it
  first; a fault is `{:error, :invalid}` with nothing stored.
  """
  def open(b, tenant, request) do
    with {:ok, b} <- bound(b),
         true <- text?(tenant, 128) || {:error, :invalid},
         {:ok, d} <- declaration(b, request),
         :ok <- outside(b) do
      bytes = encode(d)

      run(b, tenant, fn ->
        with :ok <- isolation(b) do
          inserted =
            query(
              b,
              "INSERT INTO #{table(b, :checkouts)} (tenant, checkout_id, kind, declaration, state, revision) VALUES ($1, $2, $3, $4, 'running', 1) ON CONFLICT DO NOTHING",
              [tenant, d.checkout_id, Atom.to_string(d.kind), bytes]
            )

          if inserted.num_rows == 1 do
            {:ok, :applied}
          else
            case rows(
                   b,
                   "SELECT declaration FROM #{table(b, :checkouts)} WHERE tenant = $1 AND checkout_id = $2",
                   [tenant, d.checkout_id]
                 ) do
              [[^bytes]] -> {:ok, :duplicate}
              [_] -> {:error, :conflict}
              [] -> {:error, :unavailable}
            end
          end
        end
      end)
    end
  end

  defp declaration(b, %{kind: :invoice_payment} = r) when map_size(r) == 9 do
    with %{
           checkout_id: id,
           invoice_id: invoice_id,
           amount: amount,
           recipient: recipient,
           approved: approved,
           approval_ref: ref,
           settle: accounts,
           actor_ref: actor
         } <- r,
         {:ok, d} <- common(b, id, amount, recipient, approved, ref, actor),
         true <- text?(invoice_id, 100),
         {:ok, to, from} <- accounts(accounts) do
      {:ok, Map.merge(d, %{kind: :invoice_payment, invoice_id: invoice_id, to: to, from: from})}
    else
      _ -> {:error, :invalid}
    end
  end

  defp declaration(b, %{kind: :top_up} = r) when map_size(r) == 10 do
    with %{
           checkout_id: id,
           amount: amount,
           recipient: recipient,
           approved: approved,
           approval_ref: ref,
           wallet: accounts,
           allowance: allowance,
           parallel: parallel,
           actor_ref: actor
         } <- r,
         {:ok, d} <- common(b, id, amount, recipient, approved, ref, actor),
         {:ok, to, from} <- accounts(accounts),
         {:ok, grant_id} <- grant_id(allowance),
         true <- is_boolean(parallel) and (grant_id != nil or not parallel),
         true <- grant_id == nil or b.allowance != nil do
      {:ok,
       Map.merge(d, %{kind: :top_up, to: to, from: from, grant_id: grant_id, parallel: parallel})}
    else
      _ -> {:error, :invalid}
    end
  end

  defp declaration(_b, _request), do: {:error, :invalid}

  # The fields both kinds share, each by the bound of the Piece that takes it: the amount by
  # domain/money, payment-lifecycle and the journal (its negation is the other posting), the
  # approved terms, recipient and approval_ref by payment-lifecycle, actor_ref by the journal.
  defp common(b, id, amount, recipient, approved, ref, actor) do
    with true <- checkout_id?(id),
         {:ok, amount_bytes} <- positive(amount),
         true <- journal_amount?(b.journal, amount),
         %{amount: approved_amount, recipient: approved_recipient} when map_size(approved) == 2 <-
           approved,
         {:ok, approved_bytes} <- positive(approved_amount),
         true <- text?(recipient, 256) and text?(approved_recipient, 256),
         true <- text?(ref, 256) and text?(actor, 128) do
      {:ok,
       %{
         checkout_id: id,
         amount: amount,
         amount_bytes: amount_bytes,
         recipient: recipient,
         approved_amount: approved_amount,
         approved_bytes: approved_bytes,
         approved_recipient: approved_recipient,
         approval_ref: ref,
         actor_ref: actor
       }}
    else
      _ -> :error
    end
  end

  # Two distinct journal accounts: the journal refuses one account twice in an operation.
  defp accounts(%{to: to, from: from} = a) when map_size(a) == 2 do
    if text?(to, 128) and text?(from, 128) and to != from, do: {:ok, to, from}, else: :error
  end

  defp accounts(_), do: :error

  defp grant_id(nil), do: {:ok, nil}

  defp grant_id(%{grant_id: id} = a) when map_size(a) == 1,
    do: if(text?(id, 128), do: {:ok, id}, else: :error)

  defp grant_id(_), do: :error

  defp positive(%Amount{minor_units: units} = amount) when is_integer(units) and units > 0 do
    case Codec.encode(amount) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp positive(_), do: :error

  defp journal_amount?(%Journal{registry: registry}, %Amount{
         currency: %Currency{numeric: n, minor_unit: m} = c,
         minor_units: units
       })
       when is_integer(n) and is_integer(m),
       do: units < Money.bound() and Money.member(registry, c) == :ok

  defp journal_amount?(_, _), do: false

  defp checkout_id?(id),
    do: is_binary(id) and byte_size(id) in 1..64 and id =~ ~r/\A[A-Za-z0-9._-]+\z/

  # ── resume ──────────────────────────────────────────────────────────────

  @doc """
  Run the checkout as far as it can now, holding its session advisory lock on one checked-out
  connection for the whole call. `{:ok, %{state, wait}}`, `wait` `nil` or `%{step, for,
  admission}` with `for` `:charge_intent`, `:refund_intent`, `:retry` or `:busy`.
  """
  def resume(b, tenant, request) do
    with {:ok, b} <- bound(b),
         {:ok, id} <- id_shape(tenant, request),
         :ok <- outside(b) do
      key = lock_key(b.prefix, tenant, id)

      # The checkout has no deadline (timeout: :infinity): DBConnection's checkout deadline
      # covers the whole checked-out time and its end closes the session and the lock with it.
      b.repo.checkout(
        fn ->
          case lock(b, key) do
            true ->
              try do
                drive(b, tenant, id)
              after
                unlock(b, key)
              end

            false ->
              busy(b, tenant, id)

            :error ->
              {:error, :unavailable}
          end
        end,
        timeout: :infinity
      )
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp id_shape(tenant, %{checkout_id: id} = r) when map_size(r) == 1 do
    if text?(tenant, 128) and checkout_id?(id), do: {:ok, id}, else: {:error, :invalid}
  end

  defp id_shape(_, _), do: {:error, :invalid}

  # A 64-bit key from the prefix, tenant and checkout_id; a collision only makes two checkouts
  # wait for each other.
  defp lock_key(prefix, tenant, id) do
    <<key::signed-64, _::binary>> =
      :crypto.hash(:sha256, frame(["elzoo-ledger-checkout-lock/1", prefix, tenant, id]))

    key
  end

  defp lock(b, key) do
    case SQL.query(b.repo, "SELECT pg_try_advisory_lock($1)", [key], log: false) do
      {:ok, %{rows: [[held]]}} when is_boolean(held) -> held
      _ -> :error
    end
  end

  # A lost connection has released the lock with its session already.
  defp unlock(b, key) do
    SQL.query(b.repo, "SELECT pg_advisory_unlock($1)", [key], log: false)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp busy(b, tenant, id) do
    with {:ok, c} <- load(b, tenant, id),
         do: {:ok, %{state: c.state, wait: %{step: current(c), for: :busy, admission: nil}}}
  end

  # The holder's loop: each pass records progress or returns.
  defp drive(b, tenant, id) do
    with {:ok, c} <- load(b, tenant, id),
         :ok <- if(needs?(b, c.declaration), do: :ok, else: {:error, :invalid}) do
      outcome =
        case c.state do
          :running -> forward(b, tenant, c)
          :compensating -> backward(b, tenant, c)
          state -> {:done, state}
        end

      case outcome do
        :next -> drive(b, tenant, id)
        {:done, state} -> {:ok, %{state: state, wait: nil}}
        {:wait, wait} -> {:ok, %{state: c.state, wait: wait}}
        {:error, _} = error -> error
      end
    end
  end

  defp needs?(b, d), do: d.kind == :invoice_payment or d.grant_id == nil or b.allowance != nil

  # ── forward ─────────────────────────────────────────────────────────────

  # The first unit (one step, or the declared parallel group) whose members did not all
  # succeed: start its rows, run every member that is not definite, record each definite
  # outcome. A member waiting keeps the checkout at it; its sibling still runs.
  defp forward(b, tenant, c) do
    case Enum.find(units(c.declaration), fn unit ->
           not Enum.all?(unit, &(state_of(c, &1) == :succeeded))
         end) do
      nil ->
        with :ok <- move(b, tenant, c.declaration.checkout_id, :running, :completed),
             do: :next

      unit ->
        open = Enum.filter(unit, &(state_of(c, &1) in [nil, :started]))

        # Every member definite and the checkout still running: no rule here makes that.
        with true <- open != [] || {:error, :conflict},
             :ok <- start(b, tenant, c, open) do
          outcomes =
            Enum.map(open, fn name ->
              {name, outcome(name, perform(b, tenant, c.declaration, name))}
            end)

          Enum.reduce_while(outcomes, :next, fn
            {name, {:ok, result, compensation}}, acc ->
              recorded(record(b, tenant, c, name, {:succeeded, result, compensation}), acc)

            {name, {:fail, reason}}, acc ->
              recorded(record(b, tenant, c, name, {:failed, reason}), acc)

            {_name, wait_or_error}, acc ->
              {:cont, first(acc, wait_or_error)}
          end)
        end
    end
  end

  defp recorded(:ok, acc), do: {:cont, acc}
  defp recorded(error, _acc), do: {:halt, error}

  # Errors before waits, the first of each in step order.
  defp first({:error, _} = acc, _), do: acc
  defp first(_acc, {:error, _} = error), do: error
  defp first({:wait, _} = acc, _), do: acc
  defp first(_acc, wait), do: wait

  # A Piece's :unavailable and a Need's other answer wait :retry with nothing recorded; a
  # Piece's :in_transaction and :isolation are resume/3's own error.
  defp outcome(name, :retry),
    do: {:wait, %{step: name, for: :retry, admission: nil}}

  defp outcome(name, {:wait, for, admission}),
    do: {:wait, %{step: name, for: for, admission: admission}}

  defp outcome(_name, other), do: other

  defp perform(b, tenant, d, :charge), do: charge(b, tenant, d, payment_id(d), 3)

  defp perform(b, tenant, d, :invoice) do
    ref = "checkout/" <> d.checkout_id

    case Invoice.apply_payment(b.invoices, tenant, %{
           invoice_id: d.invoice_id,
           payment_ref: ref,
           amount: d.amount
         }) do
      {:ok, result} when result in [:applied, :duplicate] ->
        {:ok, result,
         %{
           kind: :reverse_payment,
           reversal_id: "checkout/" <> d.checkout_id <> "/c/invoice",
           payment_ref: ref,
           amount: :remaining
         }}

      other ->
        piece(other)
    end
  end

  defp perform(b, tenant, d, name) when name in [:settle, :wallet] do
    {:ok, minus} = Money.negate(d.amount)
    op = operation_id(d, name)

    case Journal.post(b.journal, tenant, %{
           operation_id: op,
           actor_ref: d.actor_ref,
           reason: if(name == :settle, do: @settle, else: @wallet),
           postings: [%{account_id: d.to, amount: d.amount}, %{account_id: d.from, amount: minus}]
         }) do
      {:ok, result} when result in [:applied, :duplicate] ->
        {:ok, result,
         %{
           kind: :reverse,
           operation_id: "checkout/" <> d.checkout_id <> "/c/" <> Atom.to_string(name),
           reverses: op
         }}

      other ->
        piece(other)
    end
  end

  defp perform(b, tenant, d, :allowance) do
    case need(b.allowance.grant, %{
           tenant: tenant,
           checkout_id: d.checkout_id,
           grant_id: d.grant_id,
           amount: d.amount
         }) do
      :ok -> {:ok, :granted, %{kind: :revoke, grant_id: d.grant_id}}
      {:error, :refused} -> {:fail, :refused}
      _ -> :retry
    end
  end

  # The charge by the payment's state. A pending or unknown payment waits for the host's intent
  # and reconciliation; charge/3's {:state, _} means the payment was settled after the read,
  # so the step reads it again and acts on that state.
  defp charge(b, tenant, d, payment_id, tries) do
    case PaymentLifecycle.get(b.payments, tenant, %{payment_id: payment_id}) do
      {:ok, %{payment: %{state: :succeeded}, compensation: %{kind: :refund} = compensation}} ->
        {:ok, :succeeded, compensation}

      {:ok, %{payment: %{state: :failed}}} ->
        {:fail, :payment_failed}

      {:ok, %{payment: %{state: state}}} when state in [:created, :pending, :unknown] ->
        case PaymentLifecycle.charge(b.payments, tenant, %{
               payment_id: payment_id,
               amount: d.amount,
               recipient: d.recipient
             }) do
          {:ok, admission} -> {:wait, :charge_intent, admission}
          {:error, {:state, _}} when tries > 0 -> charge(b, tenant, d, payment_id, tries - 1)
          other -> piece(other)
        end

      {:error, :unknown_payment} when tries > 0 ->
        case PaymentLifecycle.create(b.payments, tenant, %{
               payment_id: payment_id,
               approved: %{amount: d.approved_amount, recipient: d.approved_recipient},
               approval_ref: d.approval_ref
             }) do
          {:ok, _} -> charge(b, tenant, d, payment_id, tries - 1)
          other -> piece(other)
        end

      other ->
        piece(other)
    end
  end

  defp piece({:error, :unavailable}), do: :retry
  defp piece({:error, e}) when e in [:in_transaction, :isolation], do: {:error, e}
  defp piece({:error, reason}), do: {:fail, reason}

  # A Need's :ok or {:error, :refused}; any other answer, raise, throw or exit is :retry.
  defp need(fun, argument) do
    case fun.(argument) do
      :ok -> :ok
      {:error, :refused} -> {:error, :refused}
      _ -> :retry
    end
  rescue
    _ -> :retry
  catch
    _, _ -> :retry
  end

  # ── backward ────────────────────────────────────────────────────────────

  # The compensation of the succeeded step with the highest position; none left is
  # :compensated. A failed compensation stops the checkout for an operator.
  defp backward(b, tenant, c) do
    case c.steps
         |> Enum.filter(&(&1.state == :succeeded))
         |> Enum.max_by(& &1.position, fn -> nil end) do
      nil ->
        with :ok <- move(b, tenant, c.declaration.checkout_id, :compensating, :compensated),
             do: :next

      step ->
        case outcome(step.step, compensate(b, tenant, c.declaration, step)) do
          :compensated ->
            with :ok <- record(b, tenant, c, step.step, :compensated), do: :next

          {:fail, reason} ->
            with :ok <- record(b, tenant, c, step.step, {:compensation_failed, reason}),
                 do: :next

          other ->
            other
        end
    end
  end

  defp compensate(b, tenant, _d, %{compensation: %{kind: :refund} = comp}) do
    case PaymentLifecycle.refund(b.payments, tenant, %{
           payment_id: comp.payment_id,
           refund_id: comp.refund_id,
           amount: :remaining
         }) do
      {:ok, admission} ->
        case PaymentLifecycle.get(b.payments, tenant, %{payment_id: comp.payment_id}) do
          {:ok, %{refunds: refunds}} ->
            case Enum.find(refunds, &(&1.refund_id == comp.refund_id)) do
              %{state: :succeeded} -> :compensated
              %{state: :failed} -> {:fail, :refund_failed}
              _ -> {:wait, :refund_intent, admission}
            end

          other ->
            piece(other)
        end

      {:error, :nothing_to_refund} ->
        :compensated

      other ->
        piece(other)
    end
  end

  defp compensate(b, tenant, d, %{compensation: %{kind: :reverse_payment} = comp}) do
    case Invoice.reverse_payment(b.invoices, tenant, %{
           invoice_id: d.invoice_id,
           reversal_id: comp.reversal_id,
           payment_ref: comp.payment_ref,
           amount: :remaining
         }) do
      {:ok, _} -> :compensated
      {:error, :nothing_applied} -> :compensated
      other -> piece(other)
    end
  end

  defp compensate(b, tenant, d, %{compensation: %{kind: :reverse} = comp}) do
    case Journal.reverse(b.journal, tenant, %{
           operation_id: comp.operation_id,
           reverses: comp.reverses,
           actor_ref: d.actor_ref,
           reason: @compensate
         }) do
      {:ok, _} -> :compensated
      {:error, :already_reversed} -> :compensated
      other -> piece(other)
    end
  end

  defp compensate(b, tenant, d, %{compensation: %{kind: :revoke, grant_id: grant_id}}) do
    case need(b.allowance.revoke, %{tenant: tenant, checkout_id: d.checkout_id, grant_id: grant_id}) do
      :ok -> :compensated
      {:error, :refused} -> {:fail, :refused}
      _ -> :retry
    end
  end

  # ── recording ───────────────────────────────────────────────────────────

  # The rows of steps about to be called, written started before the first call.
  defp start(b, tenant, c, names) do
    plan = plan(c.declaration)

    transact(b, tenant, fn ->
      for name <- names do
        {^name, position, group} = List.keyfind(plan, name, 0)

        query(
          b,
          "INSERT INTO #{table(b, :steps)} (tenant, checkout_id, step, position, grp, state, revision) VALUES ($1, $2, $3, $4, $5, 'started', 1) ON CONFLICT DO NOTHING",
          [tenant, c.declaration.checkout_id, Atom.to_string(name), position, group]
        )
      end

      {:ok, :started}
    end)
  end

  # One checkout transaction records one step's outcome, its compensation with its result, and
  # the checkout state that follows. Recording an equal outcome again is a no-op; another is
  # :conflict with nothing written.
  defp record(b, tenant, c, name, outcome) do
    id = c.declaration.checkout_id

    transact(b, tenant, fn ->
      with {:ok, checkout_state, steps} <- locked(b, tenant, id),
           %{} = row <- Enum.find(steps, &(&1.step == name)) || {:error, :conflict} do
        {state, result, compensation, failure} = columns(row, outcome)

        cond do
          {row.state, row.result, row.compensation_bytes, row.failure} ==
              {state, result, compensation, failure} ->
            {:ok, :recorded}

          allowed?(row.state, state) ->
            query(
              b,
              "UPDATE #{table(b, :steps)} SET state = $4, result = $5, compensation = $6, failure = $7, revision = revision + 1 WHERE tenant = $1 AND checkout_id = $2 AND step = $3",
              [tenant, id, Atom.to_string(name), text(state), text(result), compensation, failure]
            )

            steps =
              Enum.map(steps, fn
                %{step: ^name} = s -> %{s | state: state, failure: failure}
                s -> s
              end)

            next = next_state(c.declaration, checkout_state, steps)
            bump(b, tenant, id, next, failure_of(c.declaration, checkout_state, next, steps))
            {:ok, :recorded}

          true ->
            {:error, :conflict}
        end
      end
    end)
  end

  defp columns(_row, {:succeeded, result, compensation}),
    do: {:succeeded, result, encode_compensation(compensation), nil}

  defp columns(_row, {:failed, reason}), do: {:failed, nil, nil, reason_text(reason)}

  defp columns(row, :compensated), do: {:compensated, row.result, row.compensation_bytes, nil}

  defp columns(row, {:compensation_failed, reason}),
    do: {:compensation_failed, row.result, row.compensation_bytes, reason_text(reason)}

  defp allowed?(:started, to), do: to in [:succeeded, :failed]
  defp allowed?(:succeeded, to), do: to in [:compensated, :compensation_failed]
  defp allowed?(_, _), do: false

  # The checkout state after a step row changed. A unit is decided only when all its members
  # are definite: all succeeded continues; any failed starts the compensation.
  defp next_state(_d, :compensating, steps) do
    cond do
      Enum.any?(steps, &(&1.state == :compensation_failed)) -> :needs_operator
      Enum.any?(steps, &(&1.state == :succeeded)) -> :compensating
      true -> :compensated
    end
  end

  defp next_state(d, :running, steps) do
    states = Map.new(steps, &{&1.step, &1.state})

    decided =
      Enum.find(units(d), fn unit -> not Enum.all?(unit, &(states[&1] == :succeeded)) end)

    cond do
      decided == nil -> :completed
      Enum.all?(decided, &(states[&1] in [:succeeded, :failed])) -> :compensating
      true -> :running
    end
  end

  # The recorded failure of the checkout: the failed member's reason, the wallet's when both
  # members of the group failed.
  defp failure_of(_d, :running, :compensating, steps) do
    failed = Enum.filter(steps, &(&1.state == :failed))

    (Enum.find(failed, &(&1.step == :wallet)) || hd(failed)).failure
  end

  defp failure_of(_d, _from, _to, _steps), do: :keep

  defp bump(b, tenant, id, state, failure) do
    query(
      b,
      "UPDATE #{table(b, :checkouts)} SET state = $3, failure = CASE WHEN $5 THEN failure ELSE $4 END, revision = revision + 1 WHERE tenant = $1 AND checkout_id = $2",
      [
        tenant,
        id,
        text(state),
        if(failure == :keep, do: nil, else: failure),
        failure == :keep
      ]
    )
  end

  # A move of the checkout itself, :running to :completed or :compensating to :compensated,
  # when no step row changes.
  defp move(b, tenant, id, from, to) do
    transact(b, tenant, fn ->
      with {:ok, ^from, _steps} <- locked(b, tenant, id) do
        bump(b, tenant, id, to, :keep)
        {:ok, :settled}
      else
        {:ok, _, _} -> {:error, :conflict}
        error -> error
      end
    end)
  end

  defp locked(b, tenant, id) do
    case rows(
           b,
           "SELECT state FROM #{table(b, :checkouts)} WHERE tenant = $1 AND checkout_id = $2 FOR UPDATE",
           [tenant, id]
         ) do
      [[state]] -> {:ok, @text[state], steps(b, tenant, id)}
      [] -> {:error, :unknown_checkout}
    end
  end

  defp transact(b, tenant, fun) do
    case run(b, tenant, fn -> with :ok <- isolation(b), do: fun.() end) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # ── reading ─────────────────────────────────────────────────────────────

  @doc """
  `{:ok, checkout}` for `%{checkout_id}`: `%{checkout_id, kind, state, failure, revision,
  steps}`, each step `%{step, position, group, state, result, failure, compensation}`.
  """
  def get(b, tenant, request) do
    with {:ok, b} <- bound(b),
         {:ok, id} <- id_shape(tenant, request),
         :ok <- outside(b),
         {:ok, c} <- load(b, tenant, id) do
      {:ok,
       %{
         checkout_id: id,
         kind: c.declaration.kind,
         state: c.state,
         failure: c.failure,
         revision: c.revision,
         steps:
           Enum.map(c.steps, fn s ->
             %{
               step: s.step,
               position: s.position,
               group: s.group,
               state: s.state,
               result: s.result,
               failure: reason(s.failure),
               compensation: s.compensation
             }
           end)
       }}
    end
  end

  @doc """
  `{:ok, %{checkout_ids, more}}`: up to `limit` (1..256) checkout IDs after `after` (`nil` or
  a checkout ID) in byte order, of the checkouts `:running` or `:compensating` (`state: :open`)
  or `:needs_operator`.
  """
  def list_running(b, tenant, request) do
    with {:ok, b} <- bound(b),
         {:ok, r} <- list_shape(tenant, request),
         :ok <- outside(b) do
      states =
        if r.state == :open, do: ["running", "compensating"], else: ["needs_operator"]

      run(b, tenant, fn ->
        with :ok <- isolation(b) do
          ids =
            rows(
              b,
              ~s{SELECT checkout_id FROM #{table(b, :checkouts)} WHERE tenant = $1 AND state = ANY($2) AND ($3::text IS NULL OR checkout_id COLLATE "C" > $3) ORDER BY checkout_id COLLATE "C" LIMIT $4},
              [tenant, states, r.after, r.limit + 1]
            )
            |> Enum.map(&hd/1)

          {:ok, %{checkout_ids: Enum.take(ids, r.limit), more: length(ids) > r.limit}}
        end
      end)
    end
  end

  defp list_shape(tenant, %{after: after_id, limit: limit, state: state} = r)
       when map_size(r) == 3 do
    if text?(tenant, 128) and (after_id == nil or checkout_id?(after_id)) and
         is_integer(limit) and limit in 1..@max_list and state in [:open, :needs_operator],
       do: {:ok, r},
       else: {:error, :invalid}
  end

  defp list_shape(_, _), do: {:error, :invalid}

  # One transaction: the checkout and its steps in position order.
  defp load(b, tenant, id) do
    run(b, tenant, fn ->
      with :ok <- isolation(b) do
        case rows(
               b,
               "SELECT declaration, state, failure, revision FROM #{table(b, :checkouts)} WHERE tenant = $1 AND checkout_id = $2",
               [tenant, id]
             ) do
          [[bytes, state, failure, revision]] ->
            {:ok,
             %{
               declaration: decode(bytes),
               state: @text[state],
               failure: reason(failure),
               revision: revision,
               steps: steps(b, tenant, id)
             }}

          [] ->
            {:error, :unknown_checkout}
        end
      end
    end)
  end

  defp steps(b, tenant, id) do
    rows(
      b,
      "SELECT step, position, grp, state, result, compensation, failure FROM #{table(b, :steps)} WHERE tenant = $1 AND checkout_id = $2 ORDER BY position",
      [tenant, id]
    )
    |> Enum.map(fn [step, position, group, state, result, compensation, failure] ->
      %{
        step: @text[step],
        position: position,
        group: group,
        state: @text[state],
        result: result && @text[result],
        compensation_bytes: compensation,
        compensation: compensation && decode_compensation(compensation),
        failure: failure
      }
    end)
  end

  defp state_of(c, name) do
    case Enum.find(c.steps, &(&1.step == name)) do
      nil -> nil
      s -> s.state
    end
  end

  # The step a busy caller names: the next step not succeeded while running, the step whose
  # compensation runs next while compensating, the failed compensation's step.
  defp current(%{state: :running} = c) do
    Enum.find_value(plan(c.declaration), fn {name, _, _} ->
      if state_of(c, name) != :succeeded, do: name
    end)
  end

  defp current(%{state: :compensating} = c) do
    case c.steps
         |> Enum.filter(&(&1.state == :succeeded))
         |> Enum.max_by(& &1.position, fn -> nil end) do
      nil -> nil
      s -> s.step
    end
  end

  defp current(%{state: :needs_operator} = c) do
    Enum.find_value(c.steps, fn s -> if s.state == :compensation_failed, do: s.step end)
  end

  defp current(_c), do: nil

  # ── the declaration ─────────────────────────────────────────────────────

  # The steps as {name, position, group}; the group is 1 for the declared parallel pair.
  defp plan(%{kind: :invoice_payment}),
    do: [{:charge, 1, nil}, {:invoice, 2, nil}, {:settle, 3, nil}]

  defp plan(%{kind: :top_up, grant_id: nil}), do: [{:charge, 1, nil}, {:wallet, 2, nil}]

  defp plan(%{kind: :top_up, parallel: true}),
    do: [{:charge, 1, nil}, {:wallet, 2, 1}, {:allowance, 3, 1}]

  defp plan(%{kind: :top_up}), do: [{:charge, 1, nil}, {:wallet, 2, nil}, {:allowance, 3, nil}]

  # The plan as units in order: one step each, the group's members together.
  defp units(d) do
    d
    |> plan()
    |> Enum.chunk_by(fn {name, _, group} -> group || name end)
    |> Enum.map(fn unit -> Enum.map(unit, &elem(&1, 0)) end)
  end

  defp payment_id(d), do: "checkout." <> d.checkout_id

  defp operation_id(d, name), do: "checkout/" <> d.checkout_id <> "/" <> Atom.to_string(name)

  defp encode(%{kind: :invoice_payment} = d),
    do: frame([@tag, "invoice_payment" | common_fields(d)] ++ [d.invoice_id, d.to, d.from])

  defp encode(%{kind: :top_up} = d),
    do:
      frame(
        [@tag, "top_up" | common_fields(d)] ++
          [
            d.to,
            d.from,
            if(d.grant_id, do: "grant", else: "none"),
            d.grant_id || "",
            to_string(d.parallel)
          ]
      )

  defp common_fields(d),
    do: [
      d.checkout_id,
      d.amount_bytes,
      d.recipient,
      d.approved_bytes,
      d.approved_recipient,
      d.approval_ref,
      d.actor_ref
    ]

  # Stored bytes were written by encode/1 from a checked declaration.
  defp decode(bytes) do
    {:ok, [@tag, kind, id, amount, recipient, approved, approved_recipient, ref, actor | rest]} =
      unframe(bytes)

    d = %{
      checkout_id: id,
      amount: amount!(amount),
      recipient: recipient,
      approved_amount: amount!(approved),
      approved_recipient: approved_recipient,
      approval_ref: ref,
      actor_ref: actor
    }

    case {kind, rest} do
      {"invoice_payment", [invoice_id, to, from]} ->
        Map.merge(d, %{kind: :invoice_payment, invoice_id: invoice_id, to: to, from: from})

      {"top_up", [to, from, allowance, grant_id, parallel]} ->
        Map.merge(d, %{
          kind: :top_up,
          to: to,
          from: from,
          grant_id: if(allowance == "grant", do: grant_id),
          parallel: parallel == "true"
        })
    end
  end

  defp amount!(bytes) do
    {:ok, amount} = Codec.decode(bytes)
    amount
  end

  defp encode_compensation(%{kind: :refund, payment_id: p, refund_id: r, amount: :remaining}),
    do: frame(["refund", p, r])

  defp encode_compensation(%{
         kind: :reverse_payment,
         reversal_id: r,
         payment_ref: p,
         amount: :remaining
       }),
       do: frame(["reverse_payment", r, p])

  defp encode_compensation(%{kind: :reverse, operation_id: o, reverses: r}),
    do: frame(["reverse", o, r])

  defp encode_compensation(%{kind: :revoke, grant_id: g}), do: frame(["revoke", g])

  defp decode_compensation(bytes) do
    case unframe(bytes) do
      {:ok, ["refund", p, r]} ->
        %{kind: :refund, payment_id: p, refund_id: r, amount: :remaining}

      {:ok, ["reverse_payment", r, p]} ->
        %{kind: :reverse_payment, reversal_id: r, payment_ref: p, amount: :remaining}

      {:ok, ["reverse", o, r]} ->
        %{kind: :reverse, operation_id: o, reverses: r}

      {:ok, ["revoke", g]} ->
        %{kind: :revoke, grant_id: g}
    end
  end

  defp reason_text({:state, s}) when s in @piece_states, do: "state:" <> Atom.to_string(s)
  defp reason_text(reason) when reason in @reasons, do: Atom.to_string(reason)
  defp reason_text(_), do: "unexpected"

  defp reason(nil), do: nil
  defp reason(text), do: @state_text[text] || @text[text]

  defp text(nil), do: nil
  defp text(atom), do: Atom.to_string(atom)

  # ── plumbing ────────────────────────────────────────────────────────────

  defp bound(%__MODULE__{repo: repo, prefix: prefix} = b)
       when is_atom(repo) and repo not in [nil, true, false] do
    if identifier?(prefix), do: {:ok, b}, else: {:error, :invalid}
  end

  defp bound(_), do: {:error, :invalid}

  defp outside(b), do: if(b.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  defp isolation(b) do
    case rows(b, "SELECT current_setting('transaction_isolation')", []) do
      [["read committed"]] -> :ok
      _ -> {:error, :isolation}
    end
  end

  # One transaction under the tenant scope. A refusal rolls back; a database failure, including
  # a lost connection, is :unavailable and says nothing about whether the write committed.
  defp run(b, tenant, fun) do
    case TenantIsolation.transact(b.repo, %{tenant: tenant}, fun) do
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

  defp table(b, :checkouts), do: ~s("#{b.prefix}".elzoo_checkout_checkouts)
  defp table(b, :steps), do: ~s("#{b.prefix}".elzoo_checkout_steps)

  defp query(b, sql, params), do: SQL.query!(b.repo, sql, params, log: false)
  defp rows(b, sql, params), do: query(b, sql, params).rows

  # Fields as a 32-bit big-endian byte length and the bytes, in order.
  defp frame(fields), do: IO.iodata_to_binary(Enum.map(fields, &[<<byte_size(&1)::32>>, &1]))

  defp unframe(bytes), do: unframe(bytes, [])
  defp unframe(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp unframe(<<n::32, field::binary-size(n), rest::binary>>, acc) when length(acc) < 16,
    do: unframe(rest, [field | acc])

  defp unframe(_, _), do: :error

  # 1..max bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes.
  defp text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max//1 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
