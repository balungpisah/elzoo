# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Invoice do
  @moduledoc """
  Numbered invoices of one currency over a consumer-owned Ecto Repo on PostgreSQL 16 (ELZ-367).

  An invoice is a document of usage, fee and adjustment lines for one billing account,
  drafted, then finalized with the next number of its series (gapless among committed
  finalizations, never reused), then paid by payment applications up to its payable, with
  reversal of an applied amount, void of an unpaid invoice and credit notes that correct a
  finalized one. The Piece posts nothing to `domain/journal`: `finalize/3` names the operation
  ID that the host posts and `mark_posted/3` records the host's result.

  Every write runs in its own transaction through `Elzoo.TenantIsolation.transact/3` at READ
  COMMITTED (a consumer Need that the Piece checks and cannot set) and takes the invoice row
  with `SELECT ... FOR UPDATE` before it reads lines or payments; `finalize/3` takes the series
  row last. Amounts are stored as their `Elzoo.Money.Codec` bytes and summed with
  `domain/money` only.

  Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount. The Piece
  emits no telemetry and no log; its queries pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.Money
  alias Elzoo.Money.{Amount, Codec, Currency}
  alias Elzoo.TenantIsolation

  @max Integer.pow(2, 63) - 1
  @max_lines 256
  @tables ~w(elzoo_invoices elzoo_invoice_lines elzoo_invoice_applications elzoo_invoice_reversals elzoo_invoice_series)
  @states [:draft, :open, :paid, :void, :issued]
  @atoms Map.new(
           [:invoice, :credit_note, :usage, :fee, :adjustment, :pending, :posted] ++ @states,
           &{Atom.to_string(&1), &1}
         )
  @refusals [
    :invalid,
    :isolation,
    :conflict,
    :unknown_invoice,
    :currency,
    :incomplete_charge,
    :invalid_total,
    :over_payment,
    :over_reversal,
    :nothing_applied,
    :unknown_payment,
    :paid_amount,
    :credited,
    :over_credit,
    :stale_revision
  ]
  @columns "invoice_id, kind, billing_account, currency, series, number, state, total, paid, credited, issued_at_ms, due_at_ms, corrects, operation_id, posting_state, revision, request_digest"

  @enforce_keys [:repo, :prefix]
  defstruct @enforce_keys

  @doc "A binding: exactly `repo:` and `prefix:`. `{:ok, binding}` or `{:error, :invalid}`."
  def new(opts) do
    with true <- Keyword.keyword?(opts),
         [:prefix, :repo] <- Enum.sort(Keyword.keys(opts)),
         repo when is_atom(repo) and repo not in [nil, true, false] <- opts[:repo],
         true <- identifier?(opts[:prefix]) do
      {:ok, %__MODULE__{repo: repo, prefix: opts[:prefix]}}
    else
      _ -> {:error, :invalid}
    end
  end

  @doc false
  # The quoted schema name, shared with Elzoo.Invoice.Migration.install/1.
  def prefix!(prefix) do
    if identifier?(prefix),
      do: ~s("#{prefix}"),
      else: raise(ArgumentError, "invalid invoice prefix")
  end

  @doc false
  def tables, do: @tables

  defp identifier?(name), do: is_binary(name) and name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  # ── create ──────────────────────────────────────────────────────────────

  @doc """
  Store a `:draft` invoice for `%{invoice_id, billing_account, currency, series}`:
  `{:ok, :applied}`, or `{:ok, :duplicate}` for equal bytes and `{:error, :conflict}` for others.
  """
  def create(inv, tenant, request) do
    write(inv, tenant, create_shape(request), fn b, r ->
      zero = encode!(r.zero)
      digest = digest(["elzoo-invoice/create/1", r.invoice_id, r.billing_account, zero, r.series])

      inserted =
        query(
          b,
          "INSERT INTO #{t(b, :invoices)} (tenant, invoice_id, kind, billing_account, currency, series, state, total, paid, credited, revision, request_digest) VALUES ($1, $2, 'invoice', $3, $4, $5, 'draft', $4, $4, $4, 1, $6) ON CONFLICT (tenant, invoice_id) DO NOTHING",
          [tenant, r.invoice_id, r.billing_account, zero, r.series, digest]
        )

      if inserted.num_rows == 1, do: {:ok, :applied}, else: same_request(b, tenant, r, digest)
    end)
  end

  defp create_shape(%{invoice_id: id, billing_account: ba, currency: c, series: s} = r)
       when map_size(r) == 4 do
    with true <- text?(id, 100) and text?(ba, 128) and text?(s, 128),
         %Currency{} <- c,
         {:ok, zero} <- Money.from_minor_units(c, 0),
         {:ok, _} <- Codec.encode(zero) do
      {:ok, %{invoice_id: id, billing_account: ba, zero: zero, series: s}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp create_shape(_request), do: {:error, :invalid}

  # An existing document with this invoice_id: equal creation request duplicate, else conflict.
  defp same_request(b, tenant, r, digest) do
    case fetch(b, tenant, r.invoice_id, "") do
      {:ok, %{digest: ^digest}} -> {:ok, :duplicate}
      {:ok, _other} -> {:error, :conflict}
      {:error, :unknown_invoice} -> {:error, :unavailable}
    end
  end

  # ── lines ───────────────────────────────────────────────────────────────

  @doc """
  Add one line to a draft, `%{invoice_id, line}` with `line` `{:charge, line_id, charge,
  description}`, `{:fee, line_id, fee_line, description}` or `{:adjustment, line_id, amount,
  description, source_ref}`. Idempotent by `line_id`.
  """
  def add_line(inv, tenant, request) do
    write(inv, tenant, add_line_shape(request), fn b, {id, line} ->
      with {:ok, d} <- fetch(b, tenant, id, " FOR UPDATE"),
           :fresh <- line_before(b, tenant, id, line),
           :ok <- if(d.state == :draft, do: :ok, else: {:error, {:state, d.state}}),
           :ok <- currency(line.amount, d.zero),
           :ok <- valid(d.kind == :credit_note or line.amount.minor_units >= 0),
           count = line_count(b, tenant, id),
           :ok <- valid(count < @max_lines),
           {:ok, total} <- sum(d.total, line.amount) do
        insert_lines(b, tenant, id, [line], count)
        update(b, tenant, d, total: encode!(total))
      end
    end)
  end

  defp add_line_shape(%{invoice_id: id, line: line} = r) when map_size(r) == 2 do
    if text?(id, 100), do: with({:ok, l} <- line(line), do: {:ok, {id, l}}), else: invalid()
  end

  defp add_line_shape(_request), do: invalid()

  # A domain/pricing charge: refused when incomplete; one :usage line of its total.
  defp line({:charge, line_id, charge, description}) do
    with %{
           card: %{card_id: card_id, version: version},
           period: period,
           total: total,
           incomplete: incomplete,
           unknown_count: unknown
         }
         when is_boolean(incomplete) and is_integer(unknown) and unknown >= 0 and
                is_binary(card_id) and is_integer(version) and version >= 0 and
                is_binary(period) <- charge,
         {:ok, l} <-
           line(:usage, line_id, total, description, "#{card_id}/#{version}/#{period}") do
      if incomplete or unknown > 0, do: {:error, :incomplete_charge}, else: {:ok, l}
    else
      _ -> invalid()
    end
  end

  # A domain/plan fee line, taken as data: one :fee line of its amount.
  defp line({:fee, line_id, fee, description}) do
    case fee do
      %{
        subscription_id: sid,
        period: %{index: index, start_ms: _, end_ms: _},
        plan: %{plan_id: _, version: _},
        amount: amount
      }
      when is_binary(sid) and is_integer(index) and index >= 0 ->
        line(:fee, line_id, amount, description, "#{sid}/#{index}")

      _ ->
        invalid()
    end
  end

  defp line({:adjustment, line_id, amount, description, source_ref}),
    do: line(:adjustment, line_id, amount, description, source_ref)

  defp line(_line), do: invalid()

  # Zero or positive for :usage and :fee, non-zero for :adjustment; a negative amount is
  # refused later on an invoice (only a credit note takes one).
  defp line(kind, line_id, amount, description, source_ref) do
    with true <- text?(line_id, 128) and description?(description) and text?(source_ref, 256),
         %Amount{minor_units: m}
         when (kind == :adjustment and m != 0) or (kind != :adjustment and m >= 0) <-
           amount,
         {:ok, bytes} <- Codec.encode(amount) do
      {:ok,
       %{
         line_id: line_id,
         kind: kind,
         description: description,
         amount: amount,
         bytes: bytes,
         source_ref: source_ref
       }}
    else
      _ -> invalid()
    end
  end

  defp line_before(b, tenant, id, line) do
    case rows(
           b,
           "SELECT kind, description, amount, source_ref FROM #{t(b, :lines)} WHERE tenant = $1 AND invoice_id = $2 AND line_id = $3",
           [tenant, id, line.line_id]
         ) do
      [] ->
        :fresh

      [stored] ->
        if stored == [Atom.to_string(line.kind), line.description, line.bytes, line.source_ref],
          do: {:ok, :duplicate},
          else: {:error, :conflict}
    end
  end

  defp line_count(b, tenant, id) do
    [[n]] =
      rows(
        b,
        "SELECT count(*) FROM #{t(b, :lines)} WHERE tenant = $1 AND invoice_id = $2",
        [tenant, id]
      )

    n
  end

  # Lines take the positions after the `count` that the document holds.
  defp insert_lines(b, tenant, id, lines, count) do
    query(
      b,
      "INSERT INTO #{t(b, :lines)} (tenant, invoice_id, line_id, position, kind, description, amount, source_ref) SELECT $1, $2, x.l, x.p, x.k, x.d, x.a, x.s FROM unnest($3::text[], $4::integer[], $5::text[], $6::text[], $7::text[], $8::text[]) AS x(l, p, k, d, a, s)",
      [
        tenant,
        id,
        Enum.map(lines, & &1.line_id),
        Enum.to_list((count + 1)..(count + length(lines))//1),
        Enum.map(lines, &Atom.to_string(&1.kind)),
        Enum.map(lines, & &1.description),
        Enum.map(lines, & &1.bytes),
        Enum.map(lines, & &1.source_ref)
      ]
    )
  end

  # ── finalize ────────────────────────────────────────────────────────────

  @doc """
  Finalize a draft, `%{invoice_id, issued_at_ms, due_at_ms}`: `{:ok, %{number, operation_id,
  total, duplicate}}`; a repeat on a finalized document returns the same number and operation
  ID with `duplicate: true`.
  """
  def finalize(inv, tenant, request) do
    write(inv, tenant, finalize_shape(request), fn b, r ->
      # kind and corrects never change: the plain read only decides the lock order (the
      # corrected invoice's row, then the credit note's own, then the series row).
      with {:ok, head} <- fetch(b, tenant, r.invoice_id, ""),
           {:ok, corrected} <- corrected(b, tenant, head),
           {:ok, d} <- fetch(b, tenant, r.invoice_id, " FOR UPDATE") do
        cond do
          d.number != nil ->
            {:ok,
             %{number: d.number, operation_id: d.operation_id, total: d.total, duplicate: true}}

          d.state != :draft ->
            {:error, {:state, d.state}}

          line_count(b, tenant, d.invoice_id) == 0 ->
            invalid()

          d.kind == :invoice ->
            finalize_invoice(b, tenant, d, r)

          true ->
            finalize_credit_note(b, tenant, d, corrected, r)
        end
      end
    end)
  end

  defp finalize_shape(%{invoice_id: id, issued_at_ms: issued, due_at_ms: due} = r)
       when map_size(r) == 3 do
    if text?(id, 100) and time?(issued) and time?(due) and due >= issued,
      do: {:ok, r},
      else: invalid()
  end

  defp finalize_shape(_request), do: invalid()

  defp corrected(b, tenant, %{kind: :credit_note, corrects: id}),
    do: fetch(b, tenant, id, " FOR UPDATE")

  defp corrected(_b, _tenant, _head), do: {:ok, nil}

  defp finalize_invoice(b, tenant, d, r) do
    if d.total.minor_units < 0 do
      {:error, :invalid_total}
    else
      state = if d.total.minor_units == 0, do: :paid, else: :open
      issue(b, tenant, d, r, state)
    end
  end

  defp finalize_credit_note(b, tenant, d, c, r) do
    with :ok <- if(d.total.minor_units < 0, do: :ok, else: {:error, :invalid_total}),
         :ok <- if(c.state in [:open, :paid], do: :ok, else: {:error, {:state, c.state}}),
         {:ok, magnitude} <- Money.negate(d.total),
         :ok <- within(magnitude, payable(c), :over_credit),
         {:ok, credited} <- Money.add(c.credited, magnitude) do
      {:ok, result} = issue(b, tenant, d, r, :issued)
      payable = sub!(c.total, credited)
      state = if c.state == :paid or cmp(c.paid, payable) != :lt, do: :paid, else: :open
      update(b, tenant, c, credited: encode!(credited), state: Atom.to_string(state))
      {:ok, result}
    end
  end

  # Take the series' next number under the series row lock and number the document. The
  # series row is created on first use and then locked like any other.
  defp issue(b, tenant, d, r, state) do
    query(
      b,
      "INSERT INTO #{t(b, :series)} (tenant, series, last_number) VALUES ($1, $2, 0) ON CONFLICT (tenant, series) DO NOTHING",
      [tenant, d.series]
    )

    [[last]] =
      rows(
        b,
        "SELECT last_number FROM #{t(b, :series)} WHERE tenant = $1 AND series = $2 FOR UPDATE",
        [tenant, d.series]
      )

    number = last + 1

    query(
      b,
      "UPDATE #{t(b, :series)} SET last_number = $3 WHERE tenant = $1 AND series = $2",
      [tenant, d.series, number]
    )

    # The journal takes no zero posting, so a zero total names no operation.
    op = if d.total.minor_units == 0, do: nil, else: "invoice/#{d.invoice_id}/issue"

    update(b, tenant, d,
      number: number,
      state: Atom.to_string(state),
      issued_at_ms: r.issued_at_ms,
      due_at_ms: r.due_at_ms,
      operation_id: op,
      posting_state: op && "pending"
    )

    {:ok, %{number: number, operation_id: op, total: d.total, duplicate: false}}
  end

  # ── posting ─────────────────────────────────────────────────────────────

  @doc """
  Record the host's journal result, `%{invoice_id, operation_id, result}` with `result`
  `:applied` or `:duplicate`: the posting becomes `:posted`.
  """
  def mark_posted(inv, tenant, request) do
    write(inv, tenant, mark_posted_shape(request), fn b, {id, op} ->
      with {:ok, d} <- fetch(b, tenant, id, " FOR UPDATE") do
        cond do
          d.operation_id == nil or d.operation_id != op -> {:error, :conflict}
          d.posting_state == "posted" -> {:ok, :duplicate}
          true -> update(b, tenant, d, posting_state: "posted")
        end
      end
    end)
  end

  defp mark_posted_shape(%{invoice_id: id, operation_id: op, result: result} = r)
       when map_size(r) == 3 and result in [:applied, :duplicate] do
    if text?(id, 100) and text?(op, 128), do: {:ok, {id, op}}, else: invalid()
  end

  defp mark_posted_shape(_request), do: invalid()

  # ── payments ────────────────────────────────────────────────────────────

  @doc """
  Apply `%{invoice_id, payment_ref, amount}` to an `:open` invoice, up to its payable;
  idempotent by `payment_ref`. The invoice becomes `:paid` when `paid` reaches `payable`.
  """
  def apply_payment(inv, tenant, request) do
    write(inv, tenant, payment_shape(request), fn b, r ->
      with {:ok, d} <- fetch(b, tenant, r.invoice_id, " FOR UPDATE"),
           :fresh <- payment_before(b, tenant, r),
           :ok <- if(d.state == :open, do: :ok, else: {:error, {:state, d.state}}),
           :ok <- currency(r.amount, d.zero),
           payable = payable(d),
           {:ok, paid} <- Money.add(d.paid, r.amount),
           :ok <- within(paid, payable, :over_payment) do
        query(
          b,
          "INSERT INTO #{t(b, :applications)} (tenant, invoice_id, payment_ref, amount) VALUES ($1, $2, $3, $4)",
          [tenant, r.invoice_id, r.payment_ref, r.bytes]
        )

        state = if cmp(paid, payable) == :lt, do: :open, else: :paid
        update(b, tenant, d, paid: encode!(paid), state: Atom.to_string(state))
      else
        {:error, {:scale_overflow, _}} -> {:error, :over_payment}
        other -> other
      end
    end)
  end

  defp payment_shape(%{invoice_id: id, payment_ref: ref, amount: amount} = r)
       when map_size(r) == 3 do
    with true <- text?(id, 100) and text?(ref, 256),
         %Amount{minor_units: m} when m > 0 <- amount,
         {:ok, bytes} <- Codec.encode(amount) do
      {:ok, %{invoice_id: id, payment_ref: ref, amount: amount, bytes: bytes}}
    else
      _ -> invalid()
    end
  end

  defp payment_shape(_request), do: invalid()

  defp payment_before(b, tenant, r) do
    case application(b, tenant, r.invoice_id, r.payment_ref) do
      nil -> :fresh
      {bytes, _} when bytes == r.bytes -> {:ok, :duplicate}
      _ -> {:error, :conflict}
    end
  end

  defp application(b, tenant, id, ref) do
    case rows(
           b,
           "SELECT amount FROM #{t(b, :applications)} WHERE tenant = $1 AND invoice_id = $2 AND payment_ref = $3",
           [tenant, id, ref]
         ) do
      [] -> nil
      [[bytes]] -> {bytes, decode!(bytes)}
    end
  end

  @doc """
  Take back `%{invoice_id, reversal_id, payment_ref, amount}` of one application, `amount`
  positive or `:remaining`, up to what of it is still applied; idempotent by `reversal_id`.
  A `:paid` invoice becomes `:open` again when `paid` drops below `payable`.
  """
  def reverse_payment(inv, tenant, request) do
    write(inv, tenant, reversal_shape(request), fn b, r ->
      with {:ok, d} <- fetch(b, tenant, r.invoice_id, " FOR UPDATE"),
           :fresh <- reversal_before(b, tenant, r),
           {:ok, applied} <- applied(b, tenant, r),
           :ok <- if(r.amount == :remaining, do: :ok, else: currency(r.amount, d.zero)),
           rest = still_applied(b, tenant, r, applied),
           {:ok, amount} <- taken(r.amount, rest) do
        query(
          b,
          "INSERT INTO #{t(b, :reversals)} (tenant, invoice_id, reversal_id, payment_ref, requested, amount) VALUES ($1, $2, $3, $4, $5, $6)",
          [tenant, r.invoice_id, r.reversal_id, r.payment_ref, r.requested, encode!(amount)]
        )

        paid = sub!(d.paid, amount)

        state =
          if d.state == :paid and cmp(paid, payable(d)) == :lt, do: :open, else: d.state

        update(b, tenant, d, paid: encode!(paid), state: Atom.to_string(state))
      end
    end)
  end

  defp reversal_shape(%{invoice_id: id, reversal_id: rid, payment_ref: ref, amount: amount} = r)
       when map_size(r) == 4 do
    with true <- text?(id, 100) and text?(rid, 256) and text?(ref, 256),
         {:ok, requested} <- requested(amount) do
      {:ok, Map.put(r, :requested, requested)}
    else
      _ -> invalid()
    end
  end

  defp reversal_shape(_request), do: invalid()

  defp requested(:remaining), do: {:ok, "remaining"}
  defp requested(%Amount{minor_units: m} = amount) when m > 0, do: Codec.encode(amount)
  defp requested(_amount), do: :error

  defp reversal_before(b, tenant, r) do
    case rows(
           b,
           "SELECT payment_ref, requested FROM #{t(b, :reversals)} WHERE tenant = $1 AND invoice_id = $2 AND reversal_id = $3",
           [tenant, r.invoice_id, r.reversal_id]
         ) do
      [] -> :fresh
      [[ref, requested]] when ref == r.payment_ref and requested == r.requested -> {:ok, :duplicate}
      [_] -> {:error, :conflict}
    end
  end

  defp applied(b, tenant, r) do
    case application(b, tenant, r.invoice_id, r.payment_ref) do
      nil -> {:error, :unknown_payment}
      {_bytes, amount} -> {:ok, amount}
    end
  end

  # The application's amount minus its earlier reversals.
  defp still_applied(b, tenant, r, applied) do
    rows(
      b,
      "SELECT amount FROM #{t(b, :reversals)} WHERE tenant = $1 AND invoice_id = $2 AND payment_ref = $3",
      [tenant, r.invoice_id, r.payment_ref]
    )
    |> Enum.reduce(applied, fn [bytes], rest -> sub!(rest, decode!(bytes)) end)
  end

  defp taken(:remaining, rest),
    do: if(rest.minor_units == 0, do: {:error, :nothing_applied}, else: {:ok, rest})

  defp taken(amount, rest), do: with(:ok <- within(amount, rest, :over_reversal), do: {:ok, amount})

  # ── void ────────────────────────────────────────────────────────────────

  @doc """
  Void `%{invoice_id, expected_revision}`: a `:draft` or `:open` document with nothing paid and
  nothing credited. A finalized invoice keeps its number.
  """
  def void(inv, tenant, request) do
    write(inv, tenant, void_shape(request), fn b, {id, expected} ->
      with {:ok, d} <- fetch(b, tenant, id, " FOR UPDATE") do
        cond do
          d.revision != expected -> {:error, :stale_revision}
          d.paid.minor_units != 0 -> {:error, :paid_amount}
          d.credited.minor_units != 0 -> {:error, :credited}
          d.state not in [:draft, :open] -> {:error, {:state, d.state}}
          true -> update(b, tenant, d, state: "void")
        end
      end
    end)
  end

  defp void_shape(%{invoice_id: id, expected_revision: rev} = r)
       when map_size(r) == 2 and is_integer(rev) and rev in 1..@max//1 do
    if text?(id, 100), do: {:ok, {id, rev}}, else: invalid()
  end

  defp void_shape(_request), do: invalid()

  # ── credit notes ────────────────────────────────────────────────────────

  @doc """
  Create a draft credit note `%{invoice_id, corrects, lines}` of an `:open` or `:paid` invoice:
  1..256 `{:adjustment, line_id, amount, description, source_ref}` lines with negative
  amounts whose magnitude is at most the corrected invoice's payable. Idempotent by
  `invoice_id`.
  """
  def credit_note(inv, tenant, request) do
    write(inv, tenant, credit_note_shape(request), fn b, r ->
      digest = credit_note_digest(r)

      # An existing document decides first; the read takes no lock, so the corrected
      # invoice's row is still locked before the credit note's own.
      case fetch(b, tenant, r.invoice_id, "") do
        {:ok, _} -> same_request(b, tenant, r, digest)
        {:error, :unknown_invoice} -> new_credit_note(b, tenant, r, digest)
      end
    end)
  end

  defp new_credit_note(b, tenant, r, digest) do
    with {:ok, c} <- fetch(b, tenant, r.corrects, " FOR UPDATE"),
         :ok <-
           if(c.kind == :invoice and c.state in [:open, :paid],
             do: :ok,
             else: {:error, {:state, c.state}}
           ),
         :ok <-
           Enum.find_value(
             r.lines,
             :ok,
             &(currency(&1.amount, c.zero) != :ok && {:error, :currency})
           ),
         {:ok, total} <- total(c.zero, r.lines),
         {:ok, magnitude} <- Money.negate(total),
         :ok <- within(magnitude, payable(c), :over_credit) do
      inserted =
        query(
          b,
          "INSERT INTO #{t(b, :invoices)} (tenant, invoice_id, kind, billing_account, currency, series, state, total, paid, credited, corrects, revision, request_digest) VALUES ($1, $2, 'credit_note', $3, $4, $5, 'draft', $6, $4, $4, $7, 1, $8) ON CONFLICT (tenant, invoice_id) DO NOTHING",
          [
            tenant,
            r.invoice_id,
            c.billing_account,
            encode!(c.zero),
            c.series,
            encode!(total),
            c.invoice_id,
            digest
          ]
        )

      if inserted.num_rows == 1 do
        insert_lines(b, tenant, r.invoice_id, r.lines, 0)
        {:ok, :applied}
      else
        same_request(b, tenant, r, digest)
      end
    end
  end

  defp credit_note_shape(%{invoice_id: id, corrects: corrects, lines: lines} = r)
       when map_size(r) == 3 do
    with true <- text?(id, 100) and text?(corrects, 100) and proper?(lines),
         true <- length(lines) in 1..@max_lines//1,
         {:ok, lines} <- credit_lines(lines, []),
         true <- length(Enum.uniq_by(lines, & &1.line_id)) == length(lines) do
      {:ok, %{invoice_id: id, corrects: corrects, lines: lines}}
    else
      _ -> invalid()
    end
  end

  defp credit_note_shape(_request), do: invalid()

  defp credit_lines([], acc), do: {:ok, Enum.reverse(acc)}

  defp credit_lines([{:adjustment, _, _, _, _} = line | rest], acc) do
    case line(line) do
      {:ok, %{amount: %Amount{minor_units: m}} = l} when m < 0 -> credit_lines(rest, [l | acc])
      _ -> :error
    end
  end

  defp credit_lines(_lines, _acc), do: :error

  defp credit_note_digest(r) do
    digest([
      "elzoo-invoice/credit-note/1",
      r.invoice_id,
      r.corrects
      | Enum.flat_map(r.lines, &[&1.line_id, &1.description, &1.bytes, &1.source_ref])
    ])
  end

  # ── read ────────────────────────────────────────────────────────────────

  @doc """
  `{:ok, invoice}` for `%{invoice_id}`: `%{invoice_id, kind, billing_account, currency, series,
  number, state, lines, total, credited, payable, paid, credit_balance, issued_at_ms,
  due_at_ms, corrects, posting, revision}`.
  """
  def get(inv, tenant, request) do
    shape =
      case request do
        %{invoice_id: id} when map_size(request) == 1 ->
          if text?(id, 100), do: {:ok, id}, else: invalid()

        _ ->
          invalid()
      end

    with {:ok, b} <- bound(inv),
         true <- text?(tenant, 128) || invalid(),
         {:ok, id} <- shape,
         :ok <- outside(b) do
      # FOR SHARE: the row and its lines are one state, since every write locks the row first.
      run(b, tenant, fn ->
        with {:ok, d} <- fetch(b, tenant, id, " FOR SHARE"), do: {:ok, view(b, tenant, d)}
      end)
    end
  end

  defp view(b, tenant, d) do
    lines =
      rows(
        b,
        "SELECT line_id, kind, description, amount, source_ref FROM #{t(b, :lines)} WHERE tenant = $1 AND invoice_id = $2 ORDER BY position",
        [tenant, d.invoice_id]
      )
      |> Enum.map(fn [line_id, kind, description, amount, ref] ->
        %{
          line_id: line_id,
          kind: atom(kind),
          description: description,
          amount: decode!(amount),
          source_ref: ref
        }
      end)

    payable = payable(d)

    excess =
      if d.kind == :invoice and cmp(d.paid, payable) == :gt,
        do: sub!(d.paid, payable),
        else: d.zero

    %{
      invoice_id: d.invoice_id,
      kind: d.kind,
      billing_account: d.billing_account,
      currency: d.zero.currency,
      series: d.series,
      number: d.number,
      state: d.state,
      lines: lines,
      total: d.total,
      credited: d.credited,
      payable: payable,
      paid: d.paid,
      credit_balance: excess,
      issued_at_ms: d.issued_at_ms,
      due_at_ms: d.due_at_ms,
      corrects: d.corrects,
      posting: d.operation_id && %{operation_id: d.operation_id, state: atom(d.posting_state)},
      revision: d.revision
    }
  end

  @doc """
  Check the five tables with `Elzoo.TenantIsolation.verify/3`: `:ok` or the first table's
  `{:error, reason}`.
  """
  def verify(inv) do
    with {:ok, b} <- bound(inv) do
      Enum.reduce_while(@tables, :ok, fn table, :ok ->
        case TenantIsolation.verify(b.repo, {b.prefix, table},
               prefix: b.prefix,
               tenant_column: "tenant",
               space_column: nil
             ) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # ── shared steps ────────────────────────────────────────────────────────

  # Shape and bounds, then the caller's transaction, then one transaction at READ COMMITTED.
  defp write(inv, tenant, shape, fun) do
    with {:ok, b} <- bound(inv),
         true <- text?(tenant, 128) || invalid(),
         {:ok, r} <- shape,
         :ok <- outside(b) do
      run(b, tenant, fn -> with :ok <- isolation(b), do: fun.(b, r) end)
    end
  end

  # The level is the consumer's Need; transact/3 cannot set it.
  defp isolation(b) do
    case rows(b, "SELECT current_setting('transaction_isolation')", []) do
      [["read committed"]] -> :ok
      _ -> {:error, :isolation}
    end
  end

  defp fetch(b, tenant, id, lock) do
    case rows(
           b,
           "SELECT #{@columns} FROM #{t(b, :invoices)} WHERE tenant = $1 AND invoice_id = $2#{lock}",
           [tenant, id]
         ) do
      [] ->
        {:error, :unknown_invoice}

      [
        [
          id,
          kind,
          ba,
          zero,
          series,
          number,
          state,
          total,
          paid,
          credited,
          issued,
          due,
          corrects,
          op,
          posting,
          revision,
          digest
        ]
      ] ->
        {:ok,
         %{
           invoice_id: id,
           kind: atom(kind),
           billing_account: ba,
           zero: decode!(zero),
           series: series,
           number: number,
           state: atom(state),
           total: decode!(total),
           paid: decode!(paid),
           credited: decode!(credited),
           issued_at_ms: issued,
           due_at_ms: due,
           corrects: corrects,
           operation_id: op,
           posting_state: posting,
           revision: revision,
           digest: digest
         }}
    end
  end

  # Set the given columns of the locked document and advance its revision.
  defp update(b, tenant, d, sets) do
    {assigns, params} =
      sets
      |> Enum.with_index(3)
      |> Enum.map(fn {{column, value}, i} -> {"#{column} = $#{i}", value} end)
      |> Enum.unzip()

    query(
      b,
      "UPDATE #{t(b, :invoices)} SET #{Enum.join(assigns, ", ")}, revision = revision + 1 WHERE tenant = $1 AND invoice_id = $2",
      [tenant, d.invoice_id | params]
    )

    {:ok, :applied}
  end

  # ── money ───────────────────────────────────────────────────────────────

  # The same currency identity {alpha, numeric, minor_unit} as the document's.
  defp currency(%Amount{currency: a}, %Amount{currency: c}) do
    if {a.alpha, a.numeric, a.minor_unit} == {c.alpha, c.numeric, c.minor_unit},
      do: :ok,
      else: {:error, :currency}
  end

  defp payable(d), do: sub!(d.total, d.credited)

  defp total(zero, lines) do
    Enum.reduce_while(lines, {:ok, zero}, fn l, {:ok, acc} ->
      case sum(acc, l.amount) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  # A sum outside the domain/money range is invalid input.
  defp sum(a, b) do
    case Money.add(a, b) do
      {:ok, s} -> {:ok, s}
      {:error, _} -> invalid()
    end
  end

  defp sub!(a, b) do
    {:ok, d} = Money.subtract(a, b)
    d
  end

  defp cmp(a, b) do
    {:ok, c} = Money.compare(a, b)
    c
  end

  defp within(amount, limit, refusal),
    do: if(cmp(amount, limit) == :gt, do: {:error, refusal}, else: :ok)

  defp encode!(amount) do
    {:ok, bytes} = Codec.encode(amount)
    bytes
  end

  defp decode!(bytes) do
    {:ok, amount} = Codec.decode(bytes)
    amount
  end

  # ── plumbing ────────────────────────────────────────────────────────────

  defp bound(%__MODULE__{repo: repo, prefix: prefix} = b)
       when is_atom(repo) and repo not in [nil, true, false] do
    if identifier?(prefix), do: {:ok, b}, else: invalid()
  end

  defp bound(_other), do: invalid()

  defp invalid, do: {:error, :invalid}

  defp valid(true), do: :ok
  defp valid(false), do: invalid()

  # The Piece opens its own transaction and never joins a caller's.
  defp outside(b), do: if(b.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # One transaction under the tenant scope. A refusal rolls back; a database failure, including
  # a lost connection, is :unavailable and says nothing about whether the write committed.
  defp run(b, tenant, fun) do
    case TenantIsolation.transact(b.repo, %{tenant: tenant}, fun) do
      {:ok, _} = ok -> ok
      {:error, {:tenant_isolation, :in_transaction}} -> {:error, :in_transaction}
      {:error, {:state, s}} = refusal when s in @states -> refusal
      {:error, reason} when reason in @refusals -> {:error, reason}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp t(b, :invoices), do: ~s("#{b.prefix}".elzoo_invoices)
  defp t(b, name), do: ~s("#{b.prefix}".elzoo_invoice_#{name})

  defp query(b, sql, params), do: SQL.query!(b.repo, sql, params, log: false)
  defp rows(b, sql, params), do: query(b, sql, params).rows

  defp atom(text), do: Map.fetch!(@atoms, text)

  # SHA-256 of the fields, each as a 32-bit big-endian byte length and its bytes.
  defp digest(fields), do: :crypto.hash(:sha256, Enum.map(fields, &[<<byte_size(&1)::32>>, &1]))

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false

  defp time?(n), do: is_integer(n) and n in 0..@max//1

  # 1..1024 bytes of valid UTF-8 without NUL (a PostgreSQL text value holds no NUL).
  defp description?(d),
    do:
      is_binary(d) and byte_size(d) in 1..1024//1 and String.valid?(d) and
        not String.contains?(d, <<0>>)

  # 1..max bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes.
  defp text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max//1 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
