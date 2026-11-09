# SPDX-License-Identifier: Apache-2.0
# Test provider and binding for the integration/ai-text tests. The provider is
# scripted through its provider_config: `parent` receives one message per
# translate and per call, and `respond` returns the exchange for a request.
defmodule Elzoo.AiText.TestProvider do
  @behaviour Elzoo.AiText.Provider

  @impl true
  def capabilities do
    %{
      piece: "test/ai-text-provider",
      provider: "test",
      wire_surface: "scripted",
      features: [:tools, :structured_output, :sampling, :stop_sequences, :cache_hint, :reasoning],
      reasoning: [:low, :high],
      cache_ttls: ["5m"],
      convention: %{input_includes_cached: false},
      options: %{"flavour" => fn v -> if v in ["plain", "terse"], do: :ok, else: :error end}
    }
  end

  @impl true
  def translate(request, %{parent: parent} = cfg) do
    send(parent, {:translate, request.provider_options})

    if request.provider_options["flavour"] == "terse" and request.tools != [],
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

defmodule Elzoo.AiText.TestProviderNoSampling do
  @behaviour Elzoo.AiText.Provider
  alias Elzoo.AiText.TestProvider

  @impl true
  def capabilities,
    do: %{TestProvider.capabilities() | features: [:tools, :structured_output, :stop_sequences]}

  @impl true
  defdelegate translate(r, c), to: TestProvider
  @impl true
  defdelegate call(w, o), to: TestProvider
  @impl true
  defdelegate decode(e, r), to: TestProvider
  @impl true
  defdelegate classify_failure(t), to: TestProvider
end

defmodule Elzoo.AiText.TestBinding do
  use Elzoo.AiText.Binding,
    id: "ai-text-test",
    provider_account: "test:account",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiText.TestHelper do
  alias Elzoo.AiModel.Usage

  def raw(content \\ "hello", extra \\ %{}) do
    {:ok, usage} =
      Usage.from_provider(
        %{input: 10, cache_read: 0, cache_writes: [], output: 3},
        %{input_includes_cached: false},
        :provider_reported
      )

    Map.merge(
      %{
        response_id: "resp_1",
        request_id: "req_1",
        provider_model: "test-model-2026",
        content: content,
        tool_calls: [],
        structured_json: nil,
        finish: :stop,
        usage: usage
      },
      extra
    )
  end
end
