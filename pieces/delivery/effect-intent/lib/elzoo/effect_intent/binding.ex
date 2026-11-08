# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EffectIntent.Binding do
  @moduledoc """
  Build-time exhaustive Adapter descriptor. Adapter callbacks are trusted effects,
  schemas and attestations, never locally proved provider behaviour.
  """
  @max 9_223_372_036_854_775_807
  @callbacks [
    failure_tags: 0,
    schema: 0,
    validate: 2,
    send_effect: 1,
    poll: 1,
    authenticate: 2,
    validate_result: 2
  ]
  defmacro __using__(options) do
    quote do
      @effect_intent_options unquote(options)
      @before_compile Elzoo.EffectIntent.Binding
    end
  end

  defmacro __before_compile__(env) do
    descriptor = compile!(Module.get_attribute(env.module, :effect_intent_options))

    quote do
      def __effect_intent_binding__, do: unquote(Macro.escape(descriptor))
    end
  end

  def compile!(options) do
    opts = Map.new(options)
    adapter = Map.fetch!(opts, :adapter)
    Code.ensure_compiled!(adapter)
    true = Enum.all?(@callbacks, fn {f, a} -> function_exported?(adapter, f, a) end)
    tags = adapter.failure_tags()
    true = is_list(tags) and Enum.all?(tags, &is_atom/1) and length(tags) == length(Enum.uniq(tags))
    mapping = Map.fetch!(opts, :failures)
    true = is_map(mapping) and Enum.sort(Map.keys(mapping)) == Enum.sort(tags)

    Enum.each(mapping, fn {_tag, {outcome, dispatch, error}} ->
      # Static form of the ready failure matrix; no dependency on Cure BEAMs
      # being loaded while a copied consumer compiles its binding module.
      true =
        {outcome, dispatch} in [
          {"rejected", "not_dispatched"},
          {"failed", "dispatched"},
          {"timed_out", "not_dispatched"},
          {"timed_out", "dispatched"},
          {"timed_out", "unknown"},
          {"unknown", "dispatched"},
          {"unknown", "unknown"}
        ]

      true = error in ["retryable", "permanent", "unavailable", "unclassified"]
    end)

    # Every not_dispatched variant explicitly attests that no bytes reached transport.
    attest = Map.get(opts, :no_send_attestations, [])
    required = for {tag, {_, "not_dispatched", _}} <- mapping, do: tag
    true = Enum.sort(attest) == Enum.sort(required)
    for key <- [:id, :provider_account, :operation, :clock], do: true = text?(Map.fetch!(opts, key))
    grace = Map.get(opts, :recovery_grace_ms, :none)
    true = grace == :none or uint?(grace)
    replay = Map.get(opts, :replay, :none)
    true = valid_replay?(replay)
    revision = Map.get(opts, :revision, :forbidden)
    true = revision in [:forbidden, :same_key_changed_arguments]

    descriptor =
      Map.take(opts, [
        :adapter,
        :id,
        :provider_account,
        :operation,
        :clock,
        :failures,
        :no_send_attestations
      ])
      |> Map.merge(%{recovery_grace_ms: grace, replay: replay, revision: revision})

    Map.put(
      descriptor,
      :digest,
      :crypto.hash(:sha256, :erlang.term_to_binary(descriptor, [:deterministic]))
    )
  rescue
    _ ->
      raise ArgumentError,
            "invalid effect-intent binding: callbacks, failure mapping or declared capability"
  end

  def load(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__effect_intent_binding__, 0),
         descriptor <- module.__effect_intent_binding__(),
         verified <- compile!(Map.delete(descriptor, :digest)),
         true <- verified == descriptor do
      {:ok, descriptor}
    else
      _ -> {:error, :binding}
    end
  rescue
    _ -> {:error, :binding}
  end

  def load(_), do: {:error, :binding}

  def text?(s),
    do:
      is_binary(s) and String.valid?(s) and byte_size(s) in 1..256 and
        not String.contains?(s, <<0>>)

  def uint?(n), do: is_integer(n) and n >= 0 and n <= @max

  def recovery_deadline(deadline, :none) do
    if uint?(deadline), do: {:ok, :NoRecovery}, else: {:error, :deadline}
  end

  def recovery_deadline(deadline, grace) do
    if uint?(deadline) and uint?(grace) and grace <= @max - deadline,
      do: {:ok, {:RecoveryAt, deadline + grace}},
      else: {:error, :deadline_overflow}
  end

  defp valid_replay?(:none), do: true

  defp valid_replay?(
         %{
           window_ms: w,
           max_flight_ms: f,
           clock_allowance_ms: c,
           semantics: :same_key_same_arguments
         } = r
       ),
       do: map_size(r) == 4 and uint?(w) and uint?(f) and uint?(c) and f + c <= w
end
