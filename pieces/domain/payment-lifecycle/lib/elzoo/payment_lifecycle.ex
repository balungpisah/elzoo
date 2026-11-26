# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PaymentLifecycle do
  @moduledoc """
  One payment's charge and refunds over a consumer-owned Ecto Repo on PostgreSQL 19 (ELZ-365),
  provider-neutral behind the `Elzoo.PaymentLifecycle.Provider` Need.

  Each provider call is one `delivery/effect-intent` intent that the host starts from the
  admission `%{key, identity, arguments, deadline}` that `charge/3` or `refund/3` returns, with
  the host's `Elzoo.PaymentLifecycle.Binding` module of `ChargeAdapter` or `RefundAdapter` and
  `adapter_context:` this lifecycle value. The intent key derives from the logical payment or
  refund ID, never from an Attempt. The Adapters store every provider answer as an observation
  row; `record/3` applies those rows, `apply_event/3` applies verified provider events, and
  both apply only forward transitions. Whenever the charge is `:succeeded`, `record/3`,
  `apply_event/3` and `get/3` return its compensation, which the caller registers; this Piece
  keeps no saga log.

  Every write runs in its own transaction through `Elzoo.TenantIsolation.transact/3` at READ
  COMMITTED (a consumer Need that the Piece checks), takes the payment row with `SELECT ... FOR
  UPDATE` and passes `log: false`. Errors are fixed atoms that never echo an ID, a recipient, a
  provider code or a body.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.Money
  alias Elzoo.Money.{Amount, Codec}
  alias Elzoo.TenantIsolation

  @message "invalid payment lifecycle prefix"
  @tables ~w(elzoo_payment_payments elzoo_payment_refunds elzoo_payment_events elzoo_payment_observations)
  @max Integer.pow(2, 63) - 1
  @max_deadline_ms 86_400_000
  @max_body 65_536
  @max_headers 64
  @comp "comp/charge"
  @charge_adapter "elzoo/payment-lifecycle/charge"
  @refund_adapter "elzoo/payment-lifecycle/refund"
  @refusals [
    :invalid,
    :in_transaction,
    :isolation,
    :conflict,
    :unknown_payment,
    :approval_mismatch,
    :currency,
    :over_refund,
    :nothing_to_refund,
    :verification_failed,
    :unavailable
  ]
  @states %{
    "created" => :created,
    "pending" => :pending,
    "unknown" => :unknown,
    "succeeded" => :succeeded,
    "failed" => :failed
  }

  @derive {Inspect, except: [:seal_key]}
  @enforce_keys [:repo, :prefix, :provider, :provider_account, :deadline_ms, :clock, :seal_key]
  defstruct @enforce_keys

  @doc """
  A lifecycle value from exactly `repo:`, `prefix:`, `provider:` (a module implementing
  `Elzoo.PaymentLifecycle.Provider`), `provider_account:` (1..128 bytes), `deadline_ms:`
  (1..86,400,000, the intent deadline after now) and `clock:` (a zero-arity function returning
  Unix milliseconds). `{:ok, lifecycle}` or `{:error, :invalid}`.
  """
  def new(opts) do
    with true <- Keyword.keyword?(opts),
         [:clock, :deadline_ms, :prefix, :provider, :provider_account, :repo] <-
           Enum.sort(Keyword.keys(opts)),
         repo when is_atom(repo) and repo not in [nil, true, false] <- opts[:repo],
         true <- identifier?(opts[:prefix]),
         true <- provider?(opts[:provider]),
         true <- text?(opts[:provider_account], 128),
         ms when is_integer(ms) and ms in 1..@max_deadline_ms <- opts[:deadline_ms],
         true <- is_function(opts[:clock], 0) do
      {:ok,
       %__MODULE__{
         repo: repo,
         prefix: opts[:prefix],
         provider: opts[:provider],
         provider_account: opts[:provider_account],
         deadline_ms: ms,
         clock: opts[:clock],
         seal_key: :crypto.strong_rand_bytes(32)
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp provider?(m) do
    is_atom(m) and m not in [nil, true, false] and Code.ensure_loaded?(m) and
      Enum.all?([charge: 1, refund: 1, poll: 1, verify_event: 2], fn {f, a} ->
        function_exported?(m, f, a)
      end)
  end

  @doc false
  # The quoted schema name, shared with Elzoo.PaymentLifecycle.Migration.install/1.
  def prefix!(prefix) do
    if identifier?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  @doc false
  def tables, do: @tables

  defp identifier?(name), do: is_binary(name) and name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  # ── create ──────────────────────────────────────────────────────────────

  @doc """
  Store `%{payment_id, approved: %{amount, recipient}, approval_ref}` `:created`:
  `{:ok, :applied}`, `{:ok, :duplicate}` for equal bytes, else `{:error, :conflict}`.
  """
  def create(lc, tenant, request) do
    with {:ok, lc} <- lc(lc),
         {:ok, r} <- create_shape(tenant, request),
         :ok <- outside(lc) do
      run(lc, tenant, fn ->
        with :ok <- isolation(lc) do
          digest = approval_digest(r.amount, r.recipient, r.approval_ref)

          inserted =
            query(
              lc,
              "INSERT INTO #{table(lc, :payments)} (tenant, payment_id, amount, recipient, approval_ref, approval_digest, state, revision) VALUES ($1, $2, $3, $4, $5, $6, 'created', 1) ON CONFLICT DO NOTHING",
              [tenant, r.payment_id, r.amount, r.recipient, r.approval_ref, digest]
            )

          if inserted.num_rows == 1 do
            {:ok, :applied}
          else
            case rows(
                   lc,
                   "SELECT amount, recipient, approval_ref FROM #{table(lc, :payments)} WHERE tenant = $1 AND payment_id = $2",
                   [tenant, r.payment_id]
                 ) do
              [[a, rc, ref]] when a == r.amount and rc == r.recipient and ref == r.approval_ref ->
                {:ok, :duplicate}

              [_] ->
                {:error, :conflict}

              [] ->
                {:error, :unavailable}
            end
          end
        end
      end)
    end
  end

  defp create_shape(tenant, %{payment_id: id, approved: approved, approval_ref: ref} = r)
       when map_size(r) == 3 do
    with true <- text?(tenant, 128) and payment_id?(id) and text?(ref, 256),
         %{amount: amount, recipient: recipient} when map_size(approved) == 2 <- approved,
         true <- text?(recipient, 256),
         {:ok, bytes} <- positive(amount) do
      {:ok, %{payment_id: id, amount: bytes, recipient: recipient, approval_ref: ref}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp create_shape(_, _), do: {:error, :invalid}

  # SHA-256 of the framed Codec bytes of the approved amount, the recipient and approval_ref.
  defp approval_digest(amount_bytes, recipient, approval_ref),
    do:
      :crypto.hash(
        :sha256,
        frame(["elzoo-payment-approval/1", amount_bytes, recipient, approval_ref])
      )

  # ── charge ──────────────────────────────────────────────────────────────

  @doc """
  Check `%{payment_id, amount, recipient}`, the action about to be sent, against the approval
  digest and return the charge intent's admission: from `:created` it sets `:pending`; from
  `:pending` or `:unknown` it returns the same admission again.
  """
  def charge(lc, tenant, request) do
    with {:ok, lc} <- lc(lc),
         {:ok, r} <- charge_shape(tenant, request),
         :ok <- outside(lc),
         {:ok, now} <- now(lc) do
      run(lc, tenant, fn ->
        with :ok <- isolation(lc),
             {:ok, p} <- lock_payment(lc, tenant, r.payment_id),
             :ok <- approved(p, r) do
          case p.state do
            s when s in [:created, :pending, :unknown] ->
              # The first charge/3 fixes the intent deadline, so a later one recovers the intent.
              # A verified pending event can move :created to :pending before any charge/3,
              # so the deadline is fixed whenever it is still unset.
              deadline = p.deadline || now + lc.deadline_ms

              if s == :created or p.deadline == nil do
                query(
                  lc,
                  "UPDATE #{table(lc, :payments)} SET state = $3, deadline = $4, revision = revision + 1 WHERE tenant = $1 AND payment_id = $2",
                  [
                    tenant,
                    p.payment_id,
                    state_text(if(s == :created, do: :pending, else: s)),
                    deadline
                  ]
                )
              end

              {:ok,
               admission(
                 lc,
                 tenant,
                 :charge,
                 charge_ref(p.payment_id),
                 p.amount,
                 p.recipient,
                 deadline
               )}

            s ->
              {:error, {:state, s}}
          end
        end
      end)
    end
  end

  defp charge_shape(tenant, %{payment_id: id, amount: amount, recipient: recipient} = r)
       when map_size(r) == 3 do
    with true <- text?(tenant, 128) and payment_id?(id) and text?(recipient, 256),
         {:ok, bytes} <- positive(amount) do
      {:ok, %{payment_id: id, amount: bytes, recipient: recipient}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp charge_shape(_, _), do: {:error, :invalid}

  defp approved(p, r) do
    if approval_digest(r.amount, r.recipient, p.approval_ref) == p.approval_digest,
      do: :ok,
      else: {:error, :approval_mismatch}
  end

  # ── refund ──────────────────────────────────────────────────────────────

  @doc """
  Store `%{payment_id, refund_id, amount}` `:pending` under the payment row lock and return its
  intent's admission; `amount` is a positive amount or `:remaining` (the payment's amount minus
  every refund that is not `:failed`, fixed now). `comp/charge` takes only `:remaining`.
  """
  def refund(lc, tenant, request) do
    with {:ok, lc} <- lc(lc),
         {:ok, r} <- refund_shape(tenant, request),
         :ok <- outside(lc),
         {:ok, now} <- now(lc) do
      run(lc, tenant, fn ->
        with :ok <- isolation(lc),
             {:ok, p} <- lock_payment(lc, tenant, r.payment_id),
             :ok <- if(p.state == :succeeded, do: :ok, else: {:error, {:state, p.state}}) do
          ref = refund_ref(p.payment_id, r.refund_id)

          case rows(
                 lc,
                 "SELECT requested, amount, deadline FROM #{table(lc, :refunds)} WHERE tenant = $1 AND payment_id = $2 AND refund_id = $3",
                 [tenant, p.payment_id, r.refund_id]
               ) do
            [[requested, amount, deadline]] ->
              if requested == r.requested,
                do: {:ok, admission(lc, tenant, :refund, ref, amount, p.recipient, deadline)},
                else: {:error, :conflict}

            [] ->
              with {:ok, amount} <- refund_amount(lc, tenant, p, r.amount) do
                deadline = now + lc.deadline_ms

                query(
                  lc,
                  "INSERT INTO #{table(lc, :refunds)} (tenant, payment_id, refund_id, requested, amount, state, deadline) VALUES ($1, $2, $3, $4, $5, 'pending', $6)",
                  [tenant, p.payment_id, r.refund_id, r.requested, amount, deadline]
                )

                bump(lc, tenant, p.payment_id)
                {:ok, admission(lc, tenant, :refund, ref, amount, p.recipient, deadline)}
              end
          end
        end
      end)
    end
  end

  defp refund_shape(tenant, %{payment_id: id, refund_id: rid, amount: amount} = r)
       when map_size(r) == 3 do
    with true <- text?(tenant, 128) and payment_id?(id) and refund_id?(rid),
         {:ok, requested} <- requested(rid, amount) do
      {:ok, %{payment_id: id, refund_id: rid, amount: amount, requested: requested}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp refund_shape(_, _), do: {:error, :invalid}

  defp requested(_rid, :remaining), do: {:ok, "remaining"}
  defp requested(@comp, _), do: :error
  defp requested(_rid, amount), do: positive(amount)

  # The refund's amount, fixed now: held is every refund that is not :failed.
  defp refund_amount(lc, tenant, p, requested) do
    {:ok, total} = Codec.decode(p.amount)
    held = held(lc, tenant, p.payment_id, total)

    case requested do
      :remaining ->
        {:ok, rest} = Money.subtract(total, held)
        if rest.minor_units > 0, do: Codec.encode(rest), else: {:error, :nothing_to_refund}

      amount ->
        with {:ok, order} when order in [:lt, :eq] <- compare(amount, total),
             {:ok, sum} <- Money.add(held, amount),
             {:ok, order} when order in [:lt, :eq] <- compare(sum, total) do
          Codec.encode(amount)
        else
          {:error, :currency} -> {:error, :currency}
          _ -> {:error, :over_refund}
        end
    end
  end

  defp compare(a, b) do
    case Money.compare(a, b) do
      {:ok, order} -> {:ok, order}
      {:error, {:currency_mismatch, _}} -> {:error, :currency}
      _ -> {:error, :over_refund}
    end
  end

  defp held(lc, tenant, payment_id, total) do
    {:ok, zero} = Money.from_minor_units(total.currency, 0)

    rows(
      lc,
      "SELECT amount FROM #{table(lc, :refunds)} WHERE tenant = $1 AND payment_id = $2 AND state <> 'failed'",
      [tenant, payment_id]
    )
    |> Enum.reduce(zero, fn [bytes], acc ->
      {:ok, amount} = Codec.decode(bytes)
      {:ok, sum} = Money.add(acc, amount)
      sum
    end)
  end

  # ── record ──────────────────────────────────────────────────────────────

  @doc """
  Apply the stored observation rows of `%{operation, attempt, fallback}` that are not yet
  applied and whose attempt is at most `attempt`, in `seq` order; with `fallback: :unknown` and
  no row of attempt `attempt`, the operation then takes the `{:unknown, _}` transition.
  `{:ok, %{state, compensation}}`.
  """
  def record(lc, tenant, request) do
    with {:ok, lc} <- lc(lc),
         {:ok, r} <- record_shape(tenant, request),
         :ok <- outside(lc) do
      run(lc, tenant, fn ->
        with :ok <- isolation(lc),
             {:ok, p} <- lock_payment(lc, tenant, elem(r.operation, 1)),
             {:ok, t} <- target(lc, tenant, p, r.operation) do
          observed =
            rows(
              lc,
              "SELECT seq, answer, state, provider_ref FROM #{table(lc, :observations)} WHERE tenant = $1 AND payment_id = $2 AND operation_ref = $3 AND NOT applied AND attempt <= $4 ORDER BY seq",
              [tenant, p.payment_id, t.ref, r.attempt]
            )

          next =
            Enum.reduce(observed, {t.state, t.provider_ref}, fn [_, answer, state, ref], acc ->
              transition(t.kind, acc, input(answer, state, ref))
            end)

          if observed != [] do
            query(
              lc,
              "UPDATE #{table(lc, :observations)} SET applied = true WHERE tenant = $1 AND payment_id = $2 AND operation_ref = $3 AND seq = ANY($4::integer[])",
              [tenant, p.payment_id, t.ref, Enum.map(observed, &hd/1)]
            )
          end

          next =
            if r.fallback == :unknown and not attempt_seen?(lc, tenant, p, t, r.attempt),
              do: transition(t.kind, next, :unknown),
              else: next

          p = save(lc, tenant, p, t, next)

          {:ok,
           %{
             state: if(t.kind == :charge, do: p.state, else: elem(next, 0)),
             compensation: compensation(p)
           }}
        end
      end)
    end
  end

  defp record_shape(tenant, %{operation: op, attempt: n, fallback: f} = r) when map_size(r) == 3 do
    if text?(tenant, 128) and operation?(op) and is_integer(n) and n in 1..256 and
         f in [nil, :unknown],
       do: {:ok, %{operation: op, attempt: n, fallback: f}},
       else: {:error, :invalid}
  end

  defp record_shape(_, _), do: {:error, :invalid}

  defp attempt_seen?(lc, tenant, p, t, attempt) do
    rows(
      lc,
      "SELECT 1 FROM #{table(lc, :observations)} WHERE tenant = $1 AND payment_id = $2 AND operation_ref = $3 AND attempt = $4 LIMIT 1",
      [tenant, p.payment_id, t.ref, attempt]
    ) != []
  end

  # ── apply_event ─────────────────────────────────────────────────────────

  @doc """
  Verify `%{raw_body, headers}` with the provider Need before any query, store the event once
  by its `event_id` and apply its state to its operation when that is a forward transition with
  the operation's amount. `{:ok, %{applied, state, compensation}}`, with `duplicate: true` for
  a repeat of equal bytes.
  """
  def apply_event(lc, tenant, request) do
    with {:ok, lc} <- lc(lc),
         {:ok, raw, headers} <- event_shape(tenant, request),
         :ok <- outside(lc),
         {:ok, e} <- verified(lc, raw, headers) do
      body = event_bytes(e)

      run(lc, tenant, fn ->
        with :ok <- isolation(lc) do
          payment_id = elem(e.operation, 1)

          {p, t} =
            case lock_payment(lc, tenant, payment_id) do
              {:ok, p} ->
                case target(lc, tenant, p, e.operation) do
                  {:ok, t} -> {p, t}
                  _ -> {p, nil}
                end

              _ ->
                {nil, nil}
            end

          case stored_event(lc, tenant, e.event_id) do
            nil ->
              {applied, next} = event_step(t, e)

              inserted =
                query(
                  lc,
                  "INSERT INTO #{table(lc, :events)} (tenant, event_id, payment_id, body, applied) VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING",
                  [tenant, e.event_id, payment_id, body, applied]
                )

              if inserted.num_rows == 1 do
                p = if applied, do: save(lc, tenant, p, t, next), else: p

                {:ok,
                 %{
                   applied: applied,
                   state: state_of(t, applied, next),
                   compensation: compensation(p)
                 }}
              else
                duplicate(lc, tenant, e.event_id, body, p, t)
              end

            _ ->
              duplicate(lc, tenant, e.event_id, body, p, t)
          end
        end
      end)
    end
  end

  defp event_shape(tenant, %{raw_body: raw, headers: headers} = r) when map_size(r) == 2 do
    if text?(tenant, 128) and is_binary(raw) and byte_size(raw) <= @max_body and
         headers?(headers, @max_headers),
       do: {:ok, raw, headers},
       else: {:error, :invalid}
  end

  defp event_shape(_, _), do: {:error, :invalid}

  defp headers?([], _), do: true

  defp headers?([{k, v} | rest], n) when n > 0 and is_binary(k) and is_binary(v),
    do: headers?(rest, n - 1)

  defp headers?(_, _), do: false

  # The provider Need checks the signature over the raw body before parsing; a refusal, a raise
  # or an event outside the Contract's shape is verification_failed.
  defp verified(lc, raw, headers) do
    case lc.provider.verify_event(raw, headers) do
      {:ok, %{event_id: id, operation: op, state: s, amount: amount, provider_ref: ref} = e}
      when map_size(e) == 5 and s in [:succeeded, :pending, :failed] ->
        with true <- text?(id, 256) and text?(ref, 256) and operation?(op),
             {:ok, bytes} <- positive(amount) do
          {:ok, %{e | amount: bytes}}
        else
          _ -> {:error, :verification_failed}
        end

      _ ->
        {:error, :verification_failed}
    end
  rescue
    _ -> {:error, :verification_failed}
  catch
    _, _ -> {:error, :verification_failed}
  end

  defp event_bytes(e) do
    {kind, payment_id, refund_id} =
      case e.operation do
        {:charge, id} -> {"charge", id, ""}
        {:refund, id, rid} -> {"refund", id, rid}
      end

    frame([
      "elzoo-payment-event/1",
      e.event_id,
      kind,
      payment_id,
      refund_id,
      state_text(e.state),
      e.amount,
      e.provider_ref
    ])
  end

  defp stored_event(lc, tenant, event_id) do
    case rows(
           lc,
           "SELECT body, applied FROM #{table(lc, :events)} WHERE tenant = $1 AND event_id = $2",
           [tenant, event_id]
         ) do
      [[body, applied]] -> {body, applied}
      [] -> nil
    end
  end

  defp duplicate(lc, tenant, event_id, body, p, t) do
    case stored_event(lc, tenant, event_id) do
      {^body, applied} ->
        {:ok,
         %{duplicate: true, applied: applied, state: t && t.state, compensation: compensation(p)}}

      {_, _} ->
        {:error, :conflict}

      nil ->
        {:error, :unavailable}
    end
  end

  # An event for an unknown operation, of another amount or currency, or whose state is not a
  # forward transition is stored with applied false and changes nothing.
  defp event_step(nil, _e), do: {false, nil}

  defp event_step(t, e) do
    if t.amount == e.amount or Money.compare(decode!(t.amount), decode!(e.amount)) == {:ok, :eq} do
      next = transition(t.kind, {t.state, t.provider_ref}, {:result, e.state, e.provider_ref})
      {elem(next, 0) != t.state, next}
    else
      {false, nil}
    end
  end

  defp state_of(nil, _, _), do: nil
  defp state_of(_t, true, {state, _}), do: state
  defp state_of(t, false, _), do: t.state

  # ── get and verify ──────────────────────────────────────────────────────

  @doc "`{:ok, %{payment, refunds, compensation}}` for `%{payment_id}`."
  def get(lc, tenant, request) do
    with {:ok, lc} <- lc(lc),
         {:ok, id} <- get_shape(tenant, request),
         :ok <- outside(lc) do
      run(lc, tenant, fn ->
        with :ok <- isolation(lc),
             # FOR SHARE waits for and then excludes every writer of this payment, each of
             # which takes the row FOR UPDATE, so the rows below are one consistent view.
             {:ok, p} <- read_payment(lc, tenant, id, " FOR SHARE") do
          refunds =
            rows(
              lc,
              "SELECT refund_id, amount, state, provider_ref FROM #{table(lc, :refunds)} WHERE tenant = $1 AND payment_id = $2 ORDER BY refund_id",
              [tenant, id]
            )
            |> Enum.map(fn [rid, amount, state, ref] ->
              %{refund_id: rid, amount: decode!(amount), state: @states[state], provider_ref: ref}
            end)

          {:ok, total} = Codec.decode(p.amount)
          {:ok, zero} = Money.from_minor_units(total.currency, 0)

          refunded =
            Enum.reduce(refunds, zero, fn r, acc ->
              if r.state == :failed, do: acc, else: elem(Money.add(acc, r.amount), 1)
            end)

          payment = %{
            payment_id: p.payment_id,
            amount: total,
            recipient: p.recipient,
            approval_digest: p.approval_digest,
            state: p.state,
            provider_ref: p.provider_ref,
            refunded: refunded,
            revision: p.revision
          }

          {:ok, %{payment: payment, refunds: refunds, compensation: compensation(p)}}
        end
      end)
    end
  end

  defp get_shape(tenant, %{payment_id: id} = r) when map_size(r) == 1 do
    if text?(tenant, 128) and payment_id?(id), do: {:ok, id}, else: {:error, :invalid}
  end

  defp get_shape(_, _), do: {:error, :invalid}

  @doc "Check the four tables with `Elzoo.TenantIsolation.verify/3`: `:ok` or the first `{:error, reason}`."
  def verify(lc) do
    with {:ok, lc} <- lc(lc) do
      Enum.reduce_while(@tables, :ok, fn t, :ok ->
        case TenantIsolation.verify(lc.repo, {lc.prefix, t},
               prefix: lc.prefix,
               tenant_column: "tenant",
               space_column: nil
             ) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # ── transitions ─────────────────────────────────────────────────────────

  # One transition attempt of a charge or a refund from an observation, the fallback or a
  # verified event (README "Transitions"). The provider ref follows a state change it caused.
  defp transition(kind, {state, ref}, input) do
    case step(kind, state, input) do
      ^state -> {state, ref}
      next -> {next, input_ref(input) || ref}
    end
  end

  defp step(_kind, s, _input) when s in [:succeeded, :failed], do: s
  defp step(_kind, _s, {:result, t, _}) when t in [:succeeded, :failed], do: t
  defp step(_kind, s, {:result, :pending, _}) when s in [:created, :unknown], do: :pending
  defp step(_kind, _s, :declined), do: :failed
  defp step(_kind, :pending, :unknown), do: :unknown
  defp step(:refund, _s, :no_effect), do: :failed
  defp step(_kind, s, _input), do: s

  defp input_ref({:result, _, ref}), do: ref
  defp input_ref(_), do: nil

  defp input("ok", state, ref), do: {:result, @states[state], ref}
  defp input("declined", _, _), do: :declined
  defp input("unknown", _, _), do: :unknown
  defp input("no_effect", _, _), do: :no_effect
  defp input(_, _, _), do: :none

  defp compensation(%{state: :succeeded, payment_id: id}),
    do: %{kind: :refund, payment_id: id, refund_id: @comp, amount: :remaining}

  defp compensation(_), do: nil

  # ── rows ────────────────────────────────────────────────────────────────

  defp lock_payment(lc, tenant, id), do: read_payment(lc, tenant, id, " FOR UPDATE")

  defp read_payment(lc, tenant, id, lock) do
    case rows(
           lc,
           "SELECT payment_id, amount, recipient, approval_ref, approval_digest, state, provider_ref, revision, deadline FROM #{table(lc, :payments)} WHERE tenant = $1 AND payment_id = $2#{lock}",
           [tenant, id]
         ) do
      [[pid, amount, recipient, ref, digest, state, provider_ref, revision, deadline]] ->
        {:ok,
         %{
           payment_id: pid,
           amount: amount,
           recipient: recipient,
           approval_ref: ref,
           approval_digest: digest,
           state: @states[state],
           provider_ref: provider_ref,
           revision: revision,
           deadline: deadline
         }}

      [] ->
        {:error, :unknown_payment}
    end
  end

  defp target(_lc, _tenant, p, {:charge, _}) do
    {:ok,
     %{
       kind: :charge,
       ref: charge_ref(p.payment_id),
       state: p.state,
       provider_ref: p.provider_ref,
       amount: p.amount
     }}
  end

  defp target(lc, tenant, p, {:refund, _, rid}) do
    case rows(
           lc,
           "SELECT state, provider_ref, amount FROM #{table(lc, :refunds)} WHERE tenant = $1 AND payment_id = $2 AND refund_id = $3",
           [tenant, p.payment_id, rid]
         ) do
      [[state, ref, amount]] ->
        {:ok,
         %{
           kind: :refund,
           refund_id: rid,
           ref: refund_ref(p.payment_id, rid),
           state: @states[state],
           provider_ref: ref,
           amount: amount
         }}

      [] ->
        {:error, :unknown_payment}
    end
  end

  # Writes the operation's new state and provider ref when it changed, and bumps the payment's
  # revision. Returns the payment with its current state and revision.
  defp save(_lc, _tenant, p, %{state: state, provider_ref: ref}, {state, ref}), do: p

  defp save(lc, tenant, p, %{kind: :charge}, {state, ref}) do
    query(
      lc,
      "UPDATE #{table(lc, :payments)} SET state = $3, provider_ref = $4, revision = revision + 1 WHERE tenant = $1 AND payment_id = $2",
      [tenant, p.payment_id, state_text(state), ref]
    )

    %{p | state: state, provider_ref: ref, revision: p.revision + 1}
  end

  defp save(lc, tenant, p, %{kind: :refund, refund_id: rid}, {state, ref}) do
    query(
      lc,
      "UPDATE #{table(lc, :refunds)} SET state = $4, provider_ref = $5 WHERE tenant = $1 AND payment_id = $2 AND refund_id = $3",
      [tenant, p.payment_id, rid, state_text(state), ref]
    )

    bump(lc, tenant, p.payment_id)
    %{p | revision: p.revision + 1}
  end

  defp bump(lc, tenant, id) do
    query(
      lc,
      "UPDATE #{table(lc, :payments)} SET revision = revision + 1 WHERE tenant = $1 AND payment_id = $2",
      [tenant, id]
    )
  end

  defp state_text(state), do: Atom.to_string(state)

  # ── the Adapters' side ──────────────────────────────────────────────────

  @doc false
  # The admission of one intent: identity tenant, provider account, Adapter ID, operation
  # kind and the logical reference; the key is effect-intent's derived key of that identity.
  def admission(lc, tenant, kind, ref, amount_bytes, recipient, deadline) do
    identity = [tenant, lc.provider_account, adapter_id(kind), Atom.to_string(kind), ref]

    %{
      key: Elzoo.EffectIntent.Model.key(identity),
      identity: identity,
      arguments: arguments(tenant, ref, amount_bytes, recipient),
      deadline: deadline
    }
  end

  @doc false
  def adapter_id(:charge), do: @charge_adapter
  def adapter_id(:refund), do: @refund_adapter

  @doc false
  def charge_ref(payment_id), do: payment_id <> "/charge"

  @doc false
  def refund_ref(payment_id, refund_id), do: payment_id <> "/refund/" <> refund_id

  @doc false
  # The operation of a logical reference: {:charge, id} or {:refund, id, refund_id}.
  def operation_of(ref) do
    case String.split(ref, "/", parts: 3) do
      [id, "charge"] ->
        if payment_id?(id), do: {:ok, {:charge, id}}, else: :error

      [id, "refund", rid] ->
        if payment_id?(id) and refund_id?(rid), do: {:ok, {:refund, id, rid}}, else: :error

      _ ->
        :error
    end
  end

  @doc false
  # The canonical argument bytes: tenant, logical reference, amount Codec bytes and recipient.
  def arguments(tenant, ref, amount_bytes, recipient),
    do: frame(["elzoo-payment-arguments/1", tenant, ref, amount_bytes, recipient])

  @doc false
  def decode_arguments(bytes) do
    with {:ok, ["elzoo-payment-arguments/1", tenant, ref, amount, recipient]} <- unframe(bytes),
         true <- text?(tenant, 128) and text?(recipient, 256),
         {:ok, op} <- operation_of(ref),
         {:ok, %Amount{minor_units: units}} when units > 0 <- Codec.decode(amount),
         ^bytes <- arguments(tenant, ref, amount, recipient) do
      {:ok, %{tenant: tenant, ref: ref, operation: op, amount: amount, recipient: recipient}}
    else
      _ -> :error
    end
  end

  @doc false
  # Store one provider answer as the next observation row of its operation, in its own
  # transaction under the tenant scope with the payment row lock. :ok or :error.
  def observe(lc, tenant, payment_id, ref, attempt, source, {answer, state, provider_ref, detail}) do
    result =
      run(lc, tenant, fn ->
        with :ok <- isolation(lc),
             {:ok, _} <- lock_payment(lc, tenant, payment_id) do
          query(
            lc,
            "INSERT INTO #{table(lc, :observations)} (tenant, payment_id, operation_ref, seq, attempt, source, answer, state, provider_ref, detail) SELECT $1, $2, $3, COALESCE(max(seq), 0) + 1, $4, $5, $6, $7, $8, $9 FROM #{table(lc, :observations)} WHERE tenant = $1 AND payment_id = $2 AND operation_ref = $3",
            [
              tenant,
              payment_id,
              ref,
              attempt,
              source,
              answer,
              state && state_text(state),
              provider_ref,
              detail
            ]
          )

          {:ok, :stored}
        end
      end)

    if result == {:ok, :stored}, do: :ok, else: :error
  end

  @doc false
  # The ChargeAdapter's check before a send: :ok, :closed when the charge is final or one of its
  # observations holds a final answer (a completed :succeeded or :failed, or a decline), applied
  # or not, or :error.
  def charge_gate(lc, tenant, payment_id) do
    run(lc, tenant, fn ->
      with :ok <- isolation(lc) do
        case rows(
               lc,
               "SELECT p.state, EXISTS (SELECT 1 FROM #{table(lc, :observations)} o WHERE o.tenant = p.tenant AND o.payment_id = p.payment_id AND o.operation_ref = $3 AND (o.answer = 'declined' OR (o.answer = 'ok' AND o.state IN ('succeeded', 'failed')))) FROM #{table(lc, :payments)} p WHERE p.tenant = $1 AND p.payment_id = $2",
               [tenant, payment_id, charge_ref(payment_id)]
             ) do
          [[state, closed]] when state in ["succeeded", "failed"] or closed -> {:ok, :closed}
          [[_, false]] -> {:ok, :open}
          _ -> {:error, :unknown_payment}
        end
      end
    end)
    |> case do
      {:ok, :closed} -> :closed
      {:ok, :open} -> {:ok, nil}
      _ -> :error
    end
  end

  @doc false
  # The RefundAdapter's check before a send: {:ok, charge provider_ref}, :closed when the refund
  # is :failed or one of its observations holds a poll :no_effect, or :error.
  def refund_gate(lc, tenant, payment_id, refund_id) do
    run(lc, tenant, fn ->
      with :ok <- isolation(lc) do
        case rows(
               lc,
               "SELECT r.state, p.provider_ref, EXISTS (SELECT 1 FROM #{table(lc, :observations)} o WHERE o.tenant = r.tenant AND o.payment_id = r.payment_id AND o.operation_ref = $4 AND o.source = 'poll' AND o.answer = 'no_effect') FROM #{table(lc, :refunds)} r JOIN #{table(lc, :payments)} p ON p.tenant = r.tenant AND p.payment_id = r.payment_id WHERE r.tenant = $1 AND r.payment_id = $2 AND r.refund_id = $3",
               [tenant, payment_id, refund_id, refund_ref(payment_id, refund_id)]
             ) do
          [[state, _, closed]] when state == "failed" or closed -> {:ok, :closed}
          [[_, ref, false]] when is_binary(ref) -> {:ok, {:open, ref}}
          _ -> {:error, :unknown_payment}
        end
      end
    end)
    |> case do
      {:ok, :closed} -> :closed
      {:ok, {:open, ref}} -> {:ok, ref}
      _ -> :error
    end
  end

  @doc false
  # The canonical bytes of a completed provider result %{provider_ref, state}.
  def result_bytes(provider_ref, state),
    do: frame(["elzoo-payment-result/1", provider_ref, state_text(state)])

  @doc false
  def decode_result(bytes) do
    with {:ok, ["elzoo-payment-result/1", ref, state]} <- unframe(bytes),
         true <- text?(ref, 256) and state in ["succeeded", "pending", "failed"],
         ^bytes <- result_bytes(ref, @states[state]) do
      {:ok, ref, @states[state]}
    else
      _ -> :error
    end
  end

  @doc false
  def seal(%__MODULE__{seal_key: key}, parts),
    do: :crypto.mac(:hmac, :sha256, key, frame(parts)) |> Base.encode16(case: :lower)

  @doc false
  def text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max//1 and String.valid?(t) and printable?(t)

  # ── plumbing ────────────────────────────────────────────────────────────

  defp payment_id?(id),
    do: is_binary(id) and byte_size(id) in 1..100 and id =~ ~r/\A[A-Za-z0-9._-]+\z/

  defp refund_id?(@comp), do: true

  defp refund_id?(id),
    do: is_binary(id) and byte_size(id) in 1..64 and id =~ ~r/\A[A-Za-z0-9._-]+\z/

  defp operation?({:charge, id}), do: payment_id?(id)
  defp operation?({:refund, id, rid}), do: payment_id?(id) and refund_id?(rid)
  defp operation?(_), do: false

  # A positive domain/money amount of the default registry, as its Codec bytes.
  defp positive(%Amount{minor_units: units} = amount) when is_integer(units) and units > 0 do
    case Codec.encode(amount) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp positive(_), do: :error

  defp decode!(bytes) do
    {:ok, amount} = Codec.decode(bytes)
    amount
  end

  # Fields as a 32-bit big-endian byte length and the bytes, in order.
  defp frame(fields),
    do: IO.iodata_to_binary(Enum.map(fields, &[<<byte_size(&1)::32>>, &1]))

  defp unframe(bytes), do: unframe(bytes, [])
  defp unframe(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp unframe(<<n::32, field::binary-size(n), rest::binary>>, acc) when length(acc) < 8,
    do: unframe(rest, [field | acc])

  defp unframe(_, _), do: :error

  defp lc(%__MODULE__{repo: repo, prefix: prefix} = lc)
       when is_atom(repo) and repo not in [nil, true, false] do
    if identifier?(prefix), do: {:ok, lc}, else: {:error, :invalid}
  end

  defp lc(_), do: {:error, :invalid}

  defp outside(lc), do: if(lc.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # A clock that raises or returns no millisecond count that fits the deadline is :unavailable.
  defp now(lc) do
    case lc.clock.() do
      n when is_integer(n) and n >= 0 and n <= @max - @max_deadline_ms -> {:ok, n}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp isolation(lc) do
    case rows(lc, "SELECT current_setting('transaction_isolation')", []) do
      [["read committed"]] -> :ok
      _ -> {:error, :isolation}
    end
  end

  # One transaction under the tenant scope. A refusal rolls back; a database failure, including
  # a lost connection, is :unavailable and says nothing about whether the write committed.
  defp run(lc, tenant, fun) do
    case TenantIsolation.transact(lc.repo, %{tenant: tenant}, fun) do
      {:ok, _} = ok -> ok
      {:error, {:tenant_isolation, :in_transaction}} -> {:error, :in_transaction}
      {:error, {:state, s}} when is_atom(s) -> {:error, {:state, s}}
      {:error, reason} when reason in @refusals -> {:error, reason}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp table(lc, name), do: ~s("#{lc.prefix}".elzoo_payment_#{name})

  defp query(lc, sql, params), do: SQL.query!(lc.repo, sql, params, log: false)
  defp rows(lc, sql, params), do: query(lc, sql, params).rows

  # No C0 or C1 control character (U+0000-U+001F, U+007F-U+009F).
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
