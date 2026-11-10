# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_embedding_test_helper.exs", __DIR__)

defmodule Elzoo.AiEmbeddingTest do
  # Interface scenarios with a scripted test provider; each names its boundary.
  # The EffectIntent owner runs on the volatile Memory store (no database).
  use ExUnit.Case, async: false

  alias Elzoo.AiEmbedding

  alias Elzoo.AiEmbedding.{
    Adapter,
    Conformance,
    Descriptor,
    Outcome,
    Request,
    Retry,
    Sink,
    TestHelper
  }

  alias Elzoo.AiModel.Usage
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @secret "sk-test-SECRET-k91"
  @text "input-SECRET-t44"

  setup do
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent)}
  end

  ## helpers

  defp request(extra \\ %{}) do
    Map.merge(%{"version" => 1, "model" => "test-embed", "inputs" => [@text]}, extra)
  end

  defp unit(i, dims \\ 4), do: for(k <- 0..(dims - 1), do: if(k == i, do: 1.0, else: 0.0))

  defp default_respond(req) do
    {:ok,
     {:raw,
      TestHelper.raw(
        for(i <- 0..(length(req.inputs) - 1), do: %{index: i, vector: unit(i)}),
        req.model
      )}}
  end

  defp config(opts \\ []) do
    parent = self()

    base =
      [
        binding: Elzoo.AiEmbedding.TestBinding,
        tenant: "tenant-a",
        provider: Elzoo.AiEmbedding.TestProvider,
        provider_config: %{parent: parent, respond: Keyword.get(opts, :respond, &default_respond/1)},
        credentials: Keyword.get(opts, :credentials, fn -> {:ok, @secret} end),
        models: ["test-embed", "test-fixed"],
        sink: Keyword.get(opts, :sink, Sink.to_pid(parent))
      ] ++ Keyword.get(opts, :extra, [])

    {:ok, c} = AiEmbedding.configure(base)
    c
  end

  defp admit(c, req, ref \\ "req-1"),
    do: AiEmbedding.admission(c, Conformance.declaration(req, ref, 10_000))

  defp owner(c, admission, ctx) do
    memory =
      start_supervised!({Memory, fold: Intent.fold(c.binding), limits: Intent.limits()},
        id: make_ref()
      )

    host =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    {:ok, pid} =
      Intent.start_link(
        binding: c.binding,
        identity: admission.identity,
        arguments: admission.arguments,
        deadline: admission.deadline,
        clock: fn -> 100 end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: c,
        allow_volatile: true
      )

    pid
  end

  defp settled(pid, tries \\ 250) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(20) && settled(pid, tries - 1)
    end
  end

  defp dispatch(c, req, ctx, ref \\ "req-1") do
    {:ok, a} = admit(c, req, ref)
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key
    assert_receive {AiEmbedding, ^key, delivery}, 2000
    {pid, a, status, delivery}
  end

  defp calls do
    receive do
      {:call, _, _} -> 1 + calls()
    after
      50 -> 0
    end
  end

  defp drain do
    receive do
      {:translate, _} -> drain()
    after
      0 -> :ok
    end
  end

  ## I1 call path

  test "I1 completed call through admission, EffectIntent owner and Adapter; vectors reach only the sink (owner + Adapter)",
       ctx do
    c = config()
    {pid, a, status, delivery} = dispatch(c, request(%{"inputs" => [@text, "b"]}), ctx)
    assert {:outcome, attempt_id, {:completed, body}} = delivery
    assert is_binary(attempt_id)
    assert body.embeddings == [%{index: 0, vector: unit(0)}, %{index: 1, vector: unit(1)}]

    assert body.descriptor == %{
             provider: "test",
             model: "test-embed",
             dimensions: 4,
             dtype: :float32,
             normalization: :unit_l2_verified
           }

    assert body.provenance == %{
             model_ref: %{provider: "test", model_id: "test-embed", wire_surface: "scripted"},
             provider_model: "test-embed",
             response_id: :absent,
             request_id: "req_1",
             provider_piece: "test/ai-embedding-provider"
           }

    assert Usage.amount(body.usage, :input_uncached_tokens) == 12
    assert {:Confirmed, 1} = status.phase
    assert_received {:call, @secret, 60_000}
    # Vectors never in the owner's state or status; the envelope holds digest and seal only.
    state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
    refute state =~ "0.0, 1.0"
    refute state =~ @secret
    refute inspect(status) =~ @text
    assert byte_size(a.arguments) > 0
  end

  test "I1 every conformance-kit scenario passes against the scripted provider (kit)", ctx do
    for {s, i} <- Enum.with_index(Conformance.scenarios()) do
      dims = 4
      stub = Conformance.stub(s.id, dims)
      c = config(respond: fn req -> TestHelper.respond(stub, req.model) end)

      {_pid, _a, _status, delivery} =
        dispatch(c, Conformance.request(s.id, "test-embed", nil), ctx, "kit-#{i}")

      assert :ok == Conformance.check(s.id, delivery, calls(), dims), inspect({s.id, delivery})
    end
  end

  ## I2 local refusals

  test "I2 local refusals return before an intent exists, the credential Need runs or the provider is called (admission)" do
    parent = self()

    need = fn ->
      send(parent, :need_called)
      {:ok, @secret}
    end

    c = config(credentials: need, extra: [max_inputs: 3, max_input_bytes: 16])

    cases = [
      {%{"inputs" => []}, :invalid_request},
      {%{"inputs" => [""]}, :invalid_request},
      {%{"inputs" => ["a", 5]}, :invalid_request},
      {%{"inputs" => ["a", "b", "c", "d"]}, :too_large},
      {%{"inputs" => [String.duplicate("x", 17)]}, :too_large},
      {%{"model" => "other-model"}, :invalid_request},
      {%{"dimensions" => 1}, :invalid_request},
      {%{"dimensions" => 5}, :invalid_request},
      {%{"dimensions" => 0}, :invalid_request},
      {%{"model" => "test-fixed", "dimensions" => 2}, :invalid_request},
      {%{"input_type" => "document"}, :unsupported_feature},
      {%{"input_type" => "passage"}, :invalid_request},
      {%{"provider_options" => %{"nope" => 1}}, :invalid_request},
      {%{"provider_options" => %{"flavour" => "loud"}}, :invalid_request},
      {%{"provider_options" => %{"flavour" => "terse"}, "inputs" => ["a", "b", "c"]},
       :unsupported_feature},
      {%{"extra" => true}, :invalid_request},
      {%{"version" => 2}, :invalid_request}
    ]

    for {extra, reason} <- cases do
      assert {:error, {:refused, ^reason}} = admit(c, request(extra)), inspect(extra)
    end

    # Accepted variants: reduced and native dimensions, a declared input type and option.
    for extra <- [
          %{"dimensions" => 2},
          %{"model" => "test-fixed", "dimensions" => 3},
          %{"input_type" => "query"},
          %{"provider_options" => %{"flavour" => "plain"}}
        ] do
      assert {:ok, _} = admit(c, request(extra)), inspect(extra)
    end

    refute_received :need_called
    assert calls() == 0
  end

  test "I2 malformed declarations and payloads: duplicate keys, invalid UTF-8, wrong capability (admission)" do
    c = config()
    decl = Conformance.declaration(request(), "r", 10_000)

    dup =
      put_in(
        decl,
        ["command", "payload"],
        ~s({"version":1,"version":1,"model":"test-embed","inputs":["a"]})
      )

    assert {:error, {:refused, :invalid_request}} = AiEmbedding.admission(c, dup)
    bad = put_in(decl, ["command", "payload"], <<0xFF>>)
    assert {:error, {:refused, :invalid_request}} = AiEmbedding.admission(c, bad)
    assert {:error, :declaration} = AiEmbedding.admission(c, %{decl | "operation" => "generate"})

    assert {:error, :declaration} =
             AiEmbedding.admission(c, %{decl | "capability_id" => "integration/ai-text"})

    assert {:error, :declaration} =
             AiEmbedding.admission(c, %{decl | "classification" => "trusted"})
  end

  # A request whose canonical payload is exactly `size` bytes: one input padded to fit.
  defp sized_request(size) do
    base = Request.canonical(request(%{"inputs" => [""]}))
    request(%{"inputs" => [String.duplicate("y", size - byte_size(base))]})
  end

  test "I2 the request bound is the canonical command payload: 65,536 bytes admitted, 65,537 refused too_large before intent, Need and transport (admission + Adapter)",
       ctx do
    parent = self()

    need = fn ->
      send(parent, :need_called)
      {:ok, @secret}
    end

    c = config(credentials: need, extra: [max_input_bytes: 65_536])

    exact = sized_request(65_536)
    assert byte_size(Request.canonical(exact)) == 65_536
    over = sized_request(65_537)
    assert byte_size(Request.canonical(over)) == 65_537

    assert {:error, {:refused, :too_large}} = admit(c, over)
    refute_received :need_called
    assert calls() == 0

    {:ok, a} = admit(c, exact)
    assert byte_size(a.arguments) == 65_536

    # JSON escaping counts: 21,846 newlines are 43,692 canonical bytes.
    escaped = request(%{"inputs" => [String.duplicate("\n", 32_768)]})
    assert byte_size(Request.canonical(escaped)) > 65_536
    assert {:error, {:refused, :too_large}} = admit(c, escaped)

    # A payload whose raw form carries insignificant whitespace is measured canonically.
    spaced = String.replace(Request.canonical(exact), ",", ", ")
    assert byte_size(spaced) > 65_536
    decl = put_in(Conformance.declaration(exact, "ws", 10_000), ["command", "payload"], spaced)
    assert {:ok, %{arguments: args}} = AiEmbedding.admission(c, decl)
    assert byte_size(args) == 65_536

    # The exact bound also passes the owner's own argument bound and dispatches.
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)
    assert_receive {AiEmbedding, _, {:outcome, _, {:completed, _}}}, 2000

    # A lower configured bound narrows it.
    small = config(extra: [max_request_bytes: 100])
    assert {:error, {:refused, :too_large}} = admit(small, sized_request(101))
    assert {:ok, _} = admit(small, sized_request(100))
  end

  ## I3 response checks

  test "I3 count, index set, length and value defects are unknown{malformed_response}, never a partial list; reversed indices are reordered (Adapter)",
       ctx do
    good = for i <- 0..2, do: %{index: i, vector: unit(i)}

    bad = [
      Enum.drop(good, 1),
      good ++ [%{index: 3, vector: unit(0)}],
      List.replace_at(good, 2, %{index: 0, vector: unit(2)}),
      List.replace_at(good, 2, %{index: -1, vector: unit(2)}),
      List.replace_at(good, 2, %{index: 1.0, vector: unit(2)}),
      List.replace_at(good, 2, %{index: "2", vector: unit(2)}),
      List.replace_at(good, 1, %{index: 1, vector: [1.0, 0.0, 0.0]}),
      List.replace_at(good, 1, %{index: 1, vector: [1.0, 0.0, 0.0, 0.0, 0.0]}),
      List.replace_at(good, 1, %{index: 1, vector: [1.0, nil, 0.0, 0.0]}),
      List.replace_at(good, 1, %{index: 1, vector: [1.0, "0", 0.0, 0.0]}),
      List.replace_at(good, 1, %{index: 1, vector: [3.5e38, 0.0, 0.0, 0.0]}),
      List.replace_at(good, 1, %{index: 1, vector: "base64=="}),
      List.replace_at(good, 1, %{vector: unit(1)}),
      []
    ]

    for {items, i} <- Enum.with_index(bad) do
      c = config(respond: fn req -> {:ok, {:raw, TestHelper.raw(items, req.model)}} end)
      {_, _, _, delivery} = dispatch(c, request(%{"inputs" => ["a", "b", "c"]}), ctx, "bad-#{i}")
      assert {:outcome, _, {:unknown, :malformed_response}} = delivery, inspect(items)
    end

    # Served model must equal the requested one (amendment B1); absent or empty is malformed.
    for model <- ["test-embed-v2", "", nil, 7] do
      c = config(respond: fn _ -> {:ok, {:raw, TestHelper.raw(good, model)}} end)

      {_, _, _, delivery} =
        dispatch(c, request(%{"inputs" => ["a", "b", "c"]}), ctx, "m-#{inspect(model)}")

      assert {:outcome, _, {:unknown, :malformed_response}} = delivery
    end

    # Invalid usage or a non-map decode is malformed too.
    for raw <- [%{TestHelper.raw(good) | usage: %{}}, :nope] do
      c = config(respond: fn _ -> {:ok, {:raw, raw}} end)

      {_, _, _, delivery} =
        dispatch(
          c,
          request(%{"inputs" => ["a", "b", "c"]}),
          ctx,
          "u-#{inspect(raw) |> byte_size()}"
        )

      assert {:outcome, _, {:unknown, :malformed_response}} = delivery
    end

    # Reversed indices and integer elements: reordered by the validated index, floats out.
    items = [
      %{index: 2, vector: [0, 0, 1, 0]},
      %{index: 0, vector: unit(0)},
      %{index: 1, vector: unit(1)}
    ]

    c = config(respond: fn req -> {:ok, {:raw, TestHelper.raw(items, req.model)}} end)
    {_, _, _, delivery} = dispatch(c, request(%{"inputs" => ["a", "b", "c"]}), ctx, "rev")
    assert {:outcome, _, {:completed, body}} = delivery
    assert body.embeddings == for(i <- 0..2, do: %{index: i, vector: unit(i)})
    assert Enum.all?(body.embeddings, fn e -> Enum.all?(e.vector, &is_float/1) end)
  end

  test "I3 the fixed norm tolerance: within 1.0e-3 is unit_l2_verified, beyond it completes with normalization none (Adapter + Descriptor)",
       ctx do
    assert Descriptor.tolerance() == 1.0e-3

    cases = [
      {[1.0009, 0.0, 0.0, 0.0], :unit_l2_verified},
      {[0.9991, 0.0, 0.0, 0.0], :unit_l2_verified},
      {[1.0011, 0.0, 0.0, 0.0], :none},
      {[0.9989, 0.0, 0.0, 0.0], :none},
      {[0.6, 0.8, 0.0, 0.0], :unit_l2_verified},
      {[0.0, 0.0, 0.0, 0.0], :none}
    ]

    for {{v, expected}, i} <- Enum.with_index(cases) do
      items = [%{index: 0, vector: unit(0)}, %{index: 1, vector: v}]
      c = config(respond: fn req -> {:ok, {:raw, TestHelper.raw(items, req.model)}} end)
      {_, _, _, delivery} = dispatch(c, request(%{"inputs" => ["a", "b"]}), ctx, "n-#{i}")
      assert {:outcome, _, {:completed, body}} = delivery
      assert body.descriptor.normalization == expected, inspect(v)
      assert length(body.embeddings) == 2
    end

    # The tolerance is not a setting.
    assert {:error, :configuration} =
             AiEmbedding.configure(
               binding: Elzoo.AiEmbedding.TestBinding,
               tenant: "t",
               provider: Elzoo.AiEmbedding.TestProvider,
               credentials: fn -> {:ok, @secret} end,
               models: ["test-embed"],
               sink: fn _, _ -> :ok end,
               norm_tolerance: 0.1
             )
  end

  test "I3 requested dimensions are the expected vector length; the native one otherwise (Adapter)",
       ctx do
    two = [%{index: 0, vector: [0.6, 0.8]}]
    c = config(respond: fn req -> {:ok, {:raw, TestHelper.raw(two, req.model)}} end)
    {_, _, _, delivery} = dispatch(c, request(%{"dimensions" => 2}), ctx, "d2")
    assert {:outcome, _, {:completed, %{descriptor: %{dimensions: 2}}}} = delivery
    {_, _, _, delivery} = dispatch(c, request(), ctx, "d-native")
    assert {:outcome, _, {:unknown, :malformed_response}} = delivery
  end

  ## I4 retries

  test "I4 retries: only the attested no-send credential failure is redispatched; throttled and overloaded are not; unknown never (RetryTimeout policy + owner)",
       ctx do
    {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 3, base_backoff_ms: 10)
    counter = :counters.new(1, [])

    need = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) < 3, do: {:error, :vault_down}, else: {:ok, @secret}
    end

    c = config(credentials: need)
    {:ok, a} = admit(c, request())
    pid = owner(c, a, ctx)

    for attempt <- 1..2 do
      {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      settled(pid)
      key = a.key
      assert_receive {AiEmbedding, ^key, {:outcome, _, {:refused, :credentials_unavailable, _}}}

      assert {:retry, 10 * Integer.pow(2, attempt - 1)} ==
               Retry.next(policy, attempt, :credentials_unavailable)

      assert {:ok, _} = Intent.advance(pid, :rearm)
    end

    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert {:Confirmed, 3} = settled(pid).phase
    assert calls() == 1
    assert {:stop, :settle} = Retry.next(policy, 3, :completed)
    assert {:stop, :exhausted} = Retry.next(policy, 3, :credentials_unavailable)

    assert {:stop, :deadline} =
             Retry.next(policy, 1, :credentials_unavailable, now_ms: 95, deadline_ms: 100)

    for tag <- [:throttled, :overloaded] do
      c = config(respond: fn _ -> {:ok, {:status, tag, %{retry_after: 7}}} end)
      {pid, _a, _status, delivery} = dispatch(c, request(), ctx, "t-#{tag}")
      assert {:outcome, _, {:refused, ^tag, %{retry_after: 7}}} = delivery
      assert {:stop, :unresolved} = Retry.next(policy, 1, tag)
      assert {:error, _} = Intent.advance(pid, :rearm)
      assert {:error, _} = Intent.advance(pid, :dispatch)
      assert calls() == 1
    end

    for tag <- [:timeout, :transport, :provider_error, :malformed_response] do
      assert {:stop, :unresolved} = Retry.next(policy, 1, tag)
    end

    for tag <- [:provider_invalid_request, :authentication_failed, :not_found] do
      assert {:stop, :permanent} = Retry.next(policy, 1, tag)
    end

    {:ok, idempotent} = Elzoo.RetryTimeout.policy(max_attempts: 3, mode: :redispatch_idempotent)

    for tag <- [:throttled, :overloaded, :timeout, :transport, :provider_error, :malformed_response] do
      assert {:stop, :unresolved} = Retry.next(idempotent, 1, tag), inspect(tag)
    end

    assert {:retry, _} = Retry.next(idempotent, 1, :credentials_unavailable)
  end

  ## I5 one identity, one send

  test "I5 a second dispatch of the same identity is refused; re-admission recovers the same key (EffectIntent owner)",
       ctx do
    c = config(respond: fn _ -> {:transport, :timeout} end)
    {pid, a, _status, delivery} = dispatch(c, request(), ctx)
    assert {:outcome, _, {:unknown, :timeout}} = delivery
    assert {:error, _} = Intent.advance(pid, :dispatch)
    assert {:error, _} = Intent.advance(pid, :rearm)
    assert calls() == 1
    {:ok, again} = admit(c, request())
    assert again.key == a.key
    {:ok, other} = admit(c, request(), "req-2")
    refute other.key == a.key
  end

  ## I6 classification table

  test "I6 the Binding table equals the Cure decision; only credentials_unavailable is attested no-send (decision + binding)" do
    assert Outcome.verify()
    {:ok, b} = Elzoo.AiEmbedding.Binding.load(Elzoo.AiEmbedding.TestBinding)
    assert b.no_send_attestations == [:credentials_unavailable]
    assert b.operation == "embed"

    expected = %{
      credentials_unavailable:
        {{:refused, :credentials_unavailable}, {"timed_out", "not_dispatched", "unavailable"}},
      provider_invalid_request:
        {{:refused, :invalid_request}, {"failed", "dispatched", "permanent"}},
      provider_too_large: {{:refused, :too_large}, {"failed", "dispatched", "permanent"}},
      authentication_failed:
        {{:refused, :authentication_failed}, {"failed", "dispatched", "permanent"}},
      permission_denied: {{:refused, :permission_denied}, {"failed", "dispatched", "permanent"}},
      not_found: {{:refused, :not_found}, {"failed", "dispatched", "permanent"}},
      throttled: {{:refused, :throttled}, {"failed", "dispatched", "retryable"}},
      overloaded: {{:refused, :overloaded}, {"failed", "dispatched", "retryable"}},
      provider_error: {{:unknown, :provider_error}, {"unknown", "dispatched", "unclassified"}},
      provider_timeout: {{:unknown, :timeout}, {"timed_out", "unknown", "unclassified"}},
      timeout: {{:unknown, :timeout}, {"timed_out", "unknown", "unclassified"}},
      transport: {{:unknown, :transport}, {"unknown", "unknown", "unclassified"}},
      malformed_response:
        {{:unknown, :malformed_response}, {"unknown", "dispatched", "unclassified"}},
      adapter_error: {{:unknown, :provider_error}, {"unknown", "unknown", "unclassified"}}
    }

    assert Enum.sort(Map.keys(expected)) == Enum.sort(Outcome.tags())

    for {tag, {contract, triple}} <- expected do
      assert {:ok, ^contract} = AiEmbedding.outcome(tag)
      assert {:ok, ^triple} = Outcome.delivery(tag)
      assert Outcome.failures()[tag] == triple
    end

    assert :error = AiEmbedding.outcome(:nonsense)
  end

  test "I6 a provider tag outside its set and a raising provider are unknown; the envelope validates and authenticates (Adapter)",
       ctx do
    cases = [
      {fn _ -> {:ok, {:status, :credentials_unavailable}} end, {:unknown, :provider_error}},
      {fn _ -> raise "boom #{@secret}" end, {:unknown, :provider_error}}
    ]

    for {{respond, expected}, i} <- Enum.with_index(cases) do
      c = config(respond: respond)
      {_pid, _a, _s, delivery} = dispatch(c, request(), ctx, "m-#{i}")
      assert {:outcome, _, ^expected} = delivery
      refute inspect(delivery) =~ @secret
    end

    c = config()
    {:ok, a} = admit(c, request())

    req = %{
      context: c,
      key: a.key,
      attempt_id: "att-1",
      arguments: a.arguments,
      binding: Elzoo.AiEmbedding.TestBinding.__effect_intent_binding__().digest
    }

    envelope = Adapter.send_effect(req)
    assert envelope["value"] |> Map.keys() |> Enum.sort() == ["outcome_digest", "seal"]
    assert :ok == Adapter.validate_result(envelope, req)
    assert :ok == Adapter.authenticate(envelope, req)
    forged = put_in(envelope, ["value", "outcome_digest"], String.duplicate("0", 64))
    assert :error == Adapter.authenticate(forged, req)
    assert :ok == Adapter.validate(a.arguments, Adapter.schema())
    assert {:error, :schema} == Adapter.validate(a.arguments <> " ", Adapter.schema())
  end

  ## I7 sink, descriptor, configuration and redaction

  test "I7 a failing sink never changes classification or settlement; the caller is told sink_failed (Adapter + sink)",
       ctx do
    parent = self()

    sinks = [
      fn _, {:outcome, _, _} -> raise "sink down" end,
      fn _, {:outcome, _, _} -> throw(:x) end,
      fn _, {:outcome, _, _} -> exit(:x) end,
      fn _, {:outcome, _, _} -> :error end
    ]

    for {fail, i} <- Enum.with_index(sinks) do
      sink = fn
        key, {:sink_failed, _} = d ->
          send(parent, {AiEmbedding, key, d})
          :ok

        key, d ->
          fail.(key, d)
      end

      c = config(sink: sink)
      {_pid, _a, status, delivery} = dispatch(c, request(), ctx, "s-#{i}")
      assert {:sink_failed, _} = delivery
      assert {:Confirmed, 1} = status.phase
    end
  end

  test "I7 descriptors are compatible only when all five fields are equal (Descriptor)" do
    d = %{
      provider: "openai",
      model: "m",
      dimensions: 8,
      dtype: :float32,
      normalization: :unit_l2_verified
    }

    assert Descriptor.compatible?(d, d)

    for {k, v} <- [provider: "other", model: "m2", dimensions: 9, normalization: :none] do
      refute Descriptor.compatible?(d, Map.put(d, k, v)), inspect(k)
    end

    refute Descriptor.compatible?(d, %{d | dtype: :int8})
    refute Descriptor.compatible?(Map.put(d, :extra, 1), Map.put(d, :extra, 1))
    assert {:error, :descriptor} = Descriptor.validate(%{d | dimensions: 0})
  end

  test "I7 configuration is fixed and validated; Config inspect, errors and status carry no credential or input (configure, Inspect)" do
    good = [
      binding: Elzoo.AiEmbedding.TestBinding,
      tenant: "tenant-a",
      provider: Elzoo.AiEmbedding.TestProvider,
      credentials: fn -> {:ok, @secret} end,
      models: ["test-embed"],
      sink: fn _, _ -> :ok end
    ]

    assert {:ok, c} = AiEmbedding.configure(good)

    assert {c.max_inputs, c.max_input_bytes, c.max_request_bytes, c.receive_timeout_ms} ==
             {128, 32_768, 65_536, 60_000}

    refute inspect(c) =~ @secret

    bad = [
      Keyword.put(good, :models, ["undeclared-model"]),
      Keyword.put(good, :models, []),
      Keyword.put(good, :max_inputs, 0),
      Keyword.put(good, :max_inputs, 2049),
      Keyword.put(good, :max_input_bytes, 65_537),
      Keyword.put(good, :max_request_bytes, 65_537),
      Keyword.put(good, :max_request_bytes, 0),
      Keyword.put(good, :receive_timeout_ms, 600_001),
      Keyword.put(good, :binding, Elzoo.AiEmbeddingTest),
      Keyword.put(good, :provider, Elzoo.AiEmbeddingTest),
      Keyword.put(good, :credentials, @secret),
      Keyword.put(good, :unknown, 1),
      Keyword.delete(good, :tenant)
    ]

    for opts <- bad, do: assert({:error, :configuration} = AiEmbedding.configure(opts))
  end

  test "I7 credential and input text never appear in results, errors, inspect or logs (all returns)",
       ctx do
    import ExUnit.CaptureLog

    log =
      capture_log([level: :debug], fn ->
        for {respond, i} <-
              Enum.with_index([
                &default_respond/1,
                fn _ -> {:transport, :timeout} end,
                fn _ -> raise @text end
              ]) do
          c = config(respond: respond)
          {pid, _a, status, delivery} = dispatch(c, request(), ctx, "red-#{i}")

          for v <- [inspect(delivery, limit: :infinity), inspect(status), inspect(c)],
              do: refute(v =~ @secret or v =~ @text)

          refute inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity) =~
                   @secret
        end
      end)

    refute log =~ @secret
    refute log =~ @text
    drain()
  end

  ## Request codec and the batch-size example

  test "request codec: canonical bytes, defaults and normalization (Request)" do
    {:ok, r, canonical} =
      Request.decode(
        ~s({ "model": "m", "inputs": ["a\\nb", "é"], "version": 1, "input_type": "query" })
      )

    assert canonical == ~s({"input_type":"query","inputs":["a\\nb","é"],"model":"m","version":1})

    assert r == %{
             model: "m",
             inputs: ["a\nb", "é"],
             dimensions: nil,
             input_type: :query,
             provider_options: %{}
           }

    assert {:error, :too_large} = Request.decode(String.duplicate(" ", 1_048_577))

    assert {:error, :too_large} =
             Request.decode(Request.canonical(request(%{"inputs" => List.duplicate("a", 2049)})))

    assert {:error, :invalid_request} = Request.decode("[]")

    assert {:error, :invalid_request} =
             Request.decode(
               ~s({"version":1,"model":"m","inputs":["a"],"provider_options":{"a":1,"a":2}})
             )
  end

  # How many chunks of `graphemes` graphemes of `char` fit in one call: the largest k
  # whose canonical payload (model text-embedding-3-small, no other member) is at
  # most 65,536 bytes. The Piece README quotes these numbers for index writers.
  defp fit(char, graphemes) do
    chunk = String.duplicate(char, graphemes)

    Enum.reduce_while(1..2048, 0, fn k, _ ->
      req = %{
        "version" => 1,
        "model" => "text-embedding-3-small",
        "inputs" => List.duplicate(chunk, k)
      }

      if byte_size(Request.canonical(req)) <= 65_536, do: {:cont, k}, else: {:halt, k - 1}
    end)
  end

  test "batch-size example: 2,000-grapheme chunks per call under the 65,536-byte payload bound (Request.canonical)" do
    base = Request.canonical(%{"version" => 1, "model" => "text-embedding-3-small", "inputs" => []})
    assert byte_size(base) == 58
    # ASCII without escapes: 2,003 bytes per chunk (two quotes, one comma).
    assert fit("a", 2000) == 32
    # Four-byte UTF-8 text (for example emoji): 8,003 bytes per chunk.
    assert fit("😀", 2000) == 8
    # Three-byte UTF-8 text (most CJK): 6,003 bytes per chunk.
    assert fit("漢", 2000) == 10
    # Every newline costs two bytes once escaped.
    assert fit("\n", 2000) == 16
  end

  ## I8 source audit

  @layouts [
    {Path.expand("../..", __DIR__), Path.expand("../../piece.json", __DIR__)},
    {Path.expand("../..", __DIR__),
     Path.expand("../../.elzoo/pieces/integration/ai-embedding/piece.json", __DIR__)}
  ]

  defp own_files do
    case Enum.filter(@layouts, fn {_, manifest} -> File.regular?(manifest) end) do
      [{root, manifest}] ->
        files = Jason.decode!(File.read!(manifest))["files"]
        assert "lib/elzoo/ai_embedding.ex" in files
        {root, files}

      found ->
        flunk("expected exactly one integration/ai-embedding manifest, found #{length(found)}")
    end
  end

  test "I8 the interface's own files reference no provider library, text Piece or provider Piece (source audit of the listed files)" do
    {root, files} = own_files()
    # Built by concatenation so this file does not contain the names it forbids.
    forbidden = [
      "Req" <> "LLM",
      "req" <> "_llm",
      "Pl" <> "ug",
      "Req" <> ".",
      "Ai" <> "Text",
      "AiEmbedding." <> "OpenAI",
      "llm" <> "_db",
      "LL" <> "MDB"
    ]

    for file <- files, not String.starts_with?(file, "test/") do
      source = File.read!(Path.join(root, file))
      for word <- forbidden, do: refute(source =~ word, "#{file} references #{word}")
    end
  end
end
