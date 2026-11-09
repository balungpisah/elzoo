# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModelTest do
  use ExUnit.Case, async: true

  alias Elzoo.AiModel.{CacheHint, Failure, Job, ModelRef, Provenance, StreamChunk, Usage}

  @anthropic %{input_includes_cached: false}
  @openai %{input_includes_cached: true}

  # M2: documented usage examples (fetched 2026-11-09).
  # Anthropic, "Prompt caching" > "1-hour cache duration", response usage example:
  # input_tokens 2048, cache_read_input_tokens 1800, cache_creation_input_tokens 248,
  # output_tokens 503, cache_creation {ephemeral_5m_input_tokens 148, ephemeral_1h_input_tokens 100}.
  # The page states total_input_tokens = cache_read_input_tokens + cache_creation_input_tokens + input_tokens.
  @anthropic_example %{
    input: 2048,
    cache_read: 1800,
    cache_writes: [%{ttl: "5m", amount: 148}, %{ttl: "1h", amount: 100}],
    output: 503
  }
  # OpenAI, "Prompt caching" > "Monitor cache performance", input usage example:
  # input_tokens 12000, cached_tokens 4000, cache_write_tokens 7000 with
  # ttl_30m_tokens 3000 and ttl_12h_tokens 4000; "1,000 input tokens are ordinary input".
  @openai_example %{
    input: 12_000,
    cache_read: 4000,
    cache_writes: [%{ttl: "30m", amount: 3000}, %{ttl: "12h", amount: 4000}]
  }

  describe "M2 accounting identity" do
    test "Anthropic documented example: input excludes cache reads and writes" do
      {:ok, u} = Usage.from_provider(@anthropic_example, @anthropic, :provider_reported)
      assert Usage.amount(u, :input_uncached_tokens) == 2048
      assert Usage.amount(u, :cache_read_tokens) == 1800
      assert Usage.sum(u.cache_writes) == 248
      assert Usage.amount(u, :output_tokens) == 503
      assert Usage.prompt_input_tokens(u) == 1800 + 248 + 2048
    end

    test "OpenAI documented example: input includes cache reads and writes" do
      {:ok, u} = Usage.from_provider(@openai_example, @openai, :provider_reported)
      assert Usage.amount(u, :input_uncached_tokens) == 1000
      assert Usage.prompt_input_tokens(u) == 12_000
      assert Usage.amount(u, :output_tokens) == :unknown
    end

    test "the same raw counters under the two conventions are not added the same way" do
      {:ok, a} = Usage.from_provider(@openai_example, @anthropic, :provider_reported)
      {:ok, o} = Usage.from_provider(@openai_example, @openai, :provider_reported)
      assert Usage.prompt_input_tokens(a) == 12_000 + 4000 + 7000
      assert Usage.prompt_input_tokens(o) == 12_000
    end

    test "each missing component is :unknown, and so is the derived total, never zero" do
      for {missing, conv} <- [
            {:input, @anthropic},
            {:input, @openai},
            {:cache_read, @anthropic},
            {:cache_read, @openai}
          ] do
        raw = Map.put(@openai_example, missing, :unknown)
        {:ok, u} = Usage.from_provider(raw, conv, :provider_reported)
        assert Usage.prompt_input_tokens(u) == :unknown, inspect({missing, conv})
      end

      raw = %{@openai_example | cache_writes: [%{ttl: "provider_default", amount: :unknown}]}
      {:ok, o} = Usage.from_provider(raw, @openai, :provider_reported)
      assert Usage.amount(o, :input_uncached_tokens) == :unknown
      assert Usage.prompt_input_tokens(o) == :unknown

      {:ok, a} = Usage.from_provider(raw, @anthropic, :provider_reported)
      # Under the Anthropic convention the uncached input is still the input counter.
      assert Usage.amount(a, :input_uncached_tokens) == 12_000
      assert Usage.prompt_input_tokens(a) == :unknown

      # A missing input under Anthropic leaves the uncached input :unknown.
      {:ok, a} = Usage.from_provider(%{@anthropic_example | input: :unknown}, @anthropic, :provider_reported)
      assert Usage.amount(a, :input_uncached_tokens) == :unknown
    end

    test "an inconsistent includes-cached report is :unknown, not clamped" do
      raw = %{input: 100, cache_read: 90, cache_writes: [%{ttl: "provider_default", amount: 20}]}
      {:ok, u} = Usage.from_provider(raw, @openai, :provider_reported)
      assert Usage.amount(u, :input_uncached_tokens) == :unknown
      assert Usage.input_uncached(100, 100, [], true) == 0
    end

    test "no usage reported at all" do
      u = Usage.unknown(@anthropic)
      assert u.source == :unknown
      assert Usage.amount(u, :output_tokens) == :unknown
      assert Usage.prompt_input_tokens(u) == :unknown
      assert Usage.amount(u, :reasoning_tokens) == :unknown
    end

    test "an empty cache-write list is a reported zero" do
      {:ok, u} = Usage.from_provider(%{input: 5, cache_read: 0, cache_writes: [], output: 1}, @anthropic, :provider_reported)
      assert Usage.prompt_input_tokens(u) == 5
    end

    test "reasoning and non-token units" do
      raw = Map.merge(@anthropic_example, %{reasoning: 40, images: 2, audio_seconds: 3})
      {:ok, u} = Usage.from_provider(raw, @anthropic, :provider_reported)
      assert Usage.amount(u, :reasoning_tokens) == 40
      assert Usage.amount(u, :images) == 2
      assert Usage.amount(u, :audio_seconds) == 3
    end
  end

  describe "M1 usage validation" do
    setup do
      {:ok, u} = Usage.from_provider(@anthropic_example, @anthropic, :provider_reported)
      %{u: u}
    end

    test "valid value passes", %{u: u}, do: assert({:ok, ^u} = Usage.validate(u))

    test "unknown unit, duplicate unit, negative and non-integer amounts refused", %{u: u} do
      for counters <- [
            [%{unit: :dollars, amount: 1}],
            [%{unit: "output_tokens", amount: 1}],
            [%{unit: :output_tokens, amount: 1}, %{unit: :output_tokens, amount: 2}],
            [%{unit: :output_tokens, amount: -1}],
            [%{unit: :output_tokens, amount: 1.5}],
            [%{unit: :output_tokens, amount: nil}],
            [%{unit: :output_tokens, amount: 0, extra: 1}],
            [{:output_tokens, 1}]
          ] do
        assert {:error, :usage_counter} = Usage.validate(%{u | counters: counters}), inspect(counters)
      end

      assert {:error, :usage_counter} = Usage.from_provider(%{input: -1}, @anthropic, :provider_reported)
      assert {:error, :usage_counter} = Usage.from_provider(%{input: 1, cache_read: 0, dollars: 3}, @anthropic, :provider_reported)
    end

    test "unknown TTL, duplicate TTL, bad write amount refused", %{u: u} do
      for writes <- [
            [%{ttl: "10m", amount: 1}],
            [%{ttl: :"5m", amount: 1}],
            [%{ttl: "5m", amount: 1}, %{ttl: "5m", amount: 2}],
            [%{ttl: "1h", amount: -3}],
            :none
          ] do
        assert {:error, :usage_cache_write} = Usage.validate(%{u | cache_writes: writes}), inspect(writes)
      end
    end

    test "convention, source and shape", %{u: u} do
      assert {:error, :usage_convention} = Usage.validate(%{u | convention: %{input_includes_cached: nil}})
      assert {:error, :usage_convention} = Usage.validate(%{u | convention: %{}})
      assert {:error, :usage_source} = Usage.validate(%{u | source: :estimated})
      assert {:error, :usage_shape} = Usage.validate(Map.put(u, :cost, 1))
      assert {:error, :usage_shape} = Usage.validate(Map.delete(u, :source))
      assert {:error, :usage_shape} = Usage.validate([])
      assert Enum.all?(Usage.units(), &is_atom/1) and length(Usage.units()) == 9
      assert Usage.ttls() == ["5m", "1h", "30m", "12h", "24h", "provider_default"]
    end
  end

  describe "M3 cache hint" do
    @hint %{tenant: "tenant-a", local_key: "docs-v1", ttl: "5m", breakpoints: [:tools, :system, {:message, 3}]}

    test "same tenant accepted" do
      assert {:ok, @hint} = CacheHint.validate(@hint, "tenant-a")
    end

    test "a hint naming another tenant is refused invalid_request" do
      assert {:error, :invalid_request} = CacheHint.validate(@hint, "tenant-b")
      assert {:error, :invalid_request} = CacheHint.validate(%{@hint | tenant: "tenant-b"}, "tenant-a")
      assert {:error, :invalid_request} = CacheHint.validate(@hint, nil)
    end

    test "grammar" do
      bad = [
        %{@hint | ttl: "2h"},
        %{@hint | breakpoints: []},
        %{@hint | breakpoints: [:tools, :tools]},
        %{@hint | breakpoints: [:tools, :system, {:message, 0}, {:message, 1}, {:message, 2}]},
        %{@hint | breakpoints: [{:message, -1}]},
        %{@hint | breakpoints: [:messages]},
        %{@hint | local_key: ""},
        %{@hint | local_key: "a\nb"},
        %{@hint | tenant: String.duplicate("t", 257)},
        Map.put(@hint, :wire_key, "global"),
        Map.delete(@hint, :tenant)
      ]

      for hint <- bad, do: assert({:error, :invalid_request} = CacheHint.validate(hint, hint[:tenant] || "tenant-a"), inspect(hint))
      assert {:ok, _} = CacheHint.validate(%{@hint | breakpoints: [:tools, :system, {:message, 0}, {:message, 1}]}, "tenant-a")
      assert CacheHint.max_breakpoints() == 4
    end
  end

  describe "model reference, provenance and failure classes" do
    @ref %{provider: "anthropic", model_id: "claude-sonnet-4-5", wire_surface: "messages"}

    test "model reference" do
      assert {:ok, @ref} = ModelRef.validate(@ref)
      assert {:error, :model_ref} = ModelRef.validate(%{@ref | model_id: ""})
      assert {:error, :model_ref} = ModelRef.validate(Map.put(@ref, :x, 1))
      assert {:error, :model_ref} = ModelRef.validate(nil)
    end

    test "provenance with and without ids" do
      p = %{model_ref: @ref, provider_model: "claude-sonnet-4-5-20250929", response_id: "msg_01", request_id: "req_1", provider_piece: "integration/ai-text-anthropic"}
      assert {:ok, _} = Provenance.validate(p)
      assert {:ok, _} = Provenance.validate(%{p | response_id: :absent, request_id: :absent})
      assert {:error, :provenance} = Provenance.validate(%{p | response_id: nil})
      assert {:error, :provenance} = Provenance.validate(%{p | request_id: ""})
      assert {:error, :provenance} = Provenance.validate(%{p | model_ref: %{}})
    end

    test "failure classes and reason membership" do
      reasons = %{refused: [:throttled], unknown: [:timeout]}
      assert {:ok, _} = Failure.validate({:refused, :throttled}, reasons)
      assert {:ok, _} = Failure.validate({:unknown, :timeout}, reasons)
      assert {:error, :failure} = Failure.validate({:refused, :timeout}, reasons)
      assert {:error, :failure} = Failure.validate({:failed, :timeout}, reasons)
      assert {:error, :failure} = Failure.validate({:unknown, "timeout"}, reasons)
      assert Failure.classes() == [:refused, :unknown]
    end
  end

  describe "M4 job and stream chunk" do
    test "job reference and every job state" do
      assert {:ok, _} = Job.validate_ref(%{provider: "anthropic", provider_job_id: "msgbatch_1", submitted_at: 1_700_000_000_000})
      assert {:error, :job_ref} = Job.validate_ref(%{provider: "anthropic", provider_job_id: "msgbatch_1", submitted_at: -1})
      assert {:error, :job_ref} = Job.validate_ref(%{provider: "anthropic", provider_job_id: ""})

      for s <- [:pending, :running, :ending, :expired, :cancelled, :failed], do: assert({:ok, ^s} = Job.validate_state(s))
      counts = %{succeeded: 3, errored: 1, cancelled: 0, expired: 0}
      assert {:ok, _} = Job.validate_state({:ended, counts})
      assert {:error, :job_state} = Job.validate_state({:ended, Map.delete(counts, :expired)})
      assert {:error, :job_state} = Job.validate_state({:ended, %{counts | errored: -1}})
      assert {:error, :job_state} = Job.validate_state(:done)
      assert {:error, :job_state} = Job.validate_state(:ended)
    end

    test "stream chunk kinds" do
      {:ok, u} = Usage.from_provider(@anthropic_example, @anthropic, :provider_reported)

      for {kind, payload} <- [
            text_delta: "",
            text_delta: "héllo",
            tool_delta: %{index: 0, delta: "{\"q\":"},
            usage: u,
            finish: %{reason: :stop},
            finish: %{reason: {:other, "pause_turn"}}
          ] do
        assert {:ok, _} = StreamChunk.validate(%{seq: 0, kind: kind, payload: payload}), inspect(kind)
      end

      for chunk <- [
            %{seq: -1, kind: :text_delta, payload: "x"},
            %{seq: 0, kind: :reasoning_delta, payload: "x"},
            %{seq: 0, kind: :text_delta, payload: <<0xFF>>},
            %{seq: 0, kind: :tool_delta, payload: %{index: 0}},
            %{seq: 0, kind: :usage, payload: %{}},
            %{seq: 0, kind: :finish, payload: %{reason: nil}},
            %{seq: 0, kind: :finish, payload: %{reason: {:other, "a\nb"}}},
            %{seq: 0, kind: :text_delta}
          ] do
        assert {:error, :stream_chunk} = StreamChunk.validate(chunk), inspect(chunk)
      end

      assert StreamChunk.kinds() == [:text_delta, :tool_delta, :usage, :finish]
    end
  end

  test "errors carry a fixed atom and never echo input" do
    secret = "sk-ant-SECRET-#{System.unique_integer([:positive])}"
    results = [
      CacheHint.validate(%{tenant: secret, local_key: secret, ttl: "9m", breakpoints: [:tools]}, "other"),
      ModelRef.validate(%{provider: secret}),
      Usage.validate(%{counters: [%{unit: secret, amount: 1}], cache_writes: [], convention: %{input_includes_cached: true}, source: :unknown})
    ]

    for r <- results do
      assert {:error, reason} = r
      assert is_atom(reason)
      refute inspect(r) =~ secret
    end
  end
end
