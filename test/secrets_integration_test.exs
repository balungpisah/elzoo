# SPDX-License-Identifier: Apache-2.0
Code.require_file(
  "../pieces/integration/ai-text/test/support/ai_text_test_helper.exs",
  __DIR__
)

defmodule Elzoo.SecretsIntegrationTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Elzoo.{AiText, Secrets}
  alias Elzoo.AiText.{Adapter, Binding, Conformance, Sink, TestBinding, TestHelper, TestProvider}

  @request %{ref: "anthropic-key", scope: "tenant-a/anthropic/text"}
  @key "sk-synthetic-SECRET-integration-105"

  defp config(value, grant \\ @request) do
    parent = self()

    need = fn ->
      context = %{
        grant: grant,
        resolver: fn ref, scope ->
          {:ok, %{ref: ref, scope: scope, value: value, version: 1, expires_at_unix_ms: 200}}
        end,
        clock: fn -> 100 end
      }

      case Secrets.resolve(@request, context) do
        {:ok, credential} ->
          send(parent, :resolved)
          {:ok, Secrets.reveal(credential)}

        {:error, _} ->
          {:error, :credentials_unavailable}
      end
    end

    AiText.configure(
      binding: TestBinding,
      tenant: "tenant-a",
      provider: TestProvider,
      provider_config: %{
        parent: parent,
        respond: fn request ->
          send(parent, {:model_request, request})
          {:ok, {:raw, TestHelper.raw()}}
        end
      },
      credentials: need,
      models: ["test-model"],
      sink: Sink.to_pid(parent)
    )
  end

  # Exercise the accepted public admission and Adapter boundary, without
  # starting or modifying a storage/intent owner or making a network call.
  defp send_text(c) do
    declaration =
      Conformance.declaration(
        Conformance.request(:text_completion, "test-model"),
        "secrets-105",
        10_000
      )

    {:ok, admission} = AiText.admission(c, declaration)
    {:ok, binding} = Binding.load(c.binding)
    refute_received :resolved

    {admission.key,
     Adapter.send_effect(%{
       context: c,
       key: admission.key,
       attempt_id: "attempt-105",
       binding: binding.digest,
       arguments: admission.arguments
     })}
  end

  test "a scoped binary passes the unchanged text Need and reaches only the scripted provider" do
    log =
      capture_log(fn ->
        {:ok, c} = config(@key)
        {key, envelope} = send_text(c)
        assert envelope["outcome"] == "completed"
        assert_received :resolved
        assert_received {:call, @key, 120_000}
        assert_received {:model_request, request}
        assert_received {AiText, ^key, {:outcome, "attempt-105", {:completed, body}}}
        assert body.content == "hello"
        refute inspect({c, request, envelope, body}) =~ @key
      end)

    refute log =~ @key
  end

  test "resolver success outside text's narrower key contract and scope denial preserve no-send refusal" do
    for {value, grant, resolved?} <- [
          {String.duplicate("x", 1025), @request, true},
          {"key with whitespace", @request, true},
          {@key, %{@request | scope: "tenant-b/anthropic/text"}, false}
        ] do
      {:ok, c} = config(value, grant)
      {key, result} = send_text(c)
      assert result == {:error, :credentials_unavailable, :ai_text}

      assert_received {AiText, ^key,
                       {:outcome, "attempt-105",
                        {:refused, :credentials_unavailable, %{retry_after: nil}}}}

      if resolved?, do: assert_received(:resolved), else: refute_received(:resolved)
      refute_received {:call, _, _}
      refute_received {:model_request, _}
      refute inspect(result) =~ @key
    end
  end
end
