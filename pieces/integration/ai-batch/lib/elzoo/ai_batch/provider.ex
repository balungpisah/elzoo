# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Provider do
  @moduledoc """
  The behaviour a batch provider Piece implements.

  - `capabilities/0` returns `%{piece: catalogue_id, provider: text, wire_surface:
    text, item_provider: module, max_items: pos_integer, max_create_wire_bytes:
    pos_integer, options: %{key => validator}}`. `item_provider` is the
    `Elzoo.AiText.Provider` whose pure `translate/2` and `decode/2` give each item
    the meaning of the synchronous call; `max_items` and `max_create_wire_bytes`
    are the provider's documented caps; `options` declares the submission-level
    provider-options keys (strings) with a 1-arity validator returning `:ok`.
  - `prepare(submission, provider_config)` is pure: from
    `%{model, items: [%{item_id, request, wire}], provider_options}` (each `wire`
    is the item provider's translation) to `{:ok, %{body: binary, ...}}`, the exact
    bytes the provider will send, or `{:refused, :invalid_request |
    :unsupported_feature | :too_large}`. It never reads a credential.
  - `submit(wire, call_opts)` sends the prepared submission with
    `call_opts.credential` and returns `{:ok, %{provider_job_id, orphans}}` or
    `{:failure, tag, %{retry_after, orphans}}`.
  - `status(provider_job_id, call_opts)` and `cancel(provider_job_id, call_opts)`
    return `{:ok, job_state}` or `{:failure, tag, meta}`.
  - `results(provider_job_id, page_opts, call_opts)` reads one bounded page:
    `page_opts` is `%{cursor, page_size, max_line_bytes, max_scan_bytes}`; it
    returns `{:ok, %{lines: [{item_id, result}], done: boolean}}` where `result`
    is `{:succeeded, item_exchange}` (an exchange the item provider's `decode/2`
    accepts), `{:errored, :invalid_request | :provider_error}`, `:cancelled` or
    `:expired`, or `{:failure, tag, meta}`. Bytes read before the cursor count
    against `max_scan_bytes`.

  `tag` is one of `Elzoo.AiText.Outcome.provider_tags/0`, or for `results`
  also `:result_line_limit` or `:result_scan_limit`. Each call sends at most one
  HTTP request for a single-step provider; orphans are provider files a
  multi-step provider left behind (`%{kind: text, provider_ref: text}`).
  """
  @callback capabilities() :: map()
  @callback prepare(submission :: map(), provider_config :: term()) ::
              {:ok, map()} | {:refused, atom()}
  @callback submit(wire :: map(), call_opts :: map()) ::
              {:ok, map()} | {:failure, atom(), map()}
  @callback status(String.t(), map()) :: {:ok, term()} | {:failure, atom(), map()}
  @callback cancel(String.t(), map()) :: {:ok, term()} | {:failure, atom(), map()}
  @callback results(String.t(), map(), map()) :: {:ok, map()} | {:failure, atom(), map()}

  @doc false
  def valid_capabilities?(%{} = c) do
    is_binary(c[:piece]) and is_binary(c[:provider]) and is_binary(c[:wire_surface]) and
      is_atom(c[:item_provider]) and is_integer(c[:max_items]) and c.max_items > 0 and
      is_integer(c[:max_create_wire_bytes]) and c.max_create_wire_bytes > 0 and
      is_map(c[:options]) and
      Enum.all?(c.options, fn {k, v} -> is_binary(k) and is_function(v, 1) end)
  end

  def valid_capabilities?(_), do: false
end
