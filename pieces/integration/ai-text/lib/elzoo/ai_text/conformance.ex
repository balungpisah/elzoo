# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Conformance do
  @moduledoc """
  The provider conformance kit of the text interface: provider-neutral scenario
  data plus plain functions (no ExUnit macro, no test-only dependency), exported
  with the interface so every provider Piece, and every consumer that copies
  one, runs the same expectations.

  For each scenario a provider's own test supplies a stub response in the
  provider's documented format that realizes the scenario's `stub` meaning
  (the kit never sees provider formats, stub servers or fixtures), drives one
  call through `Elzoo.AiText` and the EffectIntent owner, and passes the
  delivery received by the sink and the number of HTTP requests the stub
  observed to `check/3`, which returns `:ok` or `{:error, scenario, reason}`.

  Stub meanings (`stub` field): `:text` (content `text/0`, a natural stop, full
  usage), `:length`, `:refusal`, `:other_finish` (a provider-specific stop
  reason outside the neutral set), `:tool_call` (one call of `lookup` with
  arguments `{"q": "x"}`), `:tool_invalid_json` (arguments that are not valid
  JSON or not an object), `:tool_schema_mismatch` (`{"q": 5}`),
  `:structured` (`{"answer": 42}`), `:structured_mismatch`
  (`{"answer": "forty-two"}`), `:no_usage` (a valid completion without a usage
  object), `:malformed_success` (a 2xx body without a response id or stop
  reason), `:timeout` (a transport timeout after the request was sent),
  `:throttled` (the provider's documented rate-limit status with a 7-second
  retry-after), `:overloaded` (its documented overload status) and
  `:server_error` (its documented internal-error status).
  """

  @text "Conformance reply."

  @lookup %{
    "name" => "lookup",
    "description" => "Look up a term.",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"q" => %{"type" => "string"}},
      "required" => ["q"],
      "additionalProperties" => false
    }
  }

  @answer_schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  @scenarios [
    %{id: :text_completion, stub: :text, extra: %{}},
    %{id: :finish_length, stub: :length, extra: %{}},
    %{id: :finish_refusal, stub: :refusal, extra: %{}},
    %{id: :finish_other, stub: :other_finish, extra: %{}},
    %{id: :tool_well_formed, stub: :tool_call, extra: %{"tools" => [@lookup]}},
    %{id: :tool_invalid_json, stub: :tool_invalid_json, extra: %{"tools" => [@lookup]}},
    %{id: :tool_schema_invalid, stub: :tool_schema_mismatch, extra: %{"tools" => [@lookup]}},
    %{id: :structured_valid, stub: :structured, extra: %{"output_schema" => @answer_schema}},
    %{
      id: :structured_invalid,
      stub: :structured_mismatch,
      extra: %{"output_schema" => @answer_schema}
    },
    %{id: :usage_omitted, stub: :no_usage, extra: %{}},
    %{id: :malformed_success, stub: :malformed_success, extra: %{}},
    %{id: :timeout_after_send, stub: :timeout, extra: %{}},
    %{id: :throttled, stub: :throttled, extra: %{}},
    %{id: :overloaded, stub: :overloaded, extra: %{}},
    %{id: :server_error, stub: :server_error, extra: %{}}
  ]

  def text, do: @text
  def scenarios, do: @scenarios
  def ids, do: Enum.map(@scenarios, & &1.id)

  def scenario(id), do: Enum.find(@scenarios, &(&1.id == id))

  @doc "The scenario's request object (the interface's request JSON) for `model`."
  def request(id, model) do
    %{extra: extra} = scenario(id)

    Map.merge(
      %{
        "version" => 1,
        "model" => model,
        "messages" => [
          %{"role" => "system", "text" => "Answer briefly."},
          %{"role" => "user", "text" => "Conformance prompt."}
        ],
        "max_output_tokens" => 256
      },
      extra
    )
  end

  @doc "A `core/effect` declaration carrying `request` for logical reference `ref`."
  def declaration(request, ref, deadline_unix_ms) do
    %{
      "capability_id" => "integration/ai-text",
      "operation" => "generate",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "msg-" <> ref,
        "schema_id" => "elzoo/ai-text-request",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "conformance", "port_id" => "out"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => deadline_unix_ms,
        "payload" => Elzoo.AiText.Request.canonical(request)
      }
    }
  end

  @doc """
  Checks the sink delivery (`{:outcome, attempt_id, outcome}`) and the number of
  HTTP requests the provider's stub observed for scenario `id`.
  """
  def check(id, delivery, requests) do
    cond do
      scenario(id) == nil -> {:error, id, :unknown_scenario}
      requests != 1 -> {:error, id, {:requests, requests}}
      true -> expect(id, outcome(delivery)) |> result(id)
    end
  end

  defp outcome({:outcome, _attempt, outcome}), do: outcome
  defp outcome(other), do: {:no_outcome, other}

  defp result(:ok, _), do: :ok
  defp result({:error, reason}, id), do: {:error, id, reason}

  defp expect(:text_completion, {:completed, c}) do
    with :ok <- is(c.content == @text, :content),
         :ok <- is(c.finish == :stop, :finish),
         :ok <- is(c.tool_proposals == [] and c.structured == nil, :extras),
         :ok <- is(c.usage.source == :provider_reported, :usage_source),
         :ok <- is(is_integer(Elzoo.AiModel.Usage.amount(c.usage, :output_tokens)), :usage) do
      is(is_binary(c.provenance.response_id), :provenance)
    end
  end

  defp expect(:finish_length, {:completed, c}), do: is(c.finish == :length, :finish)
  defp expect(:finish_refusal, {:completed, c}), do: is(c.finish == :refusal, :finish)
  defp expect(:finish_other, {:completed, c}), do: is(match?({:other, _}, c.finish), :finish)

  defp expect(:tool_well_formed, {:completed, c}) do
    with :ok <- is(c.finish == :tool_calls, :finish) do
      case c.tool_proposals do
        [%{name: "lookup", arguments: %{"q" => "x"}, malformed: nil}] -> :ok
        _ -> {:error, :proposal}
      end
    end
  end

  defp expect(:tool_invalid_json, {:completed, c}) do
    case c.tool_proposals do
      [%{name: "lookup", arguments: nil, malformed: m}] when m in [:invalid_json, :not_an_object] ->
        :ok

      _ ->
        {:error, :proposal}
    end
  end

  defp expect(:tool_schema_invalid, {:completed, c}) do
    case c.tool_proposals do
      [%{name: "lookup", arguments: nil, malformed: :schema_mismatch}] -> :ok
      _ -> {:error, :proposal}
    end
  end

  defp expect(:structured_valid, {:completed, c}),
    do: is(c.structured == {:valid, %{"answer" => 42}}, :structured)

  defp expect(:structured_invalid, {:completed, c}),
    do: is(c.structured == {:invalid, :schema_mismatch}, :structured)

  defp expect(:usage_omitted, {:completed, c}) do
    with :ok <- is(c.usage.source == :unknown, :usage_source) do
      is(Elzoo.AiModel.Usage.amount(c.usage, :output_tokens) == :unknown, :usage)
    end
  end

  defp expect(:malformed_success, o), do: is(o == {:unknown, :malformed_response}, :outcome)
  defp expect(:timeout_after_send, o), do: is(o == {:unknown, :timeout}, :outcome)

  defp expect(:throttled, o),
    do: is(o == {:refused, :throttled, %{retry_after: 7}}, :outcome)

  defp expect(:overloaded, o), do: is(match?({:refused, :overloaded, _}, o), :outcome)
  defp expect(:server_error, o), do: is(o == {:unknown, :provider_error}, :outcome)
  defp expect(_, _), do: {:error, :outcome}

  defp is(true, _), do: :ok
  defp is(_, reason), do: {:error, reason}
end
