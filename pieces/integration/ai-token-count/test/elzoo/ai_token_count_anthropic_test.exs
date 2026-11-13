# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiTokenCount.AnthropicTest do
  # The fixtures are Monitored observations, recorded through OpenRouter's
  # Anthropic-compatible endpoint, routed to Anthropic (see PROVENANCE.md beside
  # them). No test here calls the network: group 3 captures the adapter's body
  # through its :plug test transport.
  use ExUnit.Case, async: true

  alias Elzoo.AiText.{Anthropic, Request}
  alias Elzoo.AiTokenCount.Anthropic, as: Estimator

  @fixtures Path.expand("../fixtures/openrouter-anthropic", __DIR__)
  @names ~w(short system tools tools_any tool_turn prose dense symbols non_latin expanding
            many_messages many_tools adv_ascii_caps_punct adv_rare_punct adv_upper_rare_punct)

  @keys [
    :size,
    :unit,
    :direction,
    :provider_id,
    :model_id,
    :estimator_id,
    :estimator_version
  ]

  # This Piece's manifest and README: two levels above this file in the
  # repository; under .elzoo/pieces/integration/ai-token-count/ in an exported
  # consumer. Exactly one of each must exist, so a missing file is never skipped.
  @manifests [
    Path.expand("../../piece.json", __DIR__),
    Path.expand("../../.elzoo/pieces/integration/ai-token-count/piece.json", __DIR__)
  ]
  @readmes [
    Path.expand("../../../../../pieces/integration/ai-token-count/README.md", __DIR__),
    Path.expand("../../.elzoo/pieces/integration/ai-token-count/README.md", __DIR__)
  ]

  defp fixture(name, part), do: File.read!(Path.join(@fixtures, "#{name}.#{part}.json"))

  # input_tokens + cache_read_input_tokens + cache_creation_input_tokens, or nil
  # when the recorded usage lacks one of the three fields.
  defp reported(name) do
    usage = Jason.decode!(fixture(name, "response"))["usage"] || %{}
    fields = ~w(input_tokens cache_read_input_tokens cache_creation_input_tokens)

    if Enum.all?(fields, &is_integer(usage[&1])),
      do: Enum.sum(Enum.map(fields, &usage[&1])),
      else: nil
  end

  defp size!(payload) do
    assert {:ok, %{size: size}} = Estimator.estimate(payload)
    size
  end

  defp canonical_bytes(name) do
    {:ok, _, canonical} = Request.decode(fixture(name, "request"))
    byte_size(canonical)
  end

  defp ratio(size, reported), do: :erlang.float_to_binary(size / reported, decimals: 2)

  defp one!(paths) do
    assert [path] = Enum.filter(paths, &File.regular?/1)
    path
  end

  defp request(extra) do
    Map.merge(
      %{
        "version" => 1,
        "model" => "claude-haiku-5-5",
        "max_output_tokens" => 16,
        "messages" => [%{"role" => "user", "text" => "What is the capital of France?"}]
      },
      extra
    )
  end

  defp tool(name),
    do: %{
      "name" => name,
      "description" => "Look up one #{name}.",
      "input_schema" => %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
    }

  describe "fixtures_upper_bound" do
    test "for each of the fifteen fixtures, size is at least the reported prompt input" do
      used = for name <- @names, (r = reported(name)) != nil, do: {name, r}
      assert Enum.map(used, &elem(&1, 0)) == @names

      below =
        for {name, r} <- used,
            (size = size!(fixture(name, "request"))) < r,
            do: "#{name}: size #{size} is below the reported #{r}"

      assert below == []
    end
  end

  describe "observed_error_stated" do
    test "the README states each fixture's reported value, size and ratio, the extremes and the provenance" do
      text = File.read!(one!(@readmes))

      rows =
        for name <- @names do
          r = reported(name)
          s = size!(fixture(name, "request"))
          c = canonical_bytes(name)
          row = "| `#{name}` | #{c} | #{r} | #{s} | #{ratio(s, r)} |"
          assert String.contains?(text, row), "README lacks the row #{row}"
          {name, s / r, ratio(s, r)}
        end

      {min_name, _, min} = Enum.min_by(rows, &elem(&1, 1))
      {max_name, _, max} = Enum.max_by(rows, &elem(&1, 1))

      assert text =~
               "The smallest ratio is #{min} (`#{min_name}`) and the largest is #{max} (`#{max_name}`)."

      assert text =~
               "recorded through OpenRouter's Anthropic-compatible endpoint, routed to Anthropic"

      refute text =~ ~r/recorded from\s+Anthropic(?!'s own endpoint)/
    end
  end

  describe "fixture_matches_adapter" do
    test "the body that integration/ai-text-anthropic sends equals each upstream fixture without provider" do
      test = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)
        send(test, {:sent, body})
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      for name <- @names do
        {:ok, request, _} = Request.decode(fixture(name, "request"))
        assert {:ok, translated} = Anthropic.translate(request, %{plug: plug})

        assert {:ok, %{status: 200}} =
                 Anthropic.call(translated, %{credential: "stub-key", receive_timeout_ms: 5000})

        assert_received {:sent, body}
        refute_received {:sent, _}

        upstream = Jason.decode!(fixture(name, "upstream"))
        assert Map.has_key?(upstream, "provider")
        assert Jason.decode!(body) == Map.delete(upstream, "provider"), name
      end
    end
  end

  describe "unknown_model_refused" do
    test "an unknown Anthropic model and another provider's model are refused; an alias is accepted" do
      for model <- ["claude-no-such-model-9", "gpt-4o-mini", "anthropic:claude-haiku-5-5"] do
        payload = Jason.encode!(request(%{"model" => model}))
        assert Estimator.estimate(payload) == {:refused, :unknown_model}, model
      end

      # llm_db resolves the alias to its dated model; model_id stays the request's text.
      assert {:ok, %{id: "claude-sonnet-4-5-20250929"}} =
               LLMDB.model(:anthropic, "claude-sonnet-4-5")

      payload = Jason.encode!(request(%{"model" => "claude-sonnet-4-5"}))
      assert {:ok, %{model_id: "claude-sonnet-4-5"}} = Estimator.estimate(payload)
    end
  end

  describe "tools_and_system_counted" do
    test "tools add three times their canonical bytes, and the first tool also adds 1,024 once" do
      canonical = fn map ->
        {:ok, _, c} = Request.decode(Jason.encode!(map))
        byte_size(c)
      end

      none = request(%{})
      one = request(%{"tools" => [tool("part")]})
      two = request(%{"tools" => [tool("part"), tool("stock")]})

      [s0, s1, s2] = Enum.map([none, one, two], &size!(Jason.encode!(&1)))
      [c0, c1, c2] = Enum.map([none, one, two], canonical)

      assert s1 - s0 == 3 * (c1 - c0) + 1_024
      assert s2 - s1 == 3 * (c2 - c1)
    end

    test "one more system message raises size by at least three times the bytes of its text" do
      text = "You answer in one word."
      base = request(%{})

      more =
        request(%{
          "messages" => [%{"role" => "system", "text" => text} | base["messages"]]
        })

      assert size!(Jason.encode!(more)) - size!(Jason.encode!(base)) >= 3 * byte_size(text)
    end

    test "two payloads that differ only in key order and whitespace give the same result" do
      compact = fixture("tools", "request") |> Jason.decode!() |> Jason.encode!()

      reordered =
        ~s({ "tool_choice" : {"type":"auto"},\n\t"max_output_tokens": 16, "model":"claude-haiku-5-5", ) <>
          ~s("tools": ) <>
          Jason.encode!(Jason.decode!(fixture("tools", "request"))["tools"], pretty: true) <>
          ~s(, "messages": [ {"text": "Do you have any brass hinges in the north warehouse?", "role": "user"} ],) <>
          ~s( "version": 1 })

      assert Estimator.estimate(compact) == Estimator.estimate(reordered)
      assert Estimator.estimate(compact) == Estimator.estimate(fixture("tools", "request"))
    end
  end

  describe "never_exact" do
    test "each result has exactly the seven keys and says upper_bound; only estimate/1 is exported" do
      for name <- @names do
        assert {:ok, result} = Estimator.estimate(fixture(name, "request"))
        assert Enum.sort(Map.keys(result)) == Enum.sort(@keys)
        assert result.direction == :upper_bound
        assert result.unit == :tokens
        assert result.provider_id == "anthropic"
        assert result.estimator_id == "elzoo/ai-token-count/anthropic-bytes"
        assert result.estimator_version == 1
        assert result.size >= 1
      end

      assert Estimator.__info__(:functions) == [estimate: 1]
    end

    test "each refusal is reached and carries no number" do
      cases = [
        {:invalid_request, "{not json"},
        {:invalid_request, Jason.encode!(Map.delete(request(%{}), "model"))},
        {:invalid_request, 42},
        {:too_large, Jason.encode!(request(%{"pad" => String.duplicate("x", 65_536)}))},
        {:unsupported_feature,
         Jason.encode!(request(%{"messages" => [%{"role" => "user", "image" => "x"}]}))},
        {:unsupported_feature, Jason.encode!(request(%{"output_schema" => %{"type" => "object"}}))},
        {:unknown_model, Jason.encode!(request(%{"model" => "claude-no-such-model-9"}))},
        {:unknown_model, Jason.encode!(request(%{"model" => "x@y:z"}))}
      ]

      for {reason, payload} <- cases do
        assert Estimator.estimate(payload) == {:refused, reason}
      end
    end

    test "the README and the manifest call the value an upper bound, never a count" do
      manifest = Jason.decode!(File.read!(one!(@manifests)))
      readme = File.read!(one!(@readmes))

      assert manifest["contract"] =~ "upper bound"
      assert readme =~ "upper bound"

      for text <- [readme, Jason.encode!(manifest)] do
        # "token count" appears only as a denial.
        for [before] <- Regex.scan(~r/(.{0,6})token count/i, text, capture: :all_but_first) do
          assert before =~ ~r/not a $/i, "\"token count\" outside a denial: #{before}"
        end
      end
    end
  end

  describe "no_network" do
    test "this Piece's own lib files hold no HTTP client, socket, ReqLLM, environment read or process start" do
      manifest = Jason.decode!(File.read!(one!(@manifests)))
      root = Path.dirname(one!(@manifests))
      lib = for f <- manifest["files"], String.starts_with?(f, "lib/"), do: f
      assert lib == ["lib/elzoo/ai_token_count/anthropic.ex"]

      forbidden =
        ~r/(\b(Req\.|ReqLLM|Finch|Mint\.|HTTPoison|Tesla|Plug\.|System\.(get_env|fetch_env)|Application\.(get_env|fetch_env|get_all_env)|spawn|Task\.|GenServer|Agent\.|Process\.|Port\.|File\.write)|:(httpc|gen_tcp|gen_udp|ssl|socket|ets)\b)/

      for f <- lib do
        source = File.read!(Path.join(root, f))
        refute source =~ forbidden, "#{f}: #{inspect(Regex.run(forbidden, source))}"
      end

      http = ~w(req req_llm finch mint httpoison tesla hackney gun websockex server_sent_events)
      assert Enum.filter(manifest["providers"], &(&1 in http)) == []
    end
  end
end
