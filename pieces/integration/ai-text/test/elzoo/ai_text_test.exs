# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_text_test_helper.exs", __DIR__)

defmodule Elzoo.AiTextTest do
  # Interface scenarios with a scripted test provider; each names its boundary.
  # The EffectIntent owner runs on the volatile Memory store (no database).
  use ExUnit.Case, async: false

  alias Elzoo.AiText
  alias Elzoo.AiText.{Adapter, Conformance, Outcome, Request, Retry, Sink, TestHelper}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @secret "sk-test-SECRET-k91"
  @prompt "prompt-SECRET-p33"

  setup do
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent)}
  end

  ## helpers

  defp request(extra \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "model" => "test-model",
        "messages" => [%{"role" => "user", "text" => @prompt}],
        "max_output_tokens" => 64
      },
      extra
    )
  end

  defp config(opts \\ []) do
    parent = self()
    respond = Keyword.get(opts, :respond, fn _ -> {:ok, {:raw, TestHelper.raw()}} end)

    base = [
      binding: Elzoo.AiText.TestBinding,
      tenant: "tenant-a",
      provider: Keyword.get(opts, :provider, Elzoo.AiText.TestProvider),
      provider_config: %{parent: parent, respond: respond},
      credentials: Keyword.get(opts, :credentials, fn -> {:ok, @secret} end),
      models: ["test-model"],
      max_output_tokens: 1000,
      sink: Keyword.get(opts, :sink, Sink.to_pid(parent))
    ]

    {:ok, c} = AiText.configure(base)
    c
  end

  defp admit(c, req, ref \\ "req-1"),
    do: AiText.admission(c, Conformance.declaration(req, ref, 10_000))

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
    assert_receive {AiText, ^key, delivery}, 2000
    {pid, a, status, delivery}
  end

  defp calls do
    receive do
      {:call, _, _} -> 1 + calls()
    after
      50 -> 0
    end
  end

  ## I1 call path

  test "I1 completed call through admission, EffectIntent owner and Adapter; content reaches only the sink (owner + Adapter)",
       ctx do
    c = config()
    {pid, a, status, delivery} = dispatch(c, request(), ctx)
    assert {:outcome, attempt_id, {:completed, body}} = delivery
    assert is_binary(attempt_id)
    assert body.content == "hello"
    assert body.finish == :stop
    assert body.provenance.response_id == "resp_1"
    assert body.provenance.request_id == "req_1"

    assert body.provenance.model_ref == %{
             provider: "test",
             model_id: "test-model",
             wire_surface: "scripted"
           }

    assert body.provenance.provider_piece == "test/ai-text-provider"
    assert {:Confirmed, 1} = status.phase
    assert_received {:call, @secret, 120_000}
    # Model output never in the owner's state or status (the request arguments are
    # EffectIntent's classified durable data by its Contract; status omits them).
    state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
    refute state =~ "hello"
    refute inspect(status) =~ "hello"
    refute inspect(status) =~ @prompt
    assert byte_size(a.arguments) > 0
  end

  ## I2 local refusals before any intent, credential or call

  test "I2 local refusals return before an intent exists, the credential Need runs or the provider is called (admission)" do
    parent = self()

    c =
      config(
        credentials: fn ->
          send(parent, :credential_read)
          {:ok, @secret}
        end
      )

    refusals = [
      {request(%{"model" => "other-model"}), :invalid_request},
      {request(%{"max_output_tokens" => 5000}), :invalid_request},
      {request(%{"messages" => [%{"role" => "user", "text" => "x", "image" => "data"}]}),
       :unsupported_feature},
      {request(%{"tools" => [%{"type" => "web_search", "name" => "web"}]}), :unsupported_feature},
      {request(%{"reasoning" => "max"}), :unsupported_feature},
      {request(%{
         "cache_hint" => %{
           "tenant" => "tenant-b",
           "local_key" => "k",
           "ttl" => "5m",
           "breakpoints" => ["system"]
         }
       }), :invalid_request},
      {request(%{
         "cache_hint" => %{
           "tenant" => "tenant-a",
           "local_key" => "k",
           "ttl" => "1h",
           "breakpoints" => ["system"]
         }
       }), :unsupported_feature},
      {request(%{"output_schema" => %{"$ref" => "https://example.test/schema.json"}}),
       :invalid_request},
      {request(%{"messages" => [%{"role" => "user", "text" => String.duplicate("x", 70_000)}]}),
       :too_large}
    ]

    for {req, reason} <- refusals do
      assert {:error, {:refused, ^reason}} = admit(c, req), inspect(reason)
    end

    refute_received :credential_read
    refute_received {:call, _, _}

    # Sampling is an optional feature: a provider that does not declare it refuses it.
    c2 = config(provider: Elzoo.AiText.TestProviderNoSampling)

    assert {:error, {:refused, :unsupported_feature}} =
             admit(c2, request(%{"sampling" => %{"temperature" => 0.2}}))

    assert {:ok, _} = admit(c, request(%{"sampling" => %{"temperature" => 0.2}}))
    refute_received :credential_read
  end

  test "I2 malformed declarations and payloads (admission)" do
    c = config()
    decl = Conformance.declaration(request(), "r", 10_000)
    assert {:error, :declaration} = AiText.admission(c, put_in(decl, ["classification"], "trusted"))
    assert {:error, :declaration} = AiText.admission(c, put_in(decl, ["operation"], "chat"))
    assert {:error, :declaration} = AiText.admission(c, put_in(decl, ["command", "schema_id"], "x"))

    bad = put_in(decl, ["command", "payload"], ~s({"version":1,"version":1}))
    assert {:error, {:refused, :invalid_request}} = AiText.admission(c, bad)
    unknown = put_in(decl, ["command", "payload"], Jason.encode!(Map.put(request(), "extra", 1)))
    assert {:error, {:refused, :invalid_request}} = AiText.admission(c, unknown)
  end

  ## I3 provider options

  test "I3 provider options: undeclared key and invalid value refused, declared value reaches translate; fixed settings are not options (admission)" do
    c = config()

    assert {:error, {:refused, :invalid_request}} =
             admit(c, request(%{"provider_options" => %{"undeclared" => true}}))

    assert {:error, {:refused, :invalid_request}} =
             admit(c, request(%{"provider_options" => %{"flavour" => "loud"}}))

    for fixed <- ["api_key", "anthropic_version", "max_retries", "receive_timeout"] do
      assert {:error, {:refused, :invalid_request}} =
               admit(c, request(%{"provider_options" => %{fixed => "x"}}))
    end

    assert {:ok, _} = admit(c, request(%{"provider_options" => %{"flavour" => "plain"}}))
    assert_received {:translate, %{"flavour" => "plain"}}

    # The provider's own translate refusal is returned, never ignored.
    assert {:error, {:refused, :unsupported_feature}} =
             admit(
               c,
               request(%{
                 "provider_options" => %{"flavour" => "terse"},
                 "tools" => [Enum.at(Conformance.request(:tool_well_formed, "m")["tools"], 0)]
               })
             )
  end

  ## I4 retries

  test "I4 retries: only the attested no-send credential failure is redispatched; throttled and overloaded are not; unknown never (RetryTimeout policy + owner)",
       ctx do
    {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 3, base_backoff_ms: 10)

    # Credential Need fails twice, then succeeds: three dispatches, one provider call.
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
      assert_receive {AiText, ^key, {:outcome, _, {:refused, :credentials_unavailable, _}}}

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

    # Throttled (429-like) and overloaded: failed/dispatched/retryable, not redispatched.
    for tag <- [:throttled, :overloaded] do
      c = config(respond: fn _ -> {:ok, {:status, tag, %{retry_after: 7}}} end)
      {pid, _a, _status, delivery} = dispatch(c, request(), ctx, "t-#{tag}")
      assert {:outcome, _, {:refused, ^tag, %{retry_after: 7}}} = delivery
      assert {:stop, :unresolved} = Retry.next(policy, 1, tag)
      assert {:error, _} = Intent.advance(pid, :rearm)
      assert {:error, _} = Intent.advance(pid, :dispatch)
      assert calls() == 1
    end

    # Unknown outcomes are never retried.
    for tag <- [:timeout, :transport, :provider_error, :malformed_response] do
      assert {:stop, :unresolved} = Retry.next(policy, 1, tag)
    end

    for tag <- [:provider_invalid_request, :authentication_failed, :not_found] do
      assert {:stop, :permanent} = Retry.next(policy, 1, tag)
    end
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
    {:ok, b} = Elzoo.AiText.Binding.load(Elzoo.AiText.TestBinding)
    assert b.no_send_attestations == [:credentials_unavailable]

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
      assert {:ok, ^contract} = AiText.outcome(tag)
      assert {:ok, ^triple} = Outcome.delivery(tag)
      assert Outcome.failures()[tag] == triple
    end

    assert :error = AiText.outcome(:nonsense)
  end

  test "I6 a provider tag outside its set, a raising provider and a malformed completion are unknown (Adapter)",
       ctx do
    cases = [
      {fn _ -> {:ok, {:status, :credentials_unavailable}} end, {:unknown, :provider_error}},
      {fn _ -> raise "boom #{@secret}" end, {:unknown, :provider_error}},
      {fn _ -> {:ok, {:raw, Map.delete(TestHelper.raw(), :response_id)}} end,
       {:unknown, :malformed_response}},
      {fn _ -> {:ok, {:raw, %{TestHelper.raw() | finish: :weird}}} end,
       {:unknown, :malformed_response}},
      {fn _ -> {:ok, {:raw, %{TestHelper.raw() | usage: %{}}}} end, {:unknown, :malformed_response}}
    ]

    for {{respond, expected}, i} <- Enum.with_index(cases) do
      c = config(respond: respond)
      {_pid, _a, _s, delivery} = dispatch(c, request(), ctx, "m-#{i}")
      assert {:outcome, _, ^expected} = delivery
      refute inspect(delivery) =~ @secret
    end
  end

  ## I7 sink failures

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
          send(parent, {AiText, key, d})
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

  ## Tool proposals and structured output are checked by the interface

  test "tool proposals are data: malformed ones are marked, never dropped or repaired; structured output is validated (Adapter)",
       ctx do
    tools = Conformance.request(:tool_well_formed, "test-model")["tools"]

    calls = [
      %{id: "t1", name: "lookup", arguments_json: ~s({"q":"x"})},
      %{id: "t2", name: "lookup", arguments_json: ~s({"q":)},
      %{id: "t3", name: "lookup", arguments_json: ~s({"q":5})},
      %{id: "t4", name: "lookup", arguments_json: ~s(["q"])},
      %{id: "t5", name: "unknown_tool", arguments_json: ~s({"q":"x"})}
    ]

    c =
      config(
        respond: fn _ ->
          {:ok, {:raw, TestHelper.raw("", %{tool_calls: calls, finish: :tool_calls})}}
        end
      )

    {_, _, _, {:outcome, _, {:completed, body}}} = dispatch(c, request(%{"tools" => tools}), ctx)

    assert [
             %{id: "t1", arguments: %{"q" => "x"}, malformed: nil},
             %{id: "t2", arguments: nil, malformed: :invalid_json, raw_arguments: ~s({"q":)},
             %{id: "t3", arguments: nil, malformed: :schema_mismatch},
             %{id: "t4", arguments: nil, malformed: :not_an_object},
             %{id: "t5", arguments: nil, malformed: :undeclared_tool}
           ] = body.tool_proposals

    schema = Conformance.request(:structured_valid, "test-model")["output_schema"]

    for {json, expected, i} <- [
          {~s({"answer":42}), {:valid, %{"answer" => 42}}, 1},
          {~s({"answer":"x"}), {:invalid, :schema_mismatch}, 2},
          {~s({"answer":), {:invalid, :invalid_json}, 3},
          {nil, {:invalid, :missing}, 4}
        ] do
      c = config(respond: fn _ -> {:ok, {:raw, TestHelper.raw("", %{structured_json: json})}} end)

      {_, _, _, {:outcome, _, {:completed, body}}} =
        dispatch(c, request(%{"output_schema" => schema}), ctx, "o-#{i}")

      assert body.structured == expected
    end
  end

  ## Request codec

  test "request codec: canonical bytes, duplicate keys, unknown members, roles and bounds (Request)" do
    {:ok, r, canonical} = Request.decode(Jason.encode!(request(%{"reasoning" => "low"})))
    assert r.reasoning == :low
    assert r.tool_choice == :auto
    assert {:ok, ^r, ^canonical} = Request.decode(canonical)
    assert :ok = Adapter.validate(canonical, Adapter.schema())

    assert {:error, :schema} =
             Adapter.validate(Jason.encode!(request(), pretty: true), Adapter.schema())

    assert {:error, :invalid_request} = Request.decode(~s({"version":1,"version":2}))
    assert {:error, :invalid_request} = Request.decode("not json")
    assert {:error, :invalid_request} = Request.decode(<<0xFF>>)
    assert {:error, :too_large} = Request.decode(Jason.encode!(request()), 10)

    bad_messages = [
      [],
      [%{"role" => "robot", "text" => "x"}],
      [%{"role" => "user"}],
      [%{"role" => "tool_result", "text" => "x"}],
      [
        %{
          "role" => "assistant",
          "text" => "",
          "tool_calls" => [%{"id" => "a", "name" => "bad name", "arguments" => %{}}]
        }
      ]
    ]

    for m <- bad_messages,
        do:
          assert(
            {:error, :invalid_request} = Request.decode(Jason.encode!(request(%{"messages" => m})))
          )

    ok =
      request(%{
        "messages" => [
          %{"role" => "system", "text" => "s"},
          %{"role" => "user", "text" => "u"},
          %{
            "role" => "assistant",
            "text" => "",
            "tool_calls" => [%{"id" => "a", "name" => "lookup", "arguments" => %{"q" => "x"}}]
          },
          %{"role" => "tool_result", "tool_use_id" => "a", "text" => "result", "is_error" => false}
        ],
        "tool_choice" => %{"type" => "tool", "name" => "lookup"},
        "stop_sequences" => ["END"],
        "sampling" => %{"temperature" => 0.5, "top_p" => 0.9},
        "cache_hint" => %{
          "tenant" => "t",
          "local_key" => "k",
          "ttl" => "5m",
          "breakpoints" => ["tools", %{"message" => 1}]
        }
      })

    assert {:ok, r, _} = Request.decode(Jason.encode!(ok))
    assert r.tool_choice == {:tool, "lookup"}
    assert r.cache_hint.breakpoints == [:tools, {:message, 1}]
    assert r.sampling == %{temperature: 0.5, top_p: 0.9}
  end

  ## Configuration and redaction

  test "configuration is fixed and validated; Config inspect, errors and status carry no credential or prompt (configure, Inspect)",
       ctx do
    c = config()
    refute inspect(c) =~ @secret
    assert {:error, :configuration} = AiText.configure(binding: Elzoo.AiText.TestBinding)
    assert {:error, :configuration} = AiText.configure([])
    assert {:error, :configuration} = AiText.configure(:nope)

    for bad <- [
          [models: []],
          [max_request_bytes: 70_000],
          [receive_timeout_ms: 0],
          [credentials: "not a function"],
          [unknown: 1]
        ] do
      opts =
        Keyword.merge(
          [
            binding: Elzoo.AiText.TestBinding,
            tenant: "t",
            provider: Elzoo.AiText.TestProvider,
            credentials: fn -> {:ok, "k"} end,
            models: ["m"],
            sink: fn _, _ -> :ok end
          ],
          bad
        )

      assert {:error, :configuration} = AiText.configure(opts), inspect(Keyword.keys(bad))
    end

    for {need, i} <-
          Enum.with_index([
            fn -> {:error, @secret} end,
            fn -> raise "vault #{@secret}" end,
            fn -> {:ok, @secret <> " "} end,
            fn -> {:ok, String.duplicate("k", 1025)} end,
            fn -> {:ok, :atom} end,
            fn -> @secret end
          ]) do
      c = config(credentials: need)
      {pid, _a, status, delivery} = dispatch(c, request(), ctx, "n-#{i}")
      assert {:outcome, _, {:refused, :credentials_unavailable, %{retry_after: nil}}} = delivery
      assert calls() == 0

      text =
        inspect({delivery, status, :sys.get_state(pid)},
          limit: :infinity,
          printable_limit: :infinity
        )

      refute text =~ @secret
      refute inspect({delivery, status}) =~ @prompt
    end
  end

  ## Source audit: the interface loads no provider dependency

  # This Piece's own files exactly as its manifest lists them (never the consumer's
  # whole lib/, which also holds other Pieces' files in an export). In this repository
  # the manifest sits two levels above this file; in an exported consumer this file
  # lands in test/elzoo/ and the manifest in .elzoo/pieces/integration/ai-text/. Exactly
  # one must exist, so a missing manifest is never skipped.
  @layouts [
    {Path.expand("../..", __DIR__), Path.expand("../../piece.json", __DIR__)},
    {Path.expand("../..", __DIR__),
     Path.expand("../../.elzoo/pieces/integration/ai-text/piece.json", __DIR__)}
  ]

  defp own_files do
    case Enum.filter(@layouts, fn {_, manifest} -> File.regular?(manifest) end) do
      [{root, manifest}] ->
        files = Jason.decode!(File.read!(manifest))["files"]
        assert "lib/elzoo/ai_text.ex" in files
        {root, files}

      found ->
        flunk("expected exactly one integration/ai-text manifest, found #{length(found)}")
    end
  end

  test "the interface's own files reference no provider library or provider Piece (source audit of the listed files)" do
    {root, files} = own_files()
    # Built by concatenation so this file does not contain the names it forbids.
    forbidden = [
      "Req" <> "LLM",
      "req" <> "_llm",
      "Pl" <> "ug",
      "Req" <> ".Test",
      "AiText." <> "Anthropic",
      "llm" <> "_db"
    ]

    for file <- files do
      source = File.read!(Path.join(root, file))
      for word <- forbidden, do: refute(source =~ word, "#{file} references #{word}")
    end
  end
end
