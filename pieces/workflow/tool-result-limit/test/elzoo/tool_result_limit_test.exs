# SPDX-License-Identifier: Apache-2.0
artifact_helper = Path.expand("../support/artifact_test_helper.exs", __DIR__)

artifact_helper =
  if File.regular?(artifact_helper),
    do: artifact_helper,
    else:
      Path.expand(
        "../../../../state/artifact/test/support/artifact_test_helper.exs",
        __DIR__
      )

Code.require_file(artifact_helper)

defmodule Elzoo.ToolResultLimitTest.Binding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.ToolResultLimit.Adapter,
    id: "tool-result-store",
    provider_account: "artifact-store",
    operation: "put",
    clock: "unix-ms",
    failures: Elzoo.ToolResultLimit.Adapter.failures(),
    no_send_attestations: Elzoo.ToolResultLimit.Adapter.no_send()
end

defmodule Elzoo.ToolResultLimitTest do
  @moduledoc """
  The six acceptance groups of `workflow/tool-result-limit` on the Memory Store
  of `state/event-log`, a real `Elzoo.Artifact` over the loopback S3 double of
  `state/artifact` and a real `Elzoo.EffectIntent` owner (volatile). Finite
  scenarios, not evidence of durability or of a real object store.
  """
  use ExUnit.Case, async: false

  alias Elzoo.{Artifact, ToolResultLimit, UntrustedContent}
  alias Elzoo.Artifact.TestHelper, as: H
  alias Elzoo.DurableLog.{Memory, Store}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.ToolResultLimit.Adapter
  alias Elzoo.ToolResultLimitTest.Binding

  @max 1_024
  @limits %{max_bytes: @max, artifact_max_bytes: 100_000}
  @stream "run/r-1"
  @tenant "acme"
  @caller %{tenant: "acme", principal: "bot", scopes: []}

  # ── fixtures ─────────────────────────────────────────────────────────

  defp marked(content, opts \\ []) do
    %{
      "schema_id" => "elzoo.untrusted-content.marked",
      "schema_version" => 1,
      "sources" => Keyword.get(opts, :sources, ["mcp:files/read_file"]),
      "trust" => Keyword.get(opts, :trust, "untrusted"),
      "max_bytes" => 16_777_216,
      "content" => content
    }
  end

  defp text(content, opts \\ []),
    do: %{"content" => marked(content, opts), "media_type" => "text/plain", "encoding" => "utf8"}

  defp binary(bytes, opts \\ []),
    do: %{
      "content" => marked(Base.encode64(bytes), opts),
      "media_type" => "image/png",
      "encoding" => "base64"
    }

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp receipt(pending, id \\ String.duplicate("a", 64)),
    do: %{
      "artifact_id" => id,
      "version" => 1,
      "sha256" => pending["sha256"],
      "size_bytes" => pending["size_bytes"],
      "media_type" => pending["media_type"]
    }

  # ── log, artifact, owner ─────────────────────────────────────────────

  defp log_fold,
    do: %{
      initial: 0,
      kinds: %{"outcome" => :non_state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  @log_limits %{max_record_bytes: 131_072, max_batch_size: 4, max_checkpoint_bytes: 10_000}

  # The test record layout: the engine outcome payload holds the result under "result".
  defp extract(payload) do
    case Jason.decode(payload) do
      {:ok, %{"result" => result}} -> {:ok, result}
      _ -> :error
    end
  end

  defp record!(log, result) do
    {:ok, head} = Store.read(log, :head, [@stream])
    payload = Jason.encode!(%{"result" => result})

    {:ok, rows, request} =
      Artifact.Record.rows(
        @stream,
        head.revision,
        [{"outcome", 1, payload}],
        log_fold(),
        @log_limits
      )

    Store.write(log, :append, [@stream, head.revision, rows, []], request)
    head.revision + 1
  end

  setup do
    {:ok, log_pid} = Memory.start_link(fold: log_fold(), limits: @log_limits)
    {config, s3} = H.fake_s3()
    art = H.memory(object_store: config, max_bytes: 100_000)
    {:ok, tasks} = Task.Supervisor.start_link()
    on_exit(fn -> Process.exit(tasks, :shutdown) end)
    test = self()

    context = %{
      log: Memory.store(log_pid),
      extract: &extract/1,
      artifact: art.art,
      caller: @caller,
      access: %{tenant: @tenant, principals: :any, scopes: :any},
      access_expires_at_unix_ms: :never,
      retain_until_unix_ms: :never,
      sink: fn key, message -> send(test, {:sink, key, message}) end,
      seal_key: :crypto.strong_rand_bytes(32)
    }

    %{log: context.log, s3: s3, art: art.art, tasks: tasks, context: context}
  end

  defp owner(arguments, ctx) do
    {:ok, memory} = Memory.start_link(fold: Intent.fold(Binding), limits: Intent.limits())
    {:ok, host_memory} = Memory.start_link(fold: StoreHost.fold(), limits: StoreHost.limits())
    host = %{store: Memory.store(host_memory), authorize: fn _, _ -> :fresh end}
    d = Binding.__effect_intent_binding__()

    {:ok, pid} =
      Intent.start_link(
        binding: Binding,
        identity: [
          @tenant,
          d.provider_account,
          d.id,
          d.operation,
          "call-#{System.unique_integer([:positive])}"
        ],
        arguments: arguments,
        deadline: System.os_time(:millisecond) + 3_600_000,
        clock: fn -> System.os_time(:millisecond) end,
        store: Memory.store(memory),
        host: {StoreHost, host},
        task_supervisor: ctx.tasks,
        adapter_context: ctx.context,
        allow_volatile: true
      )

    pid
  end

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  # Records the result, runs the store action through the owner and the Adapter,
  # and returns the receipt that the sink got.
  defp store_through_owner(result, payload, ctx) do
    sequence = record!(ctx.log, result)
    {:ok, arguments} = Adapter.arguments(payload, @stream, sequence)
    pid = owner(arguments, ctx)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    eventually(fn -> Intent.status(pid).phase == {:Confirmed, 1} end)
    key = Intent.status(pid).key
    assert_receive {:sink, ^key, {:receipt, _attempt, receipt}}
    assert receipt["artifact_id"] == key
    receipt
  end

  # A direct send of one intent request; the owner builds the same request map.
  defp request(arguments, ctx) do
    %{
      key: sha("request-#{System.unique_integer([:positive])}"),
      attempt: 1,
      attempt_id: "attempt-1",
      arguments: arguments,
      arguments_digest: :crypto.hash(:sha256, arguments),
      schema: Adapter.schema(),
      binding: <<0::256>>,
      context: ctx.context
    }
  end

  defp puts(s3), do: Enum.count(H.fake_requests(s3), &match?({"put", _}, &1))

  defp assert_bounded(%{"content" => content}, full) do
    assert {:ok, checked} = UntrustedContent.decode(content)
    assert {:ok, _} = UntrustedContent.render(checked)
    assert byte_size(content["content"]) <= @max
    assert content["max_bytes"] == @max
    refute String.contains?(content["content"], full)
  end

  # ── groups ───────────────────────────────────────────────────────────

  test "under_bound_unchanged" do
    for content <- ["", "short", String.duplicate("a", @max), String.duplicate("é", 512)] do
      result = text(content)
      assert {:ok, bounded} = ToolResultLimit.decide(result, @limits, "act-1")
      assert bounded == %{"content" => result["content"], "cut" => nil}
      assert :erlang.term_to_binary(bounded["content"]) == :erlang.term_to_binary(result["content"])
    end

    # under the bound but over the Artifact bound: still whole
    assert {:ok, %{"cut" => nil}} =
             ToolResultLimit.decide(text("abc"), %{max_bytes: @max, artifact_max_bytes: 1}, "a")
  end

  test "over_bound_reference_and_preview", ctx do
    # "é" sits on bytes 511 and 512: the preview stops before it
    full = String.duplicate("a", 511) <> "é" <> String.duplicate("b", @max - 512)
    assert byte_size(full) == @max + 1
    result = text(full)

    assert {:store, pending, payload} = ToolResultLimit.decide(result, @limits, "act-2")

    assert payload == %{
             "source_action_id" => "act-2",
             "sha256" => sha(full),
             "size_bytes" => @max + 1,
             "media_type" => "text/plain",
             "encoding" => "utf8"
           }

    refute inspect(pending) =~ "é"
    receipt = store_through_owner(result, payload, ctx)

    assert {:ok, %{bytes: ^full, record: %{media_type: "text/plain"}}} =
             Artifact.get(ctx.art, @caller, receipt["artifact_id"], :head)

    assert {:ok, bounded} = ToolResultLimit.settle(pending, "completed", receipt)
    preview = String.duplicate("a", 511)

    assert bounded["content"]["content"] ==
             "[cut: first 511 of 1025 bytes shown; whole result: artifact #{receipt["artifact_id"]} version 1]\n" <>
               preview

    assert bounded["cut"] == %{
             "size_bytes" => 1025,
             "sha256" => sha(full),
             "media_type" => "text/plain",
             "preview_bytes" => 511,
             "artifact" => %{"artifact_id" => receipt["artifact_id"], "version" => 1},
             "note" => nil
           }

    assert_bounded(bounded, full)

    # a three-byte character across the cut point
    euro = String.duplicate("a", 510) <> "€" <> String.duplicate("c", 600)
    assert {:store, p, _} = ToolResultLimit.decide(text(euro), @limits, "act-3")
    assert p["content"]["content"] == String.duplicate("a", 510)

    # a result of 60,000 bytes: small intent arguments, whole bytes in the Artifact
    big = String.duplicate("0123456789", 6_000)
    assert {:store, p, payload} = ToolResultLimit.decide(text(big), @limits, "act-4")
    {:ok, arguments} = Adapter.arguments(payload, @stream, 7)
    assert byte_size(arguments) < 1_024
    assert Adapter.validate(arguments, Adapter.schema()) == :ok
    receipt = store_through_owner(text(big), payload, ctx)
    assert {:ok, %{bytes: ^big}} = Artifact.get(ctx.art, @caller, receipt["artifact_id"], :head)
    assert {:ok, bounded} = ToolResultLimit.settle(p, "completed", receipt)
    assert bounded["cut"]["preview_bytes"] == @max - 512
    assert_bounded(bounded, big)

    # only the canonical arguments; only a sealed result of this request
    for bad <- [" " <> arguments, String.replace(arguments, "\"version\":1", "\"version\":2"), "{}"],
        do: assert(Adapter.validate(bad, Adapter.schema()) == :error)

    sequence = record!(ctx.log, text(big))
    {:ok, arguments} = Adapter.arguments(payload, @stream, sequence)
    req = request(arguments, ctx)
    completed = Adapter.send_effect(req)
    assert Adapter.validate_result(completed, req) == :ok
    assert Adapter.authenticate(completed, req) == :ok
    forged = put_in(completed["value"]["receipt_sha256"], sha("other"))
    assert Adapter.authenticate(forged, req) == :error
    assert Adapter.validate_result(completed, %{req | attempt_id: "attempt-2"}) == :error
    assert Adapter.authenticate(completed, %{req | context: %{seal_key: <<1::256>>}}) == :error
    assert Adapter.authenticate({:unavailable, :no_status}, req) == :error
  end

  test "skill_file_cut_body_never" do
    skill = text(String.duplicate("step\n", 400), sources: ["pinned_skill:review/notes.md"])
    assert {:store, pending, _} = ToolResultLimit.decide(skill, @limits, "act-5")
    assert {:ok, bounded} = ToolResultLimit.settle(pending, "failed", nil)
    assert bounded["cut"]["note"] == "store_refused"

    body = "You are the reviewer. Follow these steps."

    for content <- [
          body,
          Map.delete(marked(body), "schema_id"),
          %{marked(body) | "trust" => "trusted"},
          %{marked(String.duplicate("x", 2_000)) | "max_bytes" => 10}
        ] do
      result = %{"content" => content, "media_type" => "text/markdown", "encoding" => "utf8"}
      assert ToolResultLimit.decide(result, @limits, "act-6") == {:error, :unmarked}
    end
  end

  test "binary_by_reference_only", ctx do
    bytes = <<137, 80, 78, 71>> <> :crypto.strong_rand_bytes(200)
    result = binary(bytes)
    assert {:store, pending, payload} = ToolResultLimit.decide(result, @limits, "act-7")
    assert payload["size_bytes"] == byte_size(bytes) and payload["sha256"] == sha(bytes)
    assert pending["content"]["content"] == ""

    receipt = store_through_owner(result, payload, ctx)

    assert {:ok, %{bytes: ^bytes, record: %{media_type: "image/png"}}} =
             Artifact.get(ctx.art, @caller, receipt["artifact_id"], :head)

    assert {:ok, bounded} = ToolResultLimit.settle(pending, "completed", receipt)

    assert bounded["content"]["content"] ==
             "[binary result: #{byte_size(bytes)} bytes, image/png; artifact #{receipt["artifact_id"]} version 1]"

    assert bounded["cut"]["preview_bytes"] == 0
    assert_bounded(bounded, Base.encode64(bytes))

    # base64 that does not decode: unpadded, a bad character, white space
    for bad <- ["QUI", "not base64!", "QUJD\n"] do
      result = put_in(binary("x")["content"]["content"], bad)
      assert ToolResultLimit.decide(result, @limits, "a") == {:error, :invalid_input}
    end
  end

  test "store_refused_unknown_or_too_large", ctx do
    full = String.duplicate("r", 3_000)
    result = text(full)
    assert {:store, pending, payload} = ToolResultLimit.decide(result, @limits, "act-8")

    send_once = fn ->
      sequence = record!(ctx.log, result)
      {:ok, arguments} = Adapter.arguments(payload, @stream, sequence)
      req = request(arguments, ctx)
      {Adapter.send_effect(req), req}
    end

    check = fn bounded, note ->
      assert bounded["cut"]["note"] == note
      assert bounded["cut"]["artifact"] == nil

      assert bounded["content"]["content"] ==
               "[cut: first 512 of 3000 bytes shown; whole result not stored: #{note}]\n" <>
                 String.duplicate("r", 512)

      assert_bounded(bounded, full)
    end

    # 403: refused
    H.fake_fail(ctx.s3, :put, 403)
    assert {{:error, :store_refused, nil}, _} = send_once.()
    assert {:ok, bounded} = ToolResultLimit.settle(pending, "failed", nil)
    check.(bounded, "store_refused")

    # 500: unknown, uncertain staging, no second put
    H.fake_heal(ctx.s3)
    H.fake_fail(ctx.s3, :put, 500)
    before = puts(ctx.s3)
    assert {{:error, :store_unknown, nil}, req} = send_once.()
    assert Adapter.poll(req) == {:unavailable, :no_status}
    assert puts(ctx.s3) == before + 1

    assert {:ok, %{record: %{state: :staging, upload: :uncertain}}} =
             Artifact.status(ctx.art, @caller, %{artifact_id: req.key, version: 1})

    assert {:ok, bounded} = ToolResultLimit.settle(pending, "unknown", nil)
    check.(bounded, "store_unknown")
    receipt = receipt(pending)

    assert {:ok, bounded} =
             ToolResultLimit.settle(pending, "completed", %{receipt | "size_bytes" => 2_999})

    check.(bounded, "store_unknown")

    assert {:ok, bounded} =
             ToolResultLimit.settle(pending, "completed", Map.put(receipt, "extra", 1))

    check.(bounded, "store_unknown")
    assert ToolResultLimit.settle(pending, "late", receipt) == {:error, :invalid_input}
    assert ToolResultLimit.settle(pending, "done", nil) == {:error, :invalid_input}

    for outcome <- ~w(refused out_of_budget retries_exhausted expired resource_lost) do
      assert {:ok, bounded} = ToolResultLimit.settle(pending, outcome, nil)
      check.(bounded, "store_refused")
    end

    # over the Artifact bound: no store payload
    assert {:ok, bounded} =
             ToolResultLimit.decide(result, %{max_bytes: @max, artifact_max_bytes: 2_999}, "a")

    check.(bounded, "over_artifact_max")

    # no-send tags: the double sees no request
    H.fake_heal(ctx.s3)
    requests = length(H.fake_requests(ctx.s3))
    {:ok, absent} = Adapter.arguments(payload, @stream, 999)
    assert Adapter.send_effect(request(absent, ctx)) == {:error, :record_unavailable, nil}

    Memory.fault(ctx.log, :append, :stage)
    staged = record!(ctx.log, result)
    {:ok, above} = Adapter.arguments(payload, @stream, staged)

    assert {:ok, [%{sequence: ^staged}], %{revision: revision}} =
             Elzoo.DurableLog.read(ctx.log, @stream, staged, 1)

    assert staged > revision
    assert Adapter.send_effect(request(above, ctx)) == {:error, :record_unavailable, nil}

    {:ok, invalid} = Adapter.arguments(payload, @stream, 1)
    assert Adapter.send_effect(request(invalid <> " ", ctx)) == {:error, :invalid_arguments, nil}
    assert length(H.fake_requests(ctx.s3)) == requests
    assert {:ok, bounded} = ToolResultLimit.settle(pending, "refused", nil)
    check.(bounded, "store_refused")

    # last case: a record with other bytes of the same size
    {:ok, other} = Memory.start_link(fold: log_fold(), limits: @log_limits)
    other_log = Memory.store(other)
    sequence = record!(other_log, text(String.duplicate("s", 3_000)))
    {:ok, arguments} = Adapter.arguments(payload, @stream, sequence)
    req = request(arguments, %{ctx | context: %{ctx.context | log: other_log}})
    assert Adapter.send_effect(req) == {:error, :digest_mismatch, nil}
    assert length(H.fake_requests(ctx.s3)) == requests
  end

  test "mark_survives_cut" do
    full = String.duplicate("m", 2_000)
    bytes = :crypto.strong_rand_bytes(300)

    for trust <- ["untrusted", "derived"],
        sources = ["mcp:files/read_file", "member:reviewer"],
        result <- [
          text(full, trust: trust, sources: sources),
          binary(bytes, trust: trust, sources: sources)
        ] do
      assert {:store, pending, _} = ToolResultLimit.decide(result, @limits, "act-9")

      over =
        ToolResultLimit.decide(result, %{max_bytes: @max, artifact_max_bytes: 100}, "act-9")

      values =
        [over] ++
          for {outcome, receipt} <- [
                {"completed", receipt(pending)},
                {"failed", nil},
                {"unknown", nil}
              ],
              do: ToolResultLimit.settle(pending, outcome, receipt)

      for {:ok, bounded} <- values do
        assert bounded["content"]["sources"] == sources
        assert bounded["content"]["trust"] == trust
        assert_bounded(bounded, result["content"]["content"])
      end

      assert length(values) == 4
    end
  end

  test "malformed operands are invalid_input and hold no content" do
    secret = String.duplicate("z", 2_000)
    result = text(secret)

    for {r, l, id} <- [
          {Map.put(result, "extra", 1), @limits, "a"},
          {%{result | "media_type" => ""}, @limits, "a"},
          {%{result | "media_type" => "a\0b"}, @limits, "a"},
          {%{result | "encoding" => "utf16"}, @limits, "a"},
          {result, %{max_bytes: 1_023, artifact_max_bytes: 10}, "a"},
          {result, %{max_bytes: 1_048_577, artifact_max_bytes: 10}, "a"},
          {result, %{max_bytes: @max, artifact_max_bytes: 0}, "a"},
          {result, Map.put(@limits, :x, 1), "a"},
          {result, @limits, ""},
          {result, @limits, :a},
          {secret, @limits, "a"}
        ] do
      assert ToolResultLimit.decide(r, l, id) == {:error, :invalid_input}
    end

    assert {:store, pending, _} = ToolResultLimit.decide(result, @limits, "a")

    for bad <- [
          Map.delete(pending, "sha256"),
          put_in(pending["content"]["content"], String.duplicate("z", 600)),
          %{pending | "encoding" => "base64"},
          %{pending | "size_bytes" => 16_777_217},
          nil
        ] do
      assert ToolResultLimit.settle(bad, "failed", nil) == {:error, :invalid_input}
    end
  end

  test "Selected Cure law and example" do
    source = File.read!(Path.expand("../../cure/elzoo/tool_result_limit.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0
    assert source =~ "fn whole_only_under_bound("

    for t <- [true, false], o <- [true, false], a <- [true, false] do
      whole = apply(:"Cure.Elzoo.ToolResultLimit", :decide, [t, o, a]) == :Whole
      assert whole == (t and not o)
    end

    {result, _} = Code.eval_file(Path.expand("../../examples/tool_result_limit.exs", __DIR__))
    assert {:ok, %{"cut" => %{"note" => "store_refused", "preview_bytes" => 512}}} = result
  end
end
