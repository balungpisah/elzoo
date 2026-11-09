# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_batch_anthropic_test_helper.exs", __DIR__)

defmodule Elzoo.AiBatch.AnthropicTest.SubmitBinding do
  use Elzoo.AiBatch.Binding,
    operation: :submit,
    id: "anthropic-batch-test-submit",
    provider_account: "anthropic:test-workspace",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiBatch.AnthropicTest.CancelBinding do
  use Elzoo.AiBatch.Binding,
    operation: :cancel,
    id: "anthropic-batch-test-cancel",
    provider_account: "anthropic:test-workspace",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiBatch.AnthropicTest.TextBinding do
  use Elzoo.AiText.Binding,
    id: "anthropic-batch-test-sync",
    provider_account: "anthropic:test-workspace",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiBatch.AnthropicTest do
  # Every exchange goes to an in-process function plug through Req's :plug
  # option (no network, stub keys only). Each scenario names its boundary.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.AiBatch
  alias Elzoo.AiBatch.{Anthropic, AnthropicStub, Conformance, Join, Sink, Staging}
  alias Elzoo.AiText
  alias Elzoo.AiText.Schema
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @model "claude-sonnet-4-5"
  @key "sk-ant-test-INJECTED-b5"
  @path "/v1/messages/batches"
  @batch_id "msgbatch_013Zva2CMHLNnXjNJJKqJ2EF"
  @job %{provider: "anthropic", provider_job_id: @batch_id, submitted_at: 1}
  @schema_file Path.expand("../fixtures/anthropic/message-batch-create.schema.json", __DIR__)
  @drift_file Path.expand("../fixtures/anthropic/req-llm-1.30.0-item-bodies.json", __DIR__)

  setup do
    {:ok, schema} = Schema.build(Jason.decode!(File.read!(@schema_file)))
    staging = start_supervised!({Staging, []})

    %{
      intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent),
      schema: schema,
      staging: staging
    }
  end

  ## helpers

  defp config(ctx, plug, opts \\ []) do
    {:ok, c} =
      AiBatch.configure(
        [
          submit_binding: Elzoo.AiBatch.AnthropicTest.SubmitBinding,
          cancel_binding: Elzoo.AiBatch.AnthropicTest.CancelBinding,
          tenant: "tenant-a",
          provider: Anthropic,
          provider_config: %{plug: plug},
          credentials: Keyword.get(opts, :credentials, fn -> {:ok, @key} end),
          submissions: {Staging, ctx.staging},
          models: [@model],
          max_output_tokens: 4096,
          receive_timeout_ms: 5000,
          sink: Sink.to_pid(self())
        ] ++ Keyword.get(opts, :bounds, [])
      )

    c
  end

  defp owner(binding, c, a, ctx) do
    memory =
      start_supervised!({Memory, fold: Intent.fold(binding), limits: Intent.limits()},
        id: make_ref()
      )

    host =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    {:ok, pid} =
      Intent.start_link(
        binding: binding,
        identity: a.identity,
        arguments: a.arguments,
        deadline: a.deadline,
        clock: fn -> 100 end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: c,
        allow_volatile: true
      )

    pid
  end

  defp settled(pid, tries \\ 300) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(20) && settled(pid, tries - 1)
    end
  end

  defp submit(ctx, respond, sub \\ Conformance.submission(@model), opts \\ []) do
    {agent, plug} = AnthropicStub.start(respond)
    c = config(ctx, plug, opts)
    ref = "ref-#{System.unique_integer([:positive])}"
    {:ok, a} = AiBatch.admit_submit(c, Conformance.submit_declaration(sub, ref, 10_000))
    :ok = Staging.put(ctx.staging, a)
    send(self(), {:admitted, a})
    pid = owner(c.submit_binding, c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)
    key = a.key
    assert_receive {AiBatch, ^key, delivery}, 5000
    {delivery, AnthropicStub.requests(agent), pid, c}
  end

  defp cancel(ctx, respond, ref \\ "cancel-1") do
    {agent, plug} = AnthropicStub.start(respond)
    c = config(ctx, plug)
    {:ok, a} = AiBatch.admit_cancel(c, Conformance.cancel_declaration(@job, ref, 10_000))
    pid = owner(c.cancel_binding, c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)
    key = a.key
    assert_receive {AiBatch, ^key, delivery}, 5000
    {delivery, AnthropicStub.requests(agent), pid, c}
  end

  defp read(ctx, respond, opts \\ []) do
    {agent, plug} = AnthropicStub.start(respond)
    {config(ctx, plug, opts), agent}
  end

  defp header(req, name), do: for({^name, v} <- req.headers, do: v)

  defp join(c, ids \\ Conformance.ids()) do
    {:ok, j} = Join.new(c, AiText.Request.canonical(Conformance.submission(@model, ids)))
    j
  end

  defp results_reply(lines, chunk \\ 64),
    do: {:chunked, 200, AnthropicStub.split(AnthropicStub.jsonl(lines), chunk)}

  # Every captured create request: method, path, outer headers, injected key,
  # the hand-derived schema, unique ids and the batch-only parameter rules.
  defp conforms(req, schema, betas) do
    assert req.method == "POST"
    assert req.path == @path
    assert header(req, "anthropic-version") == ["2026-10-21"]
    assert header(req, "x-api-key") == [@key]
    assert header(req, "anthropic-beta") == if(betas == [], do: [], else: [Enum.join(betas, ",")])
    body = Jason.decode!(req.body)
    assert :ok == Schema.validate(body, schema)
    ids = Enum.map(body["requests"], & &1["custom_id"])
    assert length(Enum.uniq(ids)) == length(ids)

    for %{"params" => p} <- body["requests"] do
      refute Map.has_key?(p, "stream") or Map.has_key?(p, "speed") or Map.has_key?(p, "fallbacks")
      assert p["max_tokens"] > 0
      refute Map.has_key?(p, "temperature") or Map.has_key?(p, "top_p") or Map.has_key?(p, "top_k")
    end

    body
  end

  ## submit

  test "B1 submit accepted: the create request conforms to the hand-derived schema; orphans empty; one request (conformance kit + schema)",
       ctx do
    {delivery, reqs, pid, _c} =
      submit(ctx, fn {"POST", @path, _} ->
        AnthropicStub.ok(AnthropicStub.batch("in_progress", %{"processing" => 4}))
      end)

    assert {:outcome, _, {:submitted, %{job_ref: ref, item_count: 4, orphans: []}}} = delivery
    assert ref == %{ref | provider: "anthropic", provider_job_id: @batch_id}
    assert length(reqs) == 1
    # The outbound body is byte-identical to the body the admission digest names.
    assert_received {:admitted, a}
    {:ok, m} = AiBatch.Submission.decode_manifest(a.arguments)
    assert hd(reqs).body == a.staged
    assert AiBatch.Submission.sha256(hd(reqs).body) == m.wire_sha256
    body = conforms(hd(reqs), ctx.schema, [])
    assert Enum.map(body["requests"], & &1["custom_id"]) == Conformance.ids()
    state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
    refute state =~ "Batch conformance prompt"
    refute state =~ @key
  end

  test "B2 submit lost after send is unknown; a second dispatch is refused; 401, 429 and 529 mapped with one request each; orphans always empty (Adapter + owner)",
       ctx do
    {delivery, reqs, pid, _} = submit(ctx, fn _ -> {:transport_error, :timeout} end)
    assert {:outcome, _, {:unknown, :timeout, %{orphans: []}}} = delivery
    assert length(reqs) == 1
    assert {:error, _} = Intent.advance(pid, :dispatch)
    assert {:error, _} = Intent.advance(pid, :rearm)

    for {reply, expected} <- [
          {{401, [], AnthropicStub.error("authentication_error")},
           {:refused, :authentication_failed, %{retry_after: nil, orphans: []}}},
          {{429, [{"retry-after", "7"}], AnthropicStub.error("rate_limit_error")},
           {:refused, :throttled, %{retry_after: 7, orphans: []}}},
          {{529, [], AnthropicStub.error("overloaded_error")},
           {:refused, :overloaded, %{retry_after: nil, orphans: []}}},
          {{413, [], AnthropicStub.error("request_too_large")},
           {:refused, :too_large, %{retry_after: nil, orphans: []}}},
          {{500, [], AnthropicStub.error("api_error")},
           {:unknown, :provider_error, %{orphans: []}}},
          {AnthropicStub.ok(%{"type" => "message_batch"}),
           {:unknown, :malformed_response, %{orphans: []}}}
        ] do
      {delivery, reqs, _, _} = submit(ctx, fn _ -> reply end)
      assert {:outcome, _, ^expected} = delivery
      assert length(reqs) == 1
    end

    {delivery, reqs, _, _} =
      submit(ctx, fn _ -> {429, [{"retry-after", "7"}], AnthropicStub.error("rate_limit_error")} end)

    assert Conformance.check_write(:submit_throttled, delivery, length(reqs)) == :ok
  end

  test "B3 batch-global headers: the outer beta is the sorted union of the items' allowed values; a value outside the allowed set is refused before any request (prepare + stub)",
       ctx do
    corpus = Map.new(AnthropicStub.corpus(@model))

    sub = %{
      "version" => 1,
      "model" => @model,
      "items" => [
        %{"item_id" => "tools", "request" => corpus["tools_auto"]},
        %{"item_id" => "cache", "request" => corpus["cache_1h"]},
        %{"item_id" => "plain", "request" => corpus["plain"]}
      ]
    }

    {delivery, [req], _, _} =
      submit(ctx, fn _ -> AnthropicStub.ok(AnthropicStub.batch("in_progress")) end, sub)

    assert {:outcome, _, {:submitted, _}} = delivery
    conforms(req, ctx.schema, ["prompt-caching-2024-07-31", "tools-2024-05-16"])

    # A prepared item carrying a beta outside the allowed set.
    {:ok, r, _} = AiText.Request.decode(AiText.Request.canonical(corpus["plain"]))
    {:ok, wire} = AiText.Anthropic.translate(r, nil)
    beta = %{wire | opts: Keyword.put(wire.opts, :anthropic_beta, ["files-api-2025-04-14"])}
    assert {:refused, :unsupported_feature} = Anthropic.item_body(beta)

    assert {:refused, :unsupported_feature} =
             Anthropic.prepare(%{items: [%{item_id: "x", request: r, wire: beta}]}, nil)

    assert "interleaved-thinking-2025-05-14" in Anthropic.allowed_betas()

    # Staged metadata is rechecked before sending: another beta, an unsorted
    # union or an unknown key sends nothing.
    {agent, plug} = AnthropicStub.start(fn _ -> raise "no request expected" end)
    opts = %{credential: @key, receive_timeout_ms: 1000, provider_config: %{plug: plug}}

    for meta <- [
          %{"anthropic-beta" => "files-api-2025-04-14"},
          %{"anthropic-beta" => "tools-2024-05-16,prompt-caching-2024-07-31"},
          %{"x-other" => "1"}
        ] do
      assert {:failure, :adapter_error, %{orphans: []}} =
               Anthropic.submit(%{body: "{}", meta: meta}, opts)
    end

    # An invalid provider term refuses every operation before any request; it
    # never falls back to the default endpoint.
    bad = %{credential: @key, receive_timeout_ms: 1000, provider_config: %{plug: plug, other: 1}}
    page = %{cursor: 0, page_size: 1, max_line_bytes: 100, max_scan_bytes: 100}
    assert {:failure, :provider_invalid_request, _} = Anthropic.status(@batch_id, bad)
    assert {:failure, :provider_invalid_request, _} = Anthropic.cancel(@batch_id, bad)
    assert {:failure, :provider_invalid_request, _} = Anthropic.results(@batch_id, page, bad)

    assert {:failure, :provider_invalid_request, %{orphans: []}} =
             Anthropic.submit(%{body: "{}", meta: %{}}, bad)

    assert AnthropicStub.requests(agent) == []
  end

  test "B4 drift guard: item params and headers for the fixed corpus equal the pinned req_llm 1.30.0 snapshot (upstream risk on the encoded-body location)" do
    snapshot = Jason.decode!(File.read!(@drift_file))
    corpus = AnthropicStub.corpus(@model)
    assert Enum.sort(Map.keys(snapshot)) == Enum.sort(Enum.map(corpus, &elem(&1, 0)))

    for {name, request} <- corpus do
      {:ok, r, _} = AiText.Request.decode(AiText.Request.canonical(request))
      {:ok, wire} = AiText.Anthropic.translate(r, nil)
      {:ok, b} = Anthropic.item_body(wire)
      observed = %{"params" => Jason.decode!(Jason.encode!(b.params)), "headers" => b.headers}
      assert observed == snapshot[name], "req_llm item body drifted for #{name}"
    end
  end

  test "B5 body equivalence: each batch item's params equal the body the synchronous ai-text-anthropic call sent, minus stream false, over the fixed corpus (sync stub vs prepare)",
       ctx do
    {agent, plug} =
      AnthropicStub.start(fn _ ->
        AnthropicStub.ok(AnthropicStub.message("ok"))
      end)

    {:ok, sync} =
      AiText.configure(
        binding: Elzoo.AiBatch.AnthropicTest.TextBinding,
        tenant: "tenant-a",
        provider: AiText.Anthropic,
        provider_config: %{plug: plug},
        credentials: fn -> {:ok, @key} end,
        models: [@model],
        max_output_tokens: 4096,
        receive_timeout_ms: 5000,
        sink: fn _, _ -> :ok end
      )

    for {name, request} <- AnthropicStub.corpus(@model) do
      {:ok, a} =
        AiText.admission(sync, AiText.Conformance.declaration(request, "eq-" <> name, 10_000))

      pid = owner(sync.binding, sync, a, ctx)
      {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      settled(pid)
      sent = AnthropicStub.requests(agent) |> List.last()
      assert sent.path == "/v1/messages"
      sync_body = Jason.decode!(sent.body)
      assert sync_body["stream"] == false

      {:ok, r, _} = AiText.Request.decode(AiText.Request.canonical(request))
      {:ok, wire} = AiText.Anthropic.translate(r, nil)
      {:ok, b} = Anthropic.item_body(wire)
      params = Jason.decode!(Jason.encode!(b.params))
      assert params == Map.delete(sync_body, "stream"), "#{name} differs from the synchronous body"

      sync_betas =
        sent.headers |> Enum.filter(&(elem(&1, 0) == "anthropic-beta")) |> Enum.map(&elem(&1, 1))

      assert sync_betas == if(b.betas == [], do: [], else: [Enum.join(b.betas, ",")])
    end
  end

  test "B6 bounds: the measured create body at its bound passes, one byte under is refused; items above the provider cap are refused at configuration (admission)",
       ctx do
    {_agent, plug} = AnthropicStub.start(fn _ -> raise "no request expected" end)
    c = config(ctx, plug)
    sub = Conformance.submission(@model, ["a"])
    {:ok, s, _} = AiBatch.Submission.decode(AiText.Request.canonical(sub), AiBatch.bounds(c))
    {:ok, wire} = AiBatch.prepare(c, s)
    size = byte_size(wire.body)

    ok = config(ctx, plug, bounds: [max_create_wire_bytes: size])
    assert {:ok, _} = AiBatch.admit_submit(ok, Conformance.submit_declaration(sub, "b", 10_000))
    tight = config(ctx, plug, bounds: [max_create_wire_bytes: size - 1])

    assert {:error, {:refused, :too_large, %{orphans: []}}} =
             AiBatch.admit_submit(tight, Conformance.submit_declaration(sub, "b", 10_000))

    assert Anthropic.capabilities().max_items == 100_000
    assert Anthropic.capabilities().max_create_wire_bytes == 256_000_000

    assert {:error, :configuration} =
             AiBatch.configure(
               submit_binding: Elzoo.AiBatch.AnthropicTest.SubmitBinding,
               cancel_binding: Elzoo.AiBatch.AnthropicTest.CancelBinding,
               tenant: "t",
               provider: Anthropic,
               credentials: fn -> {:ok, @key} end,
               submissions: {Staging, self()},
               models: [@model],
               sink: fn _, _ -> :ok end,
               max_items: 100_001
             )

    # Sampling is not declared by the item provider: refused at admission.
    bad = put_in(sub, ["items", Access.at(0), "request", "sampling"], %{"top_p" => 0.5})

    assert {:error, {:refused, :unsupported_feature, _}} =
             AiBatch.admit_submit(c, Conformance.submit_declaration(bad, "s", 10_000))
  end

  ## status and cancel

  test "B7 status sequence in_progress -> canceling -> ended with counts; 401 and 404 mapped; one GET each (status read)",
       ctx do
    agent = start_supervised!({Agent, fn -> ["in_progress", "canceling", "ended"] end})
    counts = %{"succeeded" => 1, "errored" => 1, "canceled" => 1, "expired" => 1}

    {c, rec} =
      read(ctx, fn {"GET", "/v1/messages/batches/" <> @batch_id, _} ->
        ps = Agent.get_and_update(agent, fn [s | r] -> {s, r} end)

        AnthropicStub.ok(
          AnthropicStub.batch(ps, if(ps == "ended", do: counts, else: %{"processing" => 4}))
        )
      end)

    seen = for _ <- 1..3, do: AiBatch.status(c, @job)
    assert Conformance.check_status(:status_sequence, seen) == :ok
    reqs = AnthropicStub.requests(rec)
    assert length(reqs) == 3

    assert Enum.all?(
             reqs,
             &(header(&1, "x-api-key") == [@key] and
                 header(&1, "anthropic-version") == ["2026-10-21"])
           )

    {c, _} = read(ctx, fn _ -> {401, [], AnthropicStub.error("authentication_error")} end)
    assert Conformance.check_status(:status_unauthorized, AiBatch.status(c, @job)) == :ok
    {c, _} = read(ctx, fn _ -> {404, [], AnthropicStub.error("not_found_error")} end)
    assert Conformance.check_status(:status_not_found, AiBatch.status(c, @job)) == :ok

    {c, _} =
      read(ctx, fn _ -> {429, [{"retry-after", "3"}], AnthropicStub.error("rate_limit_error")} end)

    assert {:error, :throttled} = AiBatch.status(c, @job)
    {c, _} = read(ctx, fn _ -> {529, [], AnthropicStub.error("overloaded_error")} end)
    assert {:error, :overloaded} = AiBatch.status(c, @job)

    # An ended batch still counting processing requests, or an unknown status, is malformed.
    for b <- [AnthropicStub.batch("ended", %{"processing" => 1}), AnthropicStub.batch("paused")] do
      {c, _} = read(ctx, fn _ -> AnthropicStub.ok(b) end)
      assert {:error, :malformed_response} = AiBatch.status(c, @job)
    end
  end

  test "B8 cancel during running acknowledged; a lost cancel is unknown, a status observation does not unlock a second cancel; 404 refused (cancel owner)",
       ctx do
    {delivery, [req], _, _} =
      cancel(ctx, fn {"POST", "/v1/messages/batches/" <> @batch_id <> "/cancel", _} ->
        AnthropicStub.ok(AnthropicStub.batch("canceling", %{"processing" => 2}))
      end)

    assert Conformance.check_write(:cancel_accepted, delivery, 1) == :ok
    assert header(req, "x-api-key") == [@key]

    {delivery, reqs, pid, c} =
      cancel(
        ctx,
        fn
          {"POST", _, _} -> {:transport_error, :timeout}
          {"GET", _, _} -> AnthropicStub.ok(AnthropicStub.batch("canceling"))
        end,
        "cancel-lost"
      )

    assert Conformance.check_write(:cancel_lost, delivery, length(reqs)) == :ok
    assert {:ok, %{state: :ending}} = AiBatch.status(c, @job)
    assert {:error, _} = Intent.advance(pid, :dispatch)
    assert {:error, _} = Intent.advance(pid, :rearm)

    {delivery, _, _, _} =
      cancel(ctx, fn _ -> {404, [], AnthropicStub.error("not_found_error")} end, "c404")

    assert {:outcome, _, {:refused, :not_found, %{retry_after: nil}}} = delivery
  end

  ## results

  test "B9 results: mixed succeeded/errored/canceled/expired out of order, streamed in chunks, joined by custom_id; absent usage fields unknown (results + Join)",
       ctx do
    lines = [
      AnthropicStub.expired("item-d"),
      AnthropicStub.succeeded("item-a", AnthropicStub.message(Conformance.text())),
      AnthropicStub.canceled("item-c"),
      AnthropicStub.errored("item-b", "invalid_request_error")
    ]

    {c, rec} =
      read(ctx, fn {"GET", "/v1/messages/batches/" <> @batch_id <> "/results", _} ->
        results_reply(lines, 37)
      end)

    r = AiBatch.results(c, @job, 0, join(c))
    assert Conformance.check_results(:results_mixed, r) == :ok
    assert [req] = AnthropicStub.requests(rec)
    assert header(req, "x-api-key") == [@key]
    {:ok, %{items: items}} = r
    {:succeeded, done} = Map.new(items)["item-a"]
    assert done.provenance.provider_piece == "integration/ai-batch-anthropic"
    assert done.provenance.model_ref.wire_surface == "message_batches"
    assert done.usage.source == :provider_reported

    # Absent usage fields stay unknown; an api_error is a provider error; an
    # undecodable succeeded message is errored malformed_response.
    lines = [
      AnthropicStub.succeeded("item-a", Map.delete(AnthropicStub.message("x"), "usage")),
      AnthropicStub.errored("item-b", "api_error"),
      AnthropicStub.succeeded("item-c", Map.delete(AnthropicStub.message("x"), "stop_reason"))
    ]

    {c, _} = read(ctx, fn _ -> results_reply(lines) end)
    {:ok, %{items: items}} = AiBatch.results(c, @job, 0, join(c))
    by = Map.new(items)
    {:succeeded, a} = by["item-a"]
    assert Elzoo.AiModel.Usage.amount(a.usage, :output_tokens) == :unknown
    assert by["item-b"] == {:errored, :provider_error}
    assert by["item-c"] == {:errored, :malformed_response}
  end

  test "B10 results: unknown and duplicated custom_id refuse the page; a missing item is reported after the last page of an ended batch (results + Join)",
       ctx do
    ok = &AnthropicStub.succeeded(&1, AnthropicStub.message("x"))

    for {id, lines} <- [
          {:results_unknown_id, [ok.("item-a"), ok.("item-z")]},
          {:results_duplicate_id, [ok.("item-a"), ok.("item-a")]}
        ] do
      {c, _} = read(ctx, fn _ -> results_reply(lines) end)
      assert Conformance.check_results(id, AiBatch.results(c, @job, 0, join(c))) == :ok
    end

    {c, _} =
      read(ctx, fn _ ->
        results_reply([ok.("item-b"), ok.("item-a"), AnthropicStub.canceled("item-c")])
      end)

    r = AiBatch.results(c, @job, 0, join(c))
    state = {:ended, %{succeeded: 2, errored: 0, cancelled: 1, expired: 0}}
    assert Conformance.check_results(:results_missing, r, state) == :ok
  end

  test "B11 results paging and bounds: contiguous pages by cursor; a deep cursor beyond the scan bound is result_scan_limit; an oversized line is result_line_limit; a malformed line refuses the page (results)",
       ctx do
    ids = for n <- 1..10, do: "item-#{n}"
    lines = for id <- ids, do: AnthropicStub.succeeded(id, AnthropicStub.message("x"))
    file = AnthropicStub.jsonl(lines)

    {c, rec} =
      read(ctx, fn _ -> {:chunked, 200, AnthropicStub.split(file, 100)} end, bounds: [page_size: 4])

    j = join(c, ids)
    {:ok, %{items: p1, next: 4, join: j}} = AiBatch.results(c, @job, 0, j)
    {:ok, %{items: p2, next: 8, join: j}} = AiBatch.results(c, @job, 4, j)
    {:ok, %{items: p3, next: :done, join: j}} = AiBatch.results(c, @job, 8, j)
    assert Enum.map(p1 ++ p2 ++ p3, &elem(&1, 0)) == ids
    assert length(AnthropicStub.requests(rec)) == 3

    assert {:ok, []} =
             Join.missing(j, {:ended, %{succeeded: 10, errored: 0, cancelled: 0, expired: 0}})

    # The scan bound counts skipped lines (and whole chunks read): the first two
    # pages fit in five lines of scan, the page at cursor 4 needs six.
    line_size = div(byte_size(file), 10) + 1

    {c, _} =
      read(ctx, fn _ -> {:chunked, 200, AnthropicStub.split(file, 50)} end,
        bounds: [page_size: 2, max_scan_bytes: line_size * 5]
      )

    j = join(c, ids)
    {:ok, %{next: 2, join: j2}} = AiBatch.results(c, @job, 0, j)
    {:ok, %{join: j4}} = AiBatch.results(c, @job, 2, j2)
    assert {:error, :result_scan_limit} = AiBatch.results(c, @job, 4, j4)
    assert j4.next == 4

    {c, _} =
      read(ctx, fn _ -> {:chunked, 200, AnthropicStub.split(file, 50)} end,
        bounds: [max_line_bytes: 100]
      )

    assert {:error, :result_line_limit} = AiBatch.results(c, @job, 0, join(c, ids))

    {c, _} = read(ctx, fn _ -> {:chunked, 200, ["{\"custom_id\":\"item-1\"}\n"]} end)
    assert {:error, :malformed_response} = AiBatch.results(c, @job, 0, join(c, ids))

    {c, _} = read(ctx, fn _ -> {404, [], AnthropicStub.error("not_found_error")} end)
    assert {:error, :not_found} = AiBatch.results(c, @job, 0, join(c, ids))

    # A blank record inside the stream is malformed, never a skipped item; a
    # final line without its newline is still read.
    [first | rest] = Enum.take(lines, 3)
    blank = AnthropicStub.jsonl([first]) <> "  \n" <> AnthropicStub.jsonl(rest)
    {c, _} = read(ctx, fn _ -> {:chunked, 200, [blank]} end)
    assert {:error, :malformed_response} = AiBatch.results(c, @job, 0, join(c, ids))
    no_newline = String.trim_trailing(AnthropicStub.jsonl(Enum.take(lines, 2)), "\n")
    {c, _} = read(ctx, fn _ -> {:chunked, 200, [no_newline]} end)
    assert {:ok, %{items: [_, _], next: :done}} = AiBatch.results(c, @job, 0, join(c, ids))
  end

  ## redaction, ambient keys, configuration and audit

  test "B12 credential, prompt and output never in errors, deliveries, logs or inspect; only the injected key is sent (redaction)",
       ctx do
    secret_out = "OUTPUT-SECRET-q4"
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-ENV-not-used")
    Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-APP-not-used")

    try do
      log =
        capture_log([level: :debug], fn ->
          {delivery, [req], _, c} =
            submit(ctx, fn _ -> {400, [], AnthropicStub.error("invalid_request_error")} end)

          assert {:outcome, _, {:refused, :invalid_request, _}} = delivery
          assert header(req, "x-api-key") == [@key]
          refute inspect(delivery) =~ "Batch conformance prompt"
          refute inspect(c) =~ @key

          lines = [AnthropicStub.succeeded("item-z", AnthropicStub.message(secret_out))]
          {c, _} = read(ctx, fn _ -> results_reply(lines) end)
          r = AiBatch.results(c, @job, 0, join(c))
          assert r == {:error, :malformed_page}
          refute inspect(r) =~ secret_out
        end)

      refute log =~ @key
      refute log =~ "Batch conformance prompt"
      refute log =~ secret_out
      refute log =~ "not-used"
    after
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:req_llm, :anthropic_api_key)
    end
  end

  # This Piece's README: in this repository it is under pieces/; in the
  # exported consumer it is under .elzoo/pieces/. Exactly one must exist.
  @readmes [
    Path.expand("../../../../../pieces/integration/ai-batch-anthropic/README.md", __DIR__),
    Path.expand("../../.elzoo/pieces/integration/ai-batch-anthropic/README.md", __DIR__)
  ]

  test "B13 the README's Install configuration section carries the exact consumer config line (README, either layout)" do
    assert [readme] = Enum.filter(@readmes, &File.regular?/1)
    text = File.read!(readme)
    [_, section] = String.split(text, "## Install configuration", parts: 2)
    section = section |> String.split("\n## ", parts: 2) |> hd()
    assert section =~ "config :req_llm, load_dotenv: false"
  end

  @layouts [
    {Path.expand("../..", __DIR__), Path.expand("../../piece.json", __DIR__)},
    {Path.expand("../..", __DIR__),
     Path.expand("../../.elzoo/pieces/integration/ai-batch-anthropic/piece.json", __DIR__)}
  ]

  test "B14 source audit of this Piece's own listed files: no global key lookup, no req_llm transport call, Req retries and redirects off" do
    {root, files} =
      case Enum.filter(@layouts, fn {_, m} -> File.regular?(m) end) do
        [{root, m}] -> {root, Jason.decode!(File.read!(m))["files"]}
        found -> flunk("expected exactly one manifest, found #{length(found)}")
      end

    [lib] = Enum.filter(files, &String.starts_with?(&1, "lib/"))
    source = File.read!(Path.join(root, lib))
    # Built by concatenation so this file does not contain the names it forbids.
    for word <- [
          "System." <> "get_env",
          "Application." <> "get_env",
          "generate" <> "_text",
          "Req" <> "LLM.generate"
        ] do
      refute source =~ word, "#{lib} references #{word}"
    end

    assert source =~ "retry: false"
    assert source =~ "redirect: false"
  end
end
