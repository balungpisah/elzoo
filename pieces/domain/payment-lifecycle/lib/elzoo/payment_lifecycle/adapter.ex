# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PaymentLifecycle.Adapter do
  @moduledoc """
  The shared body of the two `delivery/effect-intent` Adapters, `ChargeAdapter` and
  `RefundAdapter` (README "Adapters"). The `adapter_context` of the intent is the lifecycle
  value from `Elzoo.PaymentLifecycle.new/1`.

  A send calls the provider Need once with the request's derived key as `idempotency_key`,
  stores the answer as the next observation row of its operation, then returns the envelope or
  declared tag. A poll does the same with `poll`. Completed envelopes and poll certificates
  carry a process-local seal that `authenticate/2` checks. Details are fixed atoms; no provider
  code or body enters an envelope.
  """
  alias Elzoo.Money.Codec
  alias Elzoo.PaymentLifecycle, as: PL

  @schema "elzoo/payment-arguments-v1"
  @value_schema "elzoo/payment-result"
  @detail :payment_lifecycle

  def schema, do: @schema

  def validate(kind, bytes, @schema) do
    case PL.decode_arguments(bytes) do
      {:ok, a} -> if elem(a.operation, 0) == kind, do: :ok, else: {:error, :schema}
      :error -> {:error, :schema}
    end
  end

  def validate(_kind, _bytes, _schema), do: {:error, :schema}

  # ── send ──────────────────────────────────────────────────────────────

  def send_effect(kind, req) do
    with %{context: %PL{} = lc, key: key, attempt: n, attempt_id: aid} <- req,
         true <- is_binary(req.arguments),
         {:ok, a} <- PL.decode_arguments(req.arguments),
         true <- elem(a.operation, 0) == kind do
      case gate(lc, a) do
        {:ok, charge_ref} -> send_once(lc, a, key, n, aid, charge_ref)
        :closed -> failure(:refund_closed)
        :error -> failure(:store_unavailable)
      end
    else
      _ -> failure(:adapter_error)
    end
  rescue
    _ -> failure(:adapter_error)
  catch
    _, _ -> failure(:adapter_error)
  end

  # The RefundAdapter reads the refund row and its observations first; a charge has no gate.
  defp gate(_lc, %{operation: {:charge, _}}), do: {:ok, nil}

  defp gate(lc, %{tenant: t, operation: {:refund, id, rid}}),
    do: PL.refund_gate(lc, t, id, rid)

  defp send_once(lc, a, key, n, aid, charge_ref) do
    answer = answer(call(lc, a, key, charge_ref))
    stored = store(lc, a, n, "send", answer)

    case answer do
      {"ok", state, ref, _} when state in [:succeeded, :failed] ->
        if stored == :ok,
          do: completed(lc, key, aid, ref, state),
          else: failure(:observation_unrecorded)

      {"ok", :pending, _, _} ->
        failure(:provider_pending)

      {"declined", _, _, _} ->
        if stored == :ok, do: failure(:declined), else: failure(:observation_unrecorded)

      {"not_sent", _, _, _} ->
        failure(:not_sent)

      {"unknown", _, _, "timeout"} ->
        failure(:timeout)

      {"unknown", _, _, "transport"} ->
        failure(:transport)

      _ ->
        failure(:adapter_error)
    end
  end

  # Exactly one provider call; an exception or an answer outside the Contract is unknown.
  defp call(lc, %{operation: {:charge, id}} = a, key, nil) do
    lc.provider.charge(%{
      idempotency_key: key,
      payment_id: id,
      amount: amount(a),
      recipient: a.recipient
    })
  rescue
    _ -> :invalid
  catch
    _, _ -> :invalid
  end

  defp call(lc, %{operation: {:refund, id, rid}} = a, key, charge_ref) do
    lc.provider.refund(%{
      idempotency_key: key,
      payment_id: id,
      refund_id: rid,
      provider_ref: charge_ref,
      amount: amount(a)
    })
  rescue
    _ -> :invalid
  catch
    _, _ -> :invalid
  end

  defp amount(a) do
    {:ok, amount} = Codec.decode(a.amount)
    amount
  end

  # {answer, state, provider_ref, detail} of a send answer; anything else is unknown.
  defp answer({:ok, %{provider_ref: ref, state: s} = r})
       when map_size(r) == 2 and s in [:succeeded, :pending, :failed] do
    if PL.text?(ref, 256), do: {"ok", s, ref, nil}, else: {"unknown", nil, nil, nil}
  end

  defp answer({:declined, code}),
    do: {"declined", nil, nil, if(PL.text?(code, 256), do: code, else: nil)}

  defp answer({:not_sent, _}), do: {"not_sent", nil, nil, nil}
  defp answer({:unknown, :timeout}), do: {"unknown", nil, nil, "timeout"}
  defp answer({:unknown, :transport}), do: {"unknown", nil, nil, "transport"}
  defp answer(_), do: {"unknown", nil, nil, nil}

  # ── poll ──────────────────────────────────────────────────────────────

  def poll(kind, req) do
    with %{context: %PL{} = lc, key: key, attempt: n, attempt_id: aid} <- req,
         true <- is_binary(req.arguments),
         {:ok, a} <- PL.decode_arguments(req.arguments),
         true <- elem(a.operation, 0) == kind do
      answer = poll_answer(lc, key, kind)
      stored = if answer == :invalid, do: :error, else: store(lc, a, n, "poll", answer)

      case answer do
        {"ok", state, ref, _} when state in [:succeeded, :failed] ->
          if stored == :ok,
            do: completed(lc, key, aid, ref, state),
            else: certificate(lc, :pending, key, aid)

        {"ok", :pending, _, _} ->
          certificate(lc, :pending, key, aid)

        {"pending", _, _, _} ->
          certificate(lc, :pending, key, aid)

        {"no_effect", _, _, _} ->
          if kind == :refund and stored != :ok,
            do: certificate(lc, :pending, key, aid),
            else: certificate(lc, :no_effect, key, aid)

        _ ->
          certificate(lc, :unavailable, key, aid)
      end
    else
      _ -> {:unavailable, :adapter_error}
    end
  rescue
    _ -> {:unavailable, :adapter_error}
  catch
    _, _ -> {:unavailable, :adapter_error}
  end

  defp poll_answer(lc, key, kind) do
    case lc.provider.poll(%{idempotency_key: key, kind: kind}) do
      {:ok, %{provider_ref: ref, state: s} = r}
      when map_size(r) == 2 and s in [:succeeded, :pending, :failed] ->
        if PL.text?(ref, 256), do: {"ok", s, ref, nil}, else: :invalid

      :no_effect ->
        {"no_effect", nil, nil, nil}

      :pending ->
        {"pending", nil, nil, nil}

      :unavailable ->
        {"unavailable", nil, nil, nil}

      _ ->
        :invalid
    end
  rescue
    _ -> :invalid
  catch
    _, _ -> :invalid
  end

  # ── results ───────────────────────────────────────────────────────────

  defp store(lc, a, n, source, answer),
    do: PL.observe(lc, a.tenant, elem(a.operation, 1), a.ref, n, source, answer)

  defp completed(lc, key, aid, ref, state) do
    bytes = PL.result_bytes(ref, state)

    %{
      "version" => 1,
      "message_id" => key,
      "correlation_id" => key,
      "attempt_id" => aid,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{"result" => bytes, "seal" => PL.seal(lc, ["result", key, aid, bytes])},
      "value_schema_id" => @value_schema,
      "value_schema_version" => 1
    }
  end

  defp certificate(lc, kind, key, aid),
    do: {kind, PL.seal(lc, ["poll", key, aid, Atom.to_string(kind)])}

  defp failure(tag), do: {:error, tag, @detail}

  def validate_result(
        %{
          "outcome" => "completed",
          "value_schema_id" => @value_schema,
          "value_schema_version" => 1,
          "value" => %{"result" => bytes, "seal" => seal} = v
        },
        _req
      )
      when map_size(v) == 2 and is_binary(seal) do
    case PL.decode_result(bytes) do
      {:ok, _ref, state} when state in [:succeeded, :failed] -> :ok
      _ -> :error
    end
  end

  def validate_result(_, _), do: :error

  # Process-local integrity of this Adapter's own results and certificates, not provider
  # authentication: a forged or post-restart value fails.
  def authenticate({kind, seal}, %{key: key, attempt_id: aid, context: %PL{} = lc})
      when kind in [:pending, :unavailable, :no_effect] and is_binary(seal),
      do: equal(seal, PL.seal(lc, ["poll", key, aid, Atom.to_string(kind)]))

  def authenticate(
        %{"attempt_id" => aid, "value" => %{"result" => bytes, "seal" => seal}},
        %{key: key, attempt_id: aid, context: %PL{} = lc}
      )
      when is_binary(bytes) and is_binary(seal),
      do: equal(seal, PL.seal(lc, ["result", key, aid, bytes]))

  def authenticate(_, _), do: :error

  defp equal(a, b),
    do: if(byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b), do: :ok, else: :error)
