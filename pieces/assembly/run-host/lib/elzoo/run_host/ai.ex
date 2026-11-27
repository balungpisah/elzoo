# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunHost.Ai do
  @moduledoc """
  The AI text bindings of one Run (see the Piece README, "AI model calls"): the
  descriptor check, the `integration/ai-text` Config with the host's sink, the
  derived idempotency key, the gate that records an admission refusal before any
  intent exists, the engine binding with its `facts/1`, and the translation of a
  sink outcome into one engine `action_outcome` input. Pure apart from the
  trusted callbacks of the descriptor and the clock that `facts/1` reads.
  """
  alias Elzoo.AiText
  alias Elzoo.EffectIntent.Model

  @result {"elzoo.ai-text.result", 1}
  @descriptor [:id, :version, :effect_class, :proposal, :estimate, :call_ms, :usage, :ai_text]
  # The host sets these Config options itself: the tenant of the spec, its own sink,
  # and no artifact reader (the profile is text only).
  @host_options [:tenant, :sink, :artifacts, :image_bounds]
  @no_send [:credentials_unavailable, :input_unavailable]

  @doc "The result schema of every AI outcome input."
  def result, do: @result

  @doc """
  Checks the `ai` map of a spec: model_call schema ID (1..200 bytes) to descriptor.
  Returns `{:ok, ai}` with each descriptor's binding loaded, or `:error`.
  """
  def descriptors(ai) when is_map(ai) and map_size(ai) > 0 do
    Enum.reduce_while(ai, {:ok, %{}}, fn {schema_id, d}, {:ok, acc} ->
      case descriptor(schema_id, d) do
        {:ok, checked} -> {:cont, {:ok, Map.put(acc, schema_id, checked)}}
        :error -> {:halt, :error}
      end
    end)
  end

  def descriptors(_), do: :error

  defp descriptor(schema_id, %{} = d) do
    with true <- text?(schema_id, 200),
         true <- Enum.sort(Map.keys(d)) == Enum.sort(@descriptor),
         true <- text?(d.id, 128) and is_integer(d.version) and d.version in 1..2_147_483_647,
         true <- text?(d.effect_class, 128),
         true <- is_function(d.proposal, 1) and is_function(d.usage, 1),
         true <- is_integer(d.estimate) and d.estimate >= 0,
         true <- is_integer(d.call_ms) and d.call_ms in 1..86_400_000,
         true <- Keyword.keyword?(d.ai_text),
         true <- not Enum.any?(@host_options, &Keyword.has_key?(d.ai_text, &1)),
         {:ok, b} <- AiText.Binding.load(d.ai_text[:binding]) do
      {:ok, Map.put(d, :binding, b)}
    else
      _ -> :error
    end
  end

  defp descriptor(_, _), do: :error

  @doc "The ai-text Config of one descriptor, with the Run's tenant and the host's sink."
  def configure(d, tenant, sink),
    do: AiText.configure(d.ai_text ++ [tenant: tenant, sink: sink])

  @doc """
  The AI idempotency key (the logical request reference of ai-text): the lowercase
  hex SHA-256 of the ETF of `{run_id, attempt_id, action_id}`, 64 bytes.
  """
  def ref(run_id, attempt_id, action_id),
    do: hex(:erlang.term_to_binary({run_id, attempt_id, action_id}, [:deterministic]))

  @doc "The EffectIntent key that ai-text derives for one model call of the Run."
  def intent_key(d, tenant, ref),
    do: Model.key([tenant, d.binding.provider_account, d.binding.id, d.binding.operation, ref])

  @doc "ai-text admission of a model_call action whose payload is an ai-text request."
  def admission(config, action, ref, deadline) do
    declaration = %{
      "capability_id" => "integration/ai-text",
      "operation" => "generate",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "m-" <> ref,
        "schema_id" => "elzoo/ai-text-request",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "run-host", "port_id" => "model_call"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => deadline,
        "payload" => Jason.encode!(action["payload"])
      }
    }

    AiText.admission(config, declaration)
  rescue
    _ -> {:error, :declaration}
  end

  @doc """
  The spec's gate with the ai-text admission in front of it: a model_call of an AI
  binding that admission refuses is denied with the refusal reason (an image part
  is `unsupported_feature`, since the host configures no artifact reader), so the
  engine records the refusal before any intent exists. Every other action, and an
  admitted request, goes to the spec's gate unchanged.
  """
  def gate(gate, ai, ids) do
    %{
      gate
      | call: fn checked, facts ->
          with %{"actions" => [%{"kind" => "model_call", "schema_id" => schema_id} = action]} <-
                 Elzoo.PatternStep.encode(checked),
               %{config: config} <- ai[schema_id] do
            ref = ref(ids.run_id, ids.attempt_id, action["id"])

            case admission(config, action, ref, ids.run_deadline) do
              {:ok, _} -> gate.call.(checked, facts)
              {:error, {:refused, reason}} -> {:deny, Atom.to_string(reason)}
              {:error, _} -> {:deny, "invalid_request"}
            end
          else
            _ -> gate.call.(checked, facts)
          end
        end
    }
  end

  @doc """
  The engine binding of one AI descriptor. `facts/1` reads the trusted clock for the
  call deadline and repeats the admission that the gate passed; it does no I/O.
  """
  def binding(d, schema_id, config, ids, clock, unit) do
    %{
      id: d.id,
      version: d.version,
      effect_class: d.effect_class,
      result: @result,
      proposal: d.proposal,
      facts: fn action ->
        deadline = clock.() + d.call_ms
        ref = ref(ids.run_id, ids.attempt_id, action["id"])
        {:ok, a} = admission(config, action, ref, deadline)

        %{
          estimate: d.estimate,
          unit: unit,
          deadline_ms: deadline,
          intent: %{
            identity: a.identity,
            arguments: a.arguments,
            binding: schema_id,
            binding_digest: d.binding.digest,
            deadline_ms: deadline
          }
        }
      end
    }
  end

  @doc """
  The engine input ID of the outcome of one occurrence: `"ai:"` and the hex SHA-256
  of the ETF of `{run_id, attempt_id, occurrence}`, 67 bytes for any action ID.
  """
  def input_id(run_id, attempt_id, occurrence),
    do: "ai:" <> hex(:erlang.term_to_binary({run_id, attempt_id, occurrence}, [:deterministic]))

  @doc """
  Translates one outcome received at the sink: `{:input, outcome, dispatch, actual,
  payload}` (`actual` nil when none) or `:none` for a shape that is no ai-text
  outcome. `usage` is the descriptor's trusted conversion of a reported usage value
  to the Budget unit.
  """
  def translate({:completed, %{} = body}, usage) do
    {:input, "completed", "dispatched", actual(body[:usage], usage), completed_view(body)}
  end

  def translate({:refused, reason, meta}, _) when reason in @no_send,
    do: {:input, "refused", "not_dispatched", 0, refusal_view(reason, meta)}

  def translate({:refused, reason, meta}, _) when is_atom(reason),
    do: {:input, "refused", "dispatched", nil, refusal_view(reason, meta)}

  # A malformed response always reached the provider; every other unknown (a
  # provider error included, which an adapter error also gives) proves no dispatch.
  def translate({:unknown, :malformed_response}, _),
    do: {:input, "unknown", "dispatched", nil, refusal_view(:malformed_response, %{})}

  def translate({:unknown, reason}, _) when is_atom(reason),
    do: {:input, "unknown", "unknown", nil, refusal_view(reason, %{})}

  def translate(_, _), do: :none

  defp actual(%{source: :provider_reported} = usage, convert) do
    case convert.(usage) do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> amount
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp actual(_, _), do: nil

  defp completed_view(body) do
    %{
      "content" => body.content,
      "finish" => finish(body.finish),
      "tool_proposals" =>
        Enum.map(body.tool_proposals, fn p ->
          %{
            "id" => p.id,
            "name" => p.name,
            "arguments" => p.arguments,
            "malformed" => p.malformed && Atom.to_string(p.malformed)
          }
        end)
    }
  end

  defp finish({:other, raw}), do: %{"other" => raw}
  defp finish(finish), do: Atom.to_string(finish)

  defp refusal_view(reason, meta) do
    retry_after = if is_map(meta), do: Map.get(meta, :retry_after)
    %{"reason" => Atom.to_string(reason), "retry_after" => retry_after, "candidate" => nil}
  end

  defp hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp text?(s, max),
    do:
      is_binary(s) and byte_size(s) in 1..max and String.valid?(s) and
        not String.contains?(s, <<0>>)
end
