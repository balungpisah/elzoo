# SPDX-License-Identifier: Apache-2.0
# Test providers and bindings for the integration/ai-batch tests. The item
# provider is a scripted integration/ai-text provider; the batch provider is
# scripted through its provider_config: `parent` receives one message per
# provider call and `respond` returns the answer for an operation.
defmodule Elzoo.AiBatch.TestItemProvider do
  @behaviour Elzoo.AiText.Provider

  @impl true
  def capabilities do
    %{
      piece: "test/ai-text-item-provider",
      provider: "test",
      wire_surface: "scripted",
      features: [:tools, :structured_output, :stop_sequences, :cache_hint],
      reasoning: [],
      cache_ttls: ["5m"],
      convention: %{input_includes_cached: false},
      options: %{}
    }
  end

  @impl true
  def translate(%{messages: messages} = request, cfg) do
    if Enum.any?(messages, &(&1[:text] == "refuse-in-translate")),
      do: {:refused, :unsupported_feature},
      else: {:ok, %{model: request.model, messages: Enum.map(messages, & &1.text), cfg: cfg}}
  end

  # Used only by the synchronous side of the completion equality corpus; the
  # batch interface never calls it.
  @impl true
  def call(%{cfg: %{respond: respond}}, _opts), do: respond.()
  def call(_wire, _opts), do: {:transport, :other}

  @impl true
  def decode({:raw, raw}, _request), do: {:ok, raw}
  def decode(_, _), do: {:failure, :malformed_response}

  @impl true
  def classify_failure(_), do: :transport
end

defmodule Elzoo.AiBatch.TestProvider do
  @behaviour Elzoo.AiBatch.Provider

  @impl true
  def capabilities do
    %{
      piece: "test/ai-batch-provider",
      provider: "test",
      wire_surface: "scripted-batches",
      item_provider: Elzoo.AiBatch.TestItemProvider,
      max_items: 10,
      max_create_wire_bytes: 100_000,
      options: %{"priority" => fn v -> if v in ["low", "high"], do: :ok, else: :error end}
    }
  end

  # The create body: a fixed wrapper around the items' ids and translations, so
  # its size is exactly predictable in the bound tests.
  @impl true
  def prepare(%{items: items}, cfg) do
    send(cfg.parent, {:prepare, length(items)})
    pad = Map.get(cfg, :pad, 0)

    body =
      Jason.encode!(%{
        "pad" => String.duplicate("x", pad),
        "requests" => Enum.map(items, &%{"id" => &1.item_id, "messages" => &1.wire.messages})
      })

    {:ok, %{body: body}}
  end

  @impl true
  def submit(wire, opts), do: call(:submit, wire, opts)
  @impl true
  def status(id, opts), do: call(:status, id, opts)
  @impl true
  def cancel(id, opts), do: call(:cancel, id, opts)
  @impl true
  def results(id, page, opts), do: call(:results, {id, page}, opts)

  defp call(op, arg, %{provider_config: cfg} = opts) do
    send(cfg.parent, {:call, op, opts.credential})
    cfg.respond.(op, arg)
  end
end

defmodule Elzoo.AiBatch.TestSubmitBinding do
  use Elzoo.AiBatch.Binding,
    operation: :submit,
    id: "ai-batch-test-submit",
    provider_account: "test:account",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiBatch.TestCancelBinding do
  use Elzoo.AiBatch.Binding,
    operation: :cancel,
    id: "ai-batch-test-cancel",
    provider_account: "test:account",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiBatch.TestTextBinding do
  use Elzoo.AiText.Binding,
    id: "ai-batch-test-sync",
    provider_account: "test:account",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiBatch.TestHelper do
  alias Elzoo.AiModel.Usage

  def usage(output \\ 3) do
    {:ok, usage} =
      Usage.from_provider(
        %{input: 10, cache_read: 0, cache_writes: [], output: output},
        %{input_includes_cached: false},
        :provider_reported
      )

    usage
  end

  def raw(content \\ "hello", extra \\ %{}) do
    Map.merge(
      %{
        response_id: "resp_1",
        request_id: "req_1",
        provider_model: "test-model-2026",
        content: content,
        tool_calls: [],
        structured_json: nil,
        finish: :stop,
        usage: usage()
      },
      extra
    )
  end
end
