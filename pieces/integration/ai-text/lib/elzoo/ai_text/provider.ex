# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Provider do
  @moduledoc """
  The behaviour a text-model provider Piece implements.

  - `capabilities/0` returns `%{piece: catalogue_id, provider: text,
    wire_surface: text, features: [feature], reasoning: [level], cache_ttls:
    [ttl], convention: %{input_includes_cached: boolean}, options: %{key =>
    validator}}`. Features are drawn from `:tools`, `:structured_output`,
    `:sampling`, `:stop_sequences`, `:cache_hint`, `:reasoning`; a request that
    uses an undeclared feature is refused `:unsupported_feature` before any
    credential is read. `options` declares the provider-options keys (strings)
    with a 1-arity validator returning `:ok`; any other key, or a failing value,
    is refused `:invalid_request` (never ignored).
  - `translate(request, provider_config)` is pure: the neutral request to the
    provider's wire request, or `{:refused, :invalid_request |
    :unsupported_feature | :too_large}`. It never reads a credential.
  - `call(wire, call_opts)` performs **exactly one** HTTP exchange with the
    injected credential `call_opts.credential` and returns `{:ok, exchange}` or
    `{:transport, :timeout | :closed | :other}`. No retry, no redirect.
  - `decode(exchange, request)` turns a successful exchange into
    `{:ok, %{content, tool_calls, structured, finish, usage, response_id,
    request_id, provider_model}}` or `{:failure, tag}`.
  - `classify_failure(exchange_or_transport)` returns one of
    `Elzoo.AiText.Outcome.provider_tags/0`.

  Tool calls are data: the provider never executes, resolves or loads a tool.
  """
  @callback capabilities() :: map()
  @callback translate(request :: map(), provider_config :: term()) ::
              {:ok, term()} | {:refused, atom()}
  @callback call(wire :: term(), call_opts :: map()) :: {:ok, term()} | {:transport, atom()}
  @callback decode(exchange :: term(), request :: map()) :: {:ok, map()} | {:failure, atom()}
  @callback classify_failure(term()) :: atom()

  @features [:tools, :structured_output, :sampling, :stop_sequences, :cache_hint, :reasoning]
  def features, do: @features

  @doc false
  def valid_capabilities?(%{} = c) do
    is_binary(c[:piece]) and is_binary(c[:provider]) and is_binary(c[:wire_surface]) and
      is_list(c[:features]) and Enum.all?(c.features, &(&1 in @features)) and
      is_list(c[:reasoning]) and is_list(c[:cache_ttls]) and
      match?(%{input_includes_cached: b} when is_boolean(b), c[:convention]) and
      is_map(c[:options]) and
      Enum.all?(c.options, fn {k, v} -> is_binary(k) and is_function(v, 1) end)
  end

  def valid_capabilities?(_), do: false
end