end

defmodule Elzoo.PaymentLifecycle.ChargeAdapter do
  @moduledoc "The `delivery/effect-intent` Adapter of a payment's charge (operation `charge`)."
  alias Elzoo.PaymentLifecycle.{Adapter, Binding}
  def failure_tags, do: Map.keys(Binding.failures(:charge)) |> Enum.sort()
  def schema, do: Adapter.schema()
  def validate(bytes, schema), do: Adapter.validate(:charge, bytes, schema)
  def send_effect(req), do: Adapter.send_effect(:charge, req)
  def poll(req), do: Adapter.poll(:charge, req)
  def authenticate(observation, req), do: Adapter.authenticate(observation, req)
  def validate_result(envelope, req), do: Adapter.validate_result(envelope, req)
end

defmodule Elzoo.PaymentLifecycle.RefundAdapter do
  @moduledoc "The `delivery/effect-intent` Adapter of one refund of a payment (operation `refund`)."
  alias Elzoo.PaymentLifecycle.{Adapter, Binding}
  def failure_tags, do: Map.keys(Binding.failures(:refund)) |> Enum.sort()
  def schema, do: Adapter.schema()
  def validate(bytes, schema), do: Adapter.validate(:refund, bytes, schema)
  def send_effect(req), do: Adapter.send_effect(:refund, req)
  def poll(req), do: Adapter.poll(:refund, req)
  def authenticate(observation, req), do: Adapter.authenticate(observation, req)
  def validate_result(envelope, req), do: Adapter.validate_result(envelope, req)
end
