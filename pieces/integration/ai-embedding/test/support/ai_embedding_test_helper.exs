# SPDX-License-Identifier: Apache-2.0
# Test provider and binding for the integration/ai-embedding tests. The provider is
# scripted through its provider_config: `parent` receives one message per translate
# and per call, and `respond` returns the exchange for a request.
defmodule Elzoo.AiEmbedding.TestProvider do
  @behaviour Elzoo.AiEmbedding.Provider

  @impl true
  def capabilities do
    %{
      piece: "test/ai-embedding-provider",
      provider: "test",
      wire_surface: "scripted",
      models: %{
        "test-embed" => %{native: 4, min: 2, max: 4},
        "test-fixed" => %{native: 3, min: 3, max: 3}
      },
      input_types: [:unspecified, :query],
      max_inputs: 2048,
      convention: %{input_includes_cached: false},
      options: %{"flavour" => fn v -> if v in ["plain", "terse"], do: :ok, else: :error end}
    }
  end

  @impl true
  def translate(request, %{parent: parent} = cfg) do
    send(parent, {:translate, request.provider_options})

    if request.provider_options["flavour"] == "terse" and length(request.inputs) > 2,
      do: {:refused, :unsupported_feature},
      else: {:ok, %{request: request, cfg: cfg}}
  end

  @impl true
  def call(%{request: request, cfg: cfg}, opts) do
    send(cfg.parent, {:call, opts.credential, opts.receive_timeout_ms})
    cfg.respond.(request)
  end

  @impl true
  def decode({:status, tag}, _), do: {:failure, tag}
  def decode({:status, tag, meta}, _), do: {:failure, tag, meta}
  def decode({:raw, raw}, _), do: {:ok, raw}

  @impl true
  def classify_failure({:transport, :timeout}), do: :timeout
  def classify_failure(_), do: :transport
end

defmodule Elzoo.AiEmbedding.TestBinding do
  use Elzoo.AiEmbedding.Binding,
    id: "ai-embedding-test",
    provider_account: "test:account",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiEmbedding.TestHelper do
  alias Elzoo.AiModel.Usage

  def usage do
    {:ok, usage} =
      Usage.from_provider(
        %{
          input: 12,
          cache_read: :unknown,
          cache_writes: [%{ttl: "provider_default", amount: :unknown}],
          output: :unknown
        },
        %{input_includes_cached: false},
        :provider_reported
      )

    usage
  end

  @doc "A decoded provider response listing `items` (each `%{index, vector}`) for `model`."
  def raw(items, model \\ "test-embed", extra \\ %{}) do
    Map.merge(
      %{items: items, provider_model: model, usage: usage(), request_id: "req_1"},
      extra
    )
  end

  @doc "Neutral items realizing a conformance stub meaning, as a scripted exchange."
  def respond(stub, model) do
    case stub do
      {:items, items} ->
        {:ok, {:raw, raw(items, model)}}

      {:items_no_usage, items} ->
        {:ok, {:raw, raw(items, model, %{usage: Usage.unknown(%{input_includes_cached: false})})}}

      {:items_other_model, items} ->
        {:ok, {:raw, raw(items, model <> "-v2")}}

      :malformed_success ->
        {:ok, {:raw, %{items: :not_a_list}}}

      :timeout ->
        {:transport, :timeout}

      :throttled ->
        {:ok, {:status, :throttled, %{retry_after: 7}}}

      :overloaded ->
        {:ok, {:status, :overloaded}}

      :server_error ->
        {:ok, {:status, :provider_error}}
    end
  end
end
