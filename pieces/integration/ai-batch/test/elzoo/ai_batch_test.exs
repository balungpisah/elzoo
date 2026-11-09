# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_batch_test_helper.exs", __DIR__)

defmodule Elzoo.AiBatchTest do
  # Interface scenarios with scripted test providers; each names its boundary.
  # EffectIntent owners run on the volatile Memory store (no database).
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.AiBatch
  alias Elzoo.AiBatch.{Completion, Conformance, Join, Sink, Staging, Submission, TestHelper}
  alias Elzoo.AiText
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @secret "sk-test-SECRET-b42"
  @model "test-model"
  @job %{provider: "test", provider_job_id: "job-1", submitted_at: 1}

  setup do
    staging = start_supervised!({Staging, []})
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent), staging: staging}
  end

  ## helpers

  defp config(ctx, opts \\ []) do
    parent = self()
    respond = Keyword.get(opts, :respond, fn _, _ -> {:failure, :provider_error, %{}} end)

    base =
      [
        submit_binding: Elzoo.AiBatch.TestSubmitBinding,
        cancel_binding: Elzoo.AiBatch.TestCancelBinding,
        tenant: "tenant-a",
        provider: Elzoo.AiBatch.TestProvider,
        provider_config:
          Map.merge(%{parent: parent, respond: respond}, Keyword.get(opts, :provider_config, %{})),
        credentials: Keyword.get(opts, :credentials, fn -> {:ok, @secret} end),
        submissions: Keyword.get(opts, :submissions, Staging.lookup_fun(ctx.staging)),
        models: [@model],
        max_output_tokens: 1000,
        sink: Sink.to_pid(parent)
      ] ++ Keyword.get(opts, :bounds, [])

    {:ok, c} = AiBatch.configure(base)
    c
  end

  defp submission(ids \\ Conformance.ids()), do: Conformance.submission(@model, ids)

  defp admit(c, sub, ref \\ "sub-1"),
    do: AiBatch.admit_submit(c, Conformance.submit_declaration(sub, ref, 10_000))

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

  defp settled(pid, tries \\ 250) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(20) && settled(pid, tries - 1)
    end
  end

  defp submit(c, ctx, sub \\ submission(), ref \\ "sub-1", stage? \\ true) do
    {:ok, a} = admit(c, sub, ref)
    if stage?, do: :ok = Staging.put(ctx.staging, a)
    pid = owner(c.submit_binding, c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key
    assert_receive {AiBatch, ^key, delivery}, 2000
    {pid, a, status, delivery}
  end

  defp cancel(c, ctx, ref \\ "cancel-1") do
    {:ok, a} = AiBatch.admit_cancel(c, Conformance.cancel_declaration(@job, ref, 10_000))
    pid = owner(c.cancel_binding, c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key
    assert_receive {AiBatch, ^key, delivery}, 2000
    {pid, a, status, delivery}
  end

  defp calls(op) do
    receive do
      {:call, ^op, _} -> 1 + calls(op)
    after
      50 -> 0
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp line(id, result), do: {id, result}
  defp ok_line(id, text \\ Conformance.text()), do: line(id, {:succeeded, {:raw, TestHelper.raw(text)}})

  defp join(c, sub \\ submission()) do
    {:ok, j} = Join.new(c, Elzoo.AiText.Request.canonical(sub))
    j
  end

  ## submit

  test "S1 submit accepted through admission, the owner and the Adapter; orphans empty; the job reference reaches only the sink (owner + Adapter)",
       ctx do
    c = config(ctx, respond: fn :submit, _ -> {:ok, %{provider_job_id: "job-1", orphans: []}} end)
    {pid, a, status, delivery} = submit(c, ctx)
    assert Conformance.check_write(:submit_accepted, delivery, calls(:submit)) == :ok
    assert {:outcome, _, {:submitted, %{job_ref: ref, item_count: 4, orphans: []}}} = delivery
    assert ref.provider == "test"
    assert {:Confirmed, 1} = status.phase
    # The intent arguments are the manifest, not the submission.
    assert {:ok, m} = Submission.decode_manifest(a.arguments)
    assert m.item_count == 4 and m.submission_bytes == byte_size(a.submission)
    refute a.arguments =~ "Batch conformance prompt"
    # Neither the submission bytes, a prompt nor the credential is in owner state.
    state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
    refute state =~ "Batch conformance prompt"
    refute state =~ @secret
    refute inspect(status) =~ "Batch conformance prompt"
    # The staging process shows sizes, not content.
    refute inspect(:sys.get_state(ctx.staging), limit: :infinity) =~ "Batch conformance prompt"
  end

  test "S2 local refusals return at admission before an intent, the credential or the provider: ids, models, counts, bytes, items, features, options (admission)",
       ctx do
    need = fn ->
      send(self(), :credential_read)
      {:ok, @secret}
    end

    c = config(ctx, credentials: need, bounds: [max_items: 4])
    base = submission()
    items = base["items"]

    refusals = [
      {%{base | "items" => [hd(items), hd(items)]}, :invalid_request},
      {%{base | "items" => [put_in(hd(items), ["item_id"], "bad id!")]}, :invalid_request},
      {%{base | "items" => [put_in(hd(items), ["item_id"], String.duplicate("a", 65))]},
       :invalid_request},
      {%{base | "items" => [put_in(hd(items), ["request", "model"], "other-model")]},
       :invalid_request},
      {%{base | "model" => "other-model", "items" => [put_in(hd(items), ["request", "model"], "other-model")]},
       :invalid_request},
      {%{base | "items" => []}, :invalid_request},
      {submission(["a", "b", "c", "d", "e"]), :too_large},
      {%{base | "items" => [put_in(hd(items), ["request", "max_output_tokens"], 5000)]},
       :invalid_request},
      {%{base | "items" => [put_in(hd(items), ["request", "sampling"], %{"top_p" => 0.5})]},
       :unsupported_feature},
      {%{base | "items" => [put_in(hd(items), ["request", "messages"], [%{"role" => "user", "text" => "refuse-in-translate"}])]},
       :unsupported_feature},
      {Map.put(base, "provider_options", %{"unknown" => 1}), :invalid_request},
      {Map.put(base, "provider_options", %{"priority" => "urgent"}), :invalid_request},
      {Map.put(base, "extra", 1), :invalid_request}
    ]

    for {sub, reason} <- refusals do
      assert {:error, {:refused, ^reason, %{retry_after: nil, orphans: []}}} = admit(c, sub),
             inspect({sub, reason})
    end

    assert {:ok, _} = admit(c, Map.put(base, "provider_options", %{"priority" => "low"}))
    refute_received :credential_read
    assert calls(:submit) == 0

    # Duplicate JSON keys and an over-long payload.
    dup = Conformance.submit_declaration(base, "d", 10_000)
    dup = put_in(dup, ["command", "payload"], ~s({"version":1,"version":1,"model":"test-model","items":[]}))
    assert {:error, {:refused, :invalid_request, _}} = AiBatch.admit_submit(c, dup)

    small = config(ctx, bounds: [max_submission_bytes: 200])
    assert {:error, {:refused, :too_large, _}} = admit(small, base)

    # Malformed declarations.
    decl = Conformance.submit_declaration(base, "x", 10_000)
    assert {:error, :declaration} = AiBatch.admit_submit(c, Map.put(decl, "operation", "cancel"))
    assert {:error, :declaration} = AiBatch.admit_submit(c, Map.put(decl, "classification", "trusted"))
    assert {:error, :declaration} = AiBatch.admit_submit(c, %{})
  end

  test "S3 the create body bound is measured on the exact encoded body: bound - 1, bound, bound + 1 and wrapper overhead alone (admission)",
       ctx do
    c0 = config(ctx)
    {:ok, wire} = AiBatch.prepare(c0, elem(Submission.decode(Elzoo.AiText.Request.canonical(submission(["a"])), AiBatch.bounds(c0)), 1))
    size = byte_size(wire.body)

    for {bound, expected} <- [{size - 1, :refused}, {size, :ok}, {size + 1, :ok}] do
      c = config(ctx, bounds: [max_create_wire_bytes: bound])

      case expected do
        :ok -> assert {:ok, _} = admit(c, submission(["a"]))
        :refused -> assert {:error, {:refused, :too_large, _}} = admit(c, submission(["a"]))
      end
    end

    # Padding in the provider's wrapper alone crosses the bound.
    c = config(ctx, bounds: [max_create_wire_bytes: size + 10], provider_config: %{pad: 11})
    assert {:error, {:refused, :too_large, _}} = admit(c, submission(["a"]))

    # Item count at the bound and above.
    c = config(ctx, bounds: [max_items: 2])
    assert {:ok, _} = admit(c, submission(["a", "b"]))
    assert {:error, {:refused, :too_large, _}} = admit(c, submission(["a", "b", "c"]))
  end

  test "S4 configuration bounds are validated against the provider's caps; Config inspect carries no Need or secret (configure)",
       ctx do
    good = fn extra ->
      AiBatch.configure(
        [
          submit_binding: Elzoo.AiBatch.TestSubmitBinding,
          cancel_binding: Elzoo.AiBatch.TestCancelBinding,
          tenant: "tenant-a",
          provider: Elzoo.AiBatch.TestProvider,
          provider_config: %{},
          credentials: fn -> {:ok, @secret} end,
          submissions: Staging.lookup_fun(ctx.staging),
          models: [@model],
          sink: fn _, _ -> :ok end
        ]
        |> Keyword.merge(extra)
      )
    end

    assert {:ok, c} = good.([])
    assert c.max_items == 10 and c.max_create_wire_bytes == 100_000
    assert c.page_size == 100 and c.max_item_bytes == 65_536

    for bad <- [
          [max_items: 0],
          [max_items: 11],
          [max_create_wire_bytes: 100_001],
          [max_create_wire_bytes: 0],
          [max_item_bytes: 65_537],
          [page_size: 1001],
          [max_line_bytes: 16 * 1_048_576 + 1],
          [max_scan_bytes: 1024 * 1_048_576 + 1],
          [receive_timeout_ms: 600_001],
          [unknown: 1],
          [submit_binding: Elzoo.AiBatch.TestCancelBinding],
          [cancel_binding: Elzoo.AiBatch.TestSubmitBinding]
        ] do
      assert {:error, :configuration} = good.(bad), inspect(bad)
    end

    assert {:ok, _} = good.(max_items: 10, max_create_wire_bytes: 100_000, page_size: 1000)
    refute inspect(c) =~ @secret
    refute inspect(c) =~ "Function"
  end

  test "S5 orphans are present on every outcome; a provider's non-empty orphan list is validated and delivered on refused and unknown (Adapter)",
       ctx do
    orphan = %{kind: "file", provider_ref: "file-abc"}

    for {respond, expected} <- [
          {fn :submit, _ -> {:failure, :provider_invalid_request, %{orphans: [orphan]}} end,
           {:refused, :invalid_request, %{retry_after: nil, orphans: [orphan]}}},
          {fn :submit, _ -> {:failure, :timeout, %{orphans: [orphan]}} end,
           {:unknown, :timeout, %{orphans: [orphan]}}},
          {fn :submit, _ -> {:failure, :throttled, %{retry_after: 7}} end,
           {:refused, :throttled, %{retry_after: 7, orphans: []}}},
          {fn :submit, _ -> {:failure, :provider_error, %{orphans: [%{kind: 5}]}} end,
           {:unknown, :provider_error,
            %{orphans: [%{kind: "unreported", provider_ref: "invalid-orphan-list"}]}}}
        ] do
      c = config(ctx, respond: respond)
      {_pid, _a, _status, delivery} = submit(c, ctx, submission(), "o-#{System.unique_integer([:positive])}")
      assert {:outcome, _, ^expected} = delivery
    end

    flush()
    c = config(ctx, respond: fn :submit, _ -> {:failure, :throttled, %{retry_after: 7}} end)
    {_, _, _, delivery} = submit(c, ctx, submission(), "thr")
    assert Conformance.check_write(:submit_throttled, delivery, calls(:submit)) == :ok
  end

  test "S6 a lost submit is unknown; a second dispatch of the same identity is refused; re-admission yields the same key; throttled is not redispatched (owner + Retry)",
       ctx do
    c = config(ctx, respond: fn :submit, _ -> {:failure, :timeout, %{}} end)
    {pid, a, _status, delivery} = submit(c, ctx)
    assert Conformance.check_write(:submit_lost, delivery, calls(:submit)) == :ok
    assert {:error, _} = Intent.advance(pid, :dispatch)
    assert {:error, _} = Intent.advance(pid, :rearm)
    assert calls(:submit) == 0
    {:ok, again} = admit(c, submission())
    assert again.key == a.key
    {:ok, other} = admit(c, submission(), "sub-2")
    refute other.key == a.key

    {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 3, base_backoff_ms: 10)
    assert {:stop, :unresolved} = AiText.Retry.next(policy, 1, :timeout)
    assert {:stop, :unresolved} = AiText.Retry.next(policy, 1, :throttled)
    assert {:retry, 10} = AiText.Retry.next(policy, 1, :credentials_unavailable)
  end

  test "S7 the credential Need failing is the attested no-send; nothing is submitted (Adapter)", ctx do
    c = config(ctx, credentials: fn -> {:error, :vault} end, respond: fn _, _ -> raise "never" end)
    {pid, _a, _status, delivery} = submit(c, ctx)
    assert {:outcome, _, {:refused, :credentials_unavailable, %{retry_after: nil, orphans: []}}} = delivery
    assert calls(:submit) == 0
    assert {:ok, _} = Intent.advance(pid, :rearm)
  end

  test "S8 a missing or mismatched staged submission sends nothing and reads no credential; the outcome is conservatively unknown (Adapter + lookup Need)",
       ctx do
    need = fn ->
      send(self(), :credential_read)
      {:ok, @secret}
    end

    # Not staged.
    c = config(ctx, credentials: need, respond: fn _, _ -> raise "never" end)
    {:ok, a} = admit(c, submission(), "nostage")
    pid = owner(c.submit_binding, c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)
    key = a.key
    assert_receive {AiBatch, ^key, {:outcome, _, {:unknown, :provider_error, %{orphans: []}}}}, 2000
    refute_received :credential_read
    assert calls(:submit) == 0
    assert {:error, _} = Intent.advance(pid, :dispatch)

    # Staged bytes that do not match the manifest.
    lookup = fn _key, _ -> {:ok, Elzoo.AiText.Request.canonical(submission(["a"]))} end
    c = config(ctx, credentials: need, submissions: lookup, respond: fn _, _ -> raise "never" end)
    {:ok, a} = admit(c, submission(), "mismatch")
    pid = owner(c.submit_binding, c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    settled(pid)
    refute_received :credential_read
    assert calls(:submit) == 0

    # A second put of other bytes under the same key is refused.
    {:ok, a} = admit(config(ctx), submission(), "twice")
    :ok = Staging.put(ctx.staging, a)
    assert :ok = Staging.put(ctx.staging, a)
    assert {:error, :conflict} = Staging.put(ctx.staging, %{a | submission: a.submission <> " "})
  end

  ## cancel

  test "C1 cancel acknowledged; a lost cancel is unknown and a second dispatch is refused; a later status observation is not a ground (cancel owner)",
       ctx do
    c = config(ctx, respond: fn :cancel, "job-1" -> {:ok, :ending} end)
    {_pid, _a, status, delivery} = cancel(c, ctx)
    assert Conformance.check_write(:cancel_accepted, delivery, calls(:cancel)) == :ok
    assert {:Confirmed, 1} = status.phase

    c =
      config(ctx,
        respond: fn
          :cancel, _ -> {:failure, :timeout, %{}}
          :status, _ -> {:ok, :ending}
        end
      )

    {pid, a, _status, delivery} = cancel(c, ctx, "cancel-lost")
    assert Conformance.check_write(:cancel_lost, delivery, calls(:cancel)) == :ok
    assert {:ok, %{state: :ending}} = AiBatch.status(c, @job)
    assert {:error, _} = Intent.advance(pid, :dispatch)
    assert {:error, _} = Intent.advance(pid, :rearm)
    assert calls(:cancel) == 0

    # The cancel identity names one job: same caller identity, other job, other key.
    {:ok, other} =
      AiBatch.admit_cancel(c, Conformance.cancel_declaration(%{@job | provider_job_id: "job-2"}, "cancel-lost", 10_000))

    refute other.key == a.key

    # Refusals at cancel admission.
    for job <- [%{@job | provider: "other"}, %{@job | provider_job_id: String.duplicate("j", 129)}] do
      assert {:error, {:refused, :invalid_request, _}} =
               AiBatch.admit_cancel(c, Conformance.cancel_declaration(job, "x", 10_000))
    end

    # Provider rejection statuses are refusals.
    c = config(ctx, respond: fn :cancel, _ -> {:failure, :not_found, %{}} end)
    {_, _, _, delivery} = cancel(c, ctx, "cancel-404")
    assert {:outcome, _, {:refused, :not_found, %{retry_after: nil}}} = delivery
  end

  ## status

  test "R1 status: pending to running to ending to ended; every core job state; finite errors; one call each (status read)",
       ctx do
    states = [
      :pending,
      :running,
      :ending,
      {:ended, %{succeeded: 1, errored: 1, cancelled: 1, expired: 1}},
      :expired,
      :cancelled,
      :failed
    ]

    agent = start_supervised!({Agent, fn -> states end})

    c =
      config(ctx,
        respond: fn :status, "job-1" ->
          {:ok, Agent.get_and_update(agent, fn [s | rest] -> {s, rest} end)}
        end
      )

    seen = for _ <- states, do: AiBatch.status(c, @job)
    assert seen == Enum.map(states, &{:ok, %{state: &1}})
    assert calls(:status) == length(states)

    assert Conformance.check_status(:status_sequence, Enum.slice(seen, 1..3)) == :ok

    for {tag, reason} <- [
          {:authentication_failed, :authentication_failed},
          {:not_found, :not_found},
          {:throttled, :throttled},
          {:overloaded, :overloaded},
          {:timeout, :timeout},
          {:provider_error, :provider_error},
          {:bogus, :provider_error}
        ] do
      c = config(ctx, respond: fn :status, _ -> {:failure, tag, %{}} end)
      assert {:error, ^reason} = AiBatch.status(c, @job)
      assert reason in AiBatch.read_reasons()
    end

    c = config(ctx, respond: fn :status, _ -> {:ok, :weird} end)
    assert {:error, :malformed_response} = AiBatch.status(c, @job)
    c = config(ctx, credentials: fn -> :error end)
    assert {:error, :credentials_unavailable} = AiBatch.status(c, @job)
    assert {:error, :invalid_request} = AiBatch.status(c, %{@job | provider: "other"})
    assert {:error, :invalid_request} = AiBatch.status(c, %{})
  end

  ## results

  test "R2 results joined by item id, out of order, mixed outcomes; missing only after the last page of an ended job (results + Join)",
       ctx do
    page = [
      line("item-d", :expired),
      ok_line("item-a"),
      line("item-c", :cancelled),
      line("item-b", {:errored, :invalid_request})
    ]

    c = config(ctx, respond: fn :results, {"job-1", %{cursor: 0}} -> {:ok, %{lines: page, done: true}} end)
    r = AiBatch.results(c, @job, 0, join(c))
    assert Conformance.check_results(:results_mixed, r) == :ok
    assert calls(:results) == 1

    # Missing: three of four ids, in two pages.
    pages = %{0 => {[ok_line("item-b"), ok_line("item-a")], false}, 2 => {[line("item-c", :cancelled)], true}}

    c =
      config(ctx,
        bounds: [page_size: 2],
        respond: fn :results, {"job-1", %{cursor: n}} ->
          {lines, done} = pages[n]
          {:ok, %{lines: lines, done: done}}
        end
      )

    j = join(c)
    assert {:ok, %{next: 2, join: j}} = AiBatch.results(c, @job, 0, j)
    assert {:error, :not_ended} = Join.missing(j, {:ended, %{succeeded: 2, errored: 0, cancelled: 1, expired: 0}})
    r = AiBatch.results(c, @job, 2, j)
    assert {:ok, %{next: :done, join: done}} = r
    assert {:error, :not_ended} = Join.missing(done, :running)
    state = {:ended, %{succeeded: 2, errored: 0, cancelled: 1, expired: 0}}
    assert Conformance.check_results(:results_missing, r, state) == :ok
    # A cursor other than the join's next cursor is refused without a call.
    assert {:error, :invalid_request} = AiBatch.results(c, @job, 1, j)
    assert {:error, :invalid_request} = AiBatch.results(c, @job, 3, done)
  end

  test "R3 a page naming an unknown id, or an id seen in this or an earlier page, is refused whole; an over-long page too (results + Join)",
       ctx do
    for {id, lines} <- [
          {:results_unknown_id, [ok_line("item-a"), ok_line("item-z")]},
          {:results_duplicate_id, [ok_line("item-a"), ok_line("item-a")]}
        ] do
      c = config(ctx, respond: fn :results, _ -> {:ok, %{lines: lines, done: true}} end)
      assert Conformance.check_results(id, AiBatch.results(c, @job, 0, join(c))) == :ok
    end

    pages = %{0 => [ok_line("item-a")], 1 => [ok_line("item-a")]}
    c = config(ctx, respond: fn :results, {_, %{cursor: n}} -> {:ok, %{lines: pages[n], done: false}} end)
    {:ok, %{join: j}} = AiBatch.results(c, @job, 0, join(c))
    assert {:error, :malformed_page} = AiBatch.results(c, @job, 1, j)

    c =
      config(ctx,
        bounds: [page_size: 1],
        respond: fn :results, _ -> {:ok, %{lines: [ok_line("item-a"), ok_line("item-b")], done: false}} end
      )

    assert {:error, :malformed_page} = AiBatch.results(c, @job, 0, join(c))

    c = config(ctx, respond: fn :results, _ -> {:ok, %{lines: [line("item-a", :weird)], done: true}} end)
    assert {:error, :malformed_page} = AiBatch.results(c, @job, 0, join(c))
  end

  test "R4 result bounds: page size, line limit and scan limit reach the caller as finite errors; the join is unchanged (results)",
       ctx do
    parent = self()

    c =
      config(ctx,
        bounds: [page_size: 3, max_line_bytes: 1000, max_scan_bytes: 5000],
        respond: fn :results, {_, page} ->
          send(parent, {:page_opts, page})
          {:failure, :result_scan_limit, %{}}
        end
      )

    j = join(c)
    assert {:error, :result_scan_limit} = AiBatch.results(c, @job, 0, j)
    assert_received {:page_opts, %{cursor: 0, page_size: 3, max_line_bytes: 1000, max_scan_bytes: 5000}}
    assert :result_scan_limit in AiBatch.results_reasons()

    c = config(ctx, respond: fn :results, _ -> {:failure, :result_line_limit, %{}} end)
    assert {:error, :result_line_limit} = AiBatch.results(c, @job, 0, j)
    c = config(ctx, respond: fn :results, _ -> {:failure, :not_found, %{}} end)
    assert {:error, :not_found} = AiBatch.results(c, @job, 0, j)
    assert j.next == 0 and j.seen == MapSet.new()
  end

  test "R5 per-item completion: usage absent is unknown, malformed item is errored malformed_response, tool proposals are inert data (results)",
       ctx do
    {:ok, no_usage} =
      {:ok, Elzoo.AiModel.Usage.unknown(%{input_includes_cached: false})}

    lines = [
      line("item-a", {:succeeded, {:raw, TestHelper.raw("x", %{usage: no_usage})}}),
      line("item-b", {:succeeded, {:raw, TestHelper.raw("x", %{response_id: nil})}}),
      line("item-c", {:succeeded, :not_an_exchange})
    ]

    c = config(ctx, respond: fn :results, _ -> {:ok, %{lines: lines, done: true}} end)
    {:ok, %{items: items}} = AiBatch.results(c, @job, 0, join(c))
    by = Map.new(items)
    assert {:succeeded, %{usage: u}} = by["item-a"]
    assert Elzoo.AiModel.Usage.amount(u, :output_tokens) == :unknown
    assert by["item-b"] == {:errored, :malformed_response}
    assert by["item-c"] == {:errored, :malformed_response}
  end

  ## completion equality with the synchronous path

  @lookup %{
    "name" => "lookup",
    "description" => "Look up a term.",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"q" => %{"type" => "string"}},
      "required" => ["q"],
      "additionalProperties" => false
    }
  }
  @answer %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  defp call(name, json), do: %{id: "toolu_1", name: name, arguments_json: json}

  defp corpus do
    tools = %{"tools" => [@lookup]}
    out = %{"output_schema" => @answer}
    raw = &TestHelper.raw/2

    [
      {:text, %{}, raw.("hello", %{})},
      {:length, %{}, raw.("x", %{finish: :length})},
      {:refusal, %{}, raw.("x", %{finish: :refusal})},
      {:content_filter, %{}, raw.("x", %{finish: :content_filter})},
      {:other_finish, %{}, raw.("x", %{finish: {:other, "pause_turn"}})},
      {:tool_ok, tools, raw.("", %{finish: :tool_calls, tool_calls: [call("lookup", ~s({"q":"x"}))]})},
      {:tool_invalid_json, tools, raw.("", %{tool_calls: [call("lookup", "{not json")]})},
      {:tool_not_object, tools, raw.("", %{tool_calls: [call("lookup", "[1]")]})},
      {:tool_undeclared, tools, raw.("", %{tool_calls: [call("other", ~s({"q":"x"}))]})},
      {:tool_schema_mismatch, tools, raw.("", %{tool_calls: [call("lookup", ~s({"q":5}))]})},
      {:structured_valid, out, raw.(~s({"answer":42}), %{structured_json: ~s({"answer":42})})},
      {:structured_invalid, out, raw.("x", %{structured_json: ~s({"answer":"x"})})},
      {:structured_missing, out, raw.("x", %{structured_json: nil})},
      {:structured_bad_json, out, raw.("x", %{structured_json: "{"})},
      {:usage_absent, %{}, raw.("x", %{usage: Elzoo.AiModel.Usage.unknown(%{input_includes_cached: false})})},
      {:request_id_absent, %{}, Map.delete(raw.("x", %{}), :request_id)},
      {:malformed_no_id, %{}, raw.("x", %{response_id: nil})},
      {:malformed_finish, %{}, raw.("x", %{finish: :weird})},
      {:malformed_usage, %{}, raw.("x", %{usage: %{}})},
      {:malformed_content, %{}, raw.("x", %{content: 5})},
      {:malformed_provenance, %{}, raw.("x", %{provider_model: nil})}
    ]
  end

  test "E1 the batch completion check equals the synchronous text path over the named corpus (Completion vs ai-text owner + Adapter)",
       ctx do
    caps = Elzoo.AiBatch.TestItemProvider.capabilities()

    for {name, extra, raw} <- corpus() do
      request =
        Map.merge(
          %{
            "version" => 1,
            "model" => @model,
            "messages" => [%{"role" => "user", "text" => "p"}],
            "max_output_tokens" => 64
          },
          extra
        )

      parent = self()

      {:ok, sync} =
        AiText.configure(
          binding: Elzoo.AiBatch.TestTextBinding,
          tenant: "tenant-a",
          provider: Elzoo.AiBatch.TestItemProvider,
          provider_config: %{respond: fn -> {:ok, {:raw, raw}} end},
          credentials: fn -> {:ok, @secret} end,
          models: [@model],
          sink: fn key, d ->
            send(parent, {:sync, key, d})
            :ok
          end
        )

      ref = "eq-#{name}"
      {:ok, a} = AiText.admission(sync, AiText.Conformance.declaration(request, ref, 10_000))
      pid = owner(sync.binding, sync, a, ctx)
      {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      settled(pid)
      key = a.key
      assert_receive {:sync, ^key, {:outcome, _, sync_outcome}}, 2000

      {:ok, decoded, _} = AiText.Request.decode(AiText.Request.canonical(request))
      batch = Completion.complete(caps, decoded, raw)

      expected =
        case sync_outcome do
          {:completed, body} -> {:completed, body}
          {:unknown, :malformed_response} -> {:failure, :malformed_response}
        end

      assert batch == expected, "#{name}: #{inspect({batch, sync_outcome})}"
    end
  end

  ## redaction and audit

  test "X1 credential, prompt and output are absent from errors, deliveries, Config inspect and captured logs (redaction)",
       ctx do
    secret_text = "OUTPUT-SECRET-z9"

    log =
      capture_log(fn ->
        c =
          config(ctx,
            respond: fn
              :submit, _ -> {:failure, :provider_invalid_request, %{}}
              :results, _ -> {:ok, %{lines: [ok_line("item-a", secret_text), ok_line("item-z")], done: true}}
              :status, _ -> {:failure, :authentication_failed, %{}}
            end
          )

        {_, _, _, delivery} = submit(c, ctx)
        refute inspect(delivery) =~ @secret
        refute inspect(delivery) =~ "Batch conformance prompt"
        r = AiBatch.results(c, @job, 0, join(c))
        assert r == {:error, :malformed_page}
        refute inspect(r) =~ secret_text
        assert {:error, :authentication_failed} = AiBatch.status(c, @job)
        refute inspect(c) =~ @secret
        refute inspect(join(c)) =~ "Batch conformance prompt"
      end)

    refute log =~ @secret
    refute log =~ "Batch conformance prompt"
    refute log =~ secret_text
    flush()
  end

  @layouts [
    {Path.expand("../..", __DIR__), Path.expand("../../piece.json", __DIR__)},
    {Path.expand("../..", __DIR__),
     Path.expand("../../.elzoo/pieces/integration/ai-batch/piece.json", __DIR__)}
  ]

  defp own_files do
    case Enum.filter(@layouts, fn {_, manifest} -> File.regular?(manifest) end) do
      [{root, manifest}] ->
        files = Jason.decode!(File.read!(manifest))["files"]
        assert "lib/elzoo/ai_batch.ex" in files
        {root, files}

      found ->
        flunk("expected exactly one integration/ai-batch manifest, found #{length(found)}")
    end
  end

  test "A1 the interface's own files reference no provider library, transport or provider Piece (source audit of the listed files)" do
    {root, files} = own_files()
    # Built by concatenation so this file does not contain the names it forbids.
    forbidden = [
      "Req" <> "LLM",
      "req" <> "_llm",
      "Pl" <> "ug",
      "Req" <> ".",
      "Fin" <> "ch",
      "AiText." <> "Anthropic",
      "AiBatch." <> "Anthropic",
      "llm" <> "_db"
    ]

    for file <- files, not String.starts_with?(file, "test/") do
      source = File.read!(Path.join(root, file))
      for word <- forbidden, do: refute(source =~ word, "#{file} references #{word}")
    end
  end
end
