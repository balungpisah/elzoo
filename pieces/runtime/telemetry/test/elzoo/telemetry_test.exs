# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TelemetryTest do
  @moduledoc "runtime/telemetry: README tables equal the schema (T1), redaction and modes (T2), upstream handler behaviour (T6, T8)."
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Elzoo.Telemetry, as: T

  # T1 reads this Piece's README. In this repository it is
  # pieces/runtime/telemetry/README.md (this file is in the Piece's test/elzoo/);
  # in an exported consumer Elzoo.Export copies it to
  # .elzoo/pieces/runtime/telemetry/README.md while this file lands in the
  # consumer's test/elzoo/. Exactly one of the two must exist; none (or both)
  # fails T1, so a missing README is never skipped.
  @readmes [
    Path.expand("../../../../../pieces/runtime/telemetry/README.md", __DIR__),
    Path.expand("../../.elzoo/pieces/runtime/telemetry/README.md", __DIR__)
  ]
  @ref String.duplicate("ab", 32)

  defp readme do
    case Enum.filter(@readmes, &File.regular?/1) do
      [path] ->
        path

      found ->
        flunk(
          "expected exactly one runtime/telemetry README among #{inspect(@readmes)}, found #{inspect(found)}"
        )
    end
  end

  defp table(marker) do
    File.read!(readme())
    |> String.split("<!-- elzoo-telemetry:#{marker} -->\n")
    |> Enum.at(1)
    |> String.split("\n")
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.drop(2)
    |> Enum.map(fn line ->
      line |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
    end)
  end

  defp code(cell), do: String.trim(cell, "`")

  defp atoms(cell),
    do: cell |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> code() |> String.to_atom()))

  defp event(text) do
    text
    |> code()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(", ")
    |> Enum.map(&(&1 |> String.trim_leading(":") |> String.to_atom()))
  end

  defp perform(extra \\ %{}),
    do:
      Map.merge(
        %{
          adapter: "assembly/durable-job",
          operation: :perform,
          request_ref: @ref,
          attempt: 1,
          queue: "tally"
        },
        extra
      )

  defp effect(extra),
    do: Map.merge(%{adapter: "assembly/http-job", operation: :send, tenant: "tenant-1"}, extra)

  defp capture(events) do
    parent = self()
    id = "elzoo-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(id, events, fn e, m, d, _ -> send(parent, {:event, e, m, d}) end, nil)

    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  describe "T1 schema equals the README tables" do
    test "events and measurement keys" do
      rows = table("events")
      assert Enum.map(rows, &event(hd(&1))) == T.schema().events

      for [e, m] <- rows do
        [:elzoo, f, k] = event(e)
        assert T.schema().measurements[{f, k}] == atoms(m)
      end
    end

    test "units" do
      units =
        for [m, u, _] <- table("units"), into: %{}, do: {String.to_atom(code(m)), String.to_atom(u)}

      assert units == T.schema().units
    end

    test "required and optional keys per operation" do
      keys = [:adapter, :operation, :request_ref, :attempt, :queue, :tenant]

      table =
        for [a, o, f | marks] <- table("operations"), into: %{} do
          pick = fn mark -> for {k, ^mark} <- Enum.zip(keys, marks), do: k end
          {{code(a), String.to_atom(code(o))}, {String.to_atom(f), pick.("R"), pick.("O")}}
        end

      assert table == T.schema().operations
    end

    test "outcomes per operation and the reasons" do
      outcomes =
        for [o, list] <- table("outcomes"), into: %{}, do: {String.to_atom(code(o)), atoms(list)}

      assert outcomes == T.schema().outcomes
      assert T.schema().reasons == [:raise, :throw, :exit]
    end
  end

  describe "T2 redaction" do
    @payload ~s({"version":1,"kind":"publication","text":"hi"})
    @prefixed_secret "tok_" <> String.duplicate("a1B2c3", 6)
    @plain_secret String.duplicate("Zx9Qw7", 6) <> "abcd"

    @hostile [
      @payload,
      String.duplicate("x", 4096),
      "https://user:pw@host",
      "http://host/path",
      "Bearer abc",
      "Basic dXNlcjpwdw==",
      "ab+c/d==",
      "tenant\u0000",
      "tenant\n",
      "ténant",
      %{"a" => 1},
      ["a"],
      %URI{scheme: "https", host: "host", userinfo: "user:pw"},
      %RuntimeError{message: "boom"}
    ]

    test "every structured, URL, header, base64, control and non-ASCII value fails every string grammar" do
      for value <- @hostile, key <- [:tenant, :queue, :request_ref] do
        meta = effect(%{tenant: "t", request_ref: @ref}) |> Map.put(key, value)
        {:ok, clean} = T.metadata([:elzoo, :effect, :start], Map.delete(meta, :queue))

        if key != :queue, do: refute(Map.has_key?(clean, key), inspect({key, value}))

        assert {:error, {:invalid, bad}} =
                 T.metadata([:elzoo, :job, :start], Map.put(perform(), key, value))

        if key in [:queue, :request_ref], do: assert(key in bad), else: assert(:tenant in bad)
      end
    end

    test "a short valid payload never passes, and a non-prefixed token-like secret is a stated limit" do
      refute Map.has_key?(
               elem(T.metadata([:elzoo, :effect, :start], effect(%{tenant: @payload})), 1),
               :tenant
             )

      # Stated limit: an opaque identifier-shaped token (with or without a `tok_`
      # prefix) is indistinguishable from an identifier and passes the tenant
      # grammar; the Adapters never read credentials at an emission point.
      for secret <- [@prefixed_secret, @plain_secret] do
        assert {:ok, %{tenant: ^secret}} =
                 T.metadata([:elzoo, :effect, :start], effect(%{tenant: secret}))
      end
    end

    test "unknown keys are refused" do
      for key <- [:authorization, :token, :payload, :url, :error, "tenant"] do
        assert {:error, {:invalid, bad}} =
                 T.metadata([:elzoo, :job, :start], Map.put(perform(), key, "x"))

        assert if(is_atom(key), do: key, else: :non_atom_key) in bad
      end
    end

    test "strict raises naming keys only; production omits and still emits; optional failures never raise" do
      capture([[:elzoo, :job, :start], [:elzoo, :effect, :start]])
      bad = Map.merge(perform(), %{queue: @payload, token: @plain_secret})

      error =
        assert_raise ArgumentError, fn ->
          T.emit([:elzoo, :job, :start], %{queue_wait: 1}, bad, :strict)
        end

      assert error.message =~ ":queue" and error.message =~ ":token"
      refute error.message =~ "publication" or error.message =~ @plain_secret
      refute_received {:event, _, _, _}

      assert :ok = T.emit([:elzoo, :job, :start], %{queue_wait: 1, bytes: 9}, bad, :production)
      assert_received {:event, [:elzoo, :job, :start], %{queue_wait: 1} = m, d}
      assert map_size(m) == 1
      assert d == Map.delete(perform(), :queue)

      for mode <- [:strict, :production] do
        assert :ok =
                 T.emit(
                   [:elzoo, :effect, :start],
                   %{payload_bytes: 3},
                   effect(%{tenant: "tenant one"}),
                   mode
                 )

        assert_received {:event, [:elzoo, :effect, :start], %{payload_bytes: 3}, d}
        assert d == %{adapter: "assembly/http-job", operation: :send}
      end
    end

    test "required outcome and reason must be declared atoms; family and operation must agree" do
      assert {:ok, _} = T.metadata([:elzoo, :job, :stop], perform(%{outcome: :snooze}))

      assert {:error, {:invalid, [:outcome]}} =
               T.metadata([:elzoo, :job, :stop], perform(%{outcome: :boom}))

      assert {:error, {:invalid, [:outcome]}} = T.metadata([:elzoo, :job, :stop], perform())

      assert {:error, {:invalid, [:reason]}} =
               T.metadata([:elzoo, :job, :exception], perform(%{reason: "boom"}))

      assert {:error, _} = T.metadata([:elzoo, :effect, :start], perform())
      assert {:error, _} = T.metadata([:elzoo, :job, :start], %{perform() | adapter: "other"})
      assert {:error, _} = T.metadata([:elzoo, :job, :typo], perform())
      assert {:error, _} = T.metadata([:elzoo, :job, :start], adapter: "x")
    end

    test "measurements: declared key, non-negative integer" do
      capture([[:elzoo, :job, :stop]])
      meta = perform(%{outcome: :ok})

      assert_raise ArgumentError, fn ->
        T.emit([:elzoo, :job, :stop], %{duration: -1}, meta, :strict)
      end

      assert_raise ArgumentError, fn ->
        T.emit([:elzoo, :job, :stop], %{duration: 1.5}, meta, :strict)
      end

      assert_raise ArgumentError, fn ->
        T.emit([:elzoo, :job, :stop], %{queue_wait: 1}, meta, :strict)
      end

      assert :ok = T.emit([:elzoo, :job, :stop], %{duration: 1.5, size: 3}, meta, :production)
      assert_received {:event, _, m, _}
      assert m == %{}
    end

    test "an unknown event name is never emitted" do
      capture([[:elzoo, :job, :typo]])
      assert :ok = T.emit([:elzoo, :job, :typo], %{}, perform(), :production)
      refute_received {:event, _, _, _}
    end

    test "this repository compiles in strict mode" do
      assert T.default_mode() == :strict
    end
  end

  describe "helpers" do
    test "ref, queue_wait, duration, job_outcome, reason" do
      assert T.ref("job-1") == Base.encode16(:crypto.hash(:sha256, "job-1"), case: :lower)
      assert T.ref("job-1") =~ ~r/\A[0-9a-f]{64}\z/
      a = ~U[2026-11-09 00:00:01.000000Z]
      assert T.queue_wait(a, ~U[2026-11-09 00:00:00.500000Z]) == 500_000
      assert T.queue_wait(a, ~U[2026-11-09 00:00:02Z]) == 0
      assert T.queue_wait(nil, a) == nil
      assert T.duration(T.mark()) >= 0

      assert Enum.map(
               [:ok, {:ok, 1}, {:snooze, 1}, {:cancel, :x}, {:error, :y}, :other],
               &T.job_outcome/1
             ) ==
               [:ok, :ok, :snooze, :cancel, :error, :error]

      assert Enum.map([:error, :throw, :exit], &T.reason/1) == [:raise, :throw, :exit]
    end
  end

  describe "T6/T8 upstream handler behaviour (telemetry 1.4.2)" do
    test "a raising, throwing or exiting handler is detached after its first failure; a healthy handler keeps receiving" do
      event = [:elzoo, :job, :start]
      capture([event])
      failure = capture([[:telemetry, :handler, :failure]])
      _ = failure

      for {kind, fun} <- [
            raise: fn _, _, _, _ -> raise "handler" end,
            throw: fn _, _, _, _ -> throw(:handler) end,
            exit: fn _, _, _, _ -> exit(:handler) end
          ] do
        id = "elzoo-failing-#{kind}"
        :ok = :telemetry.attach(id, event, fun, nil)
        assert :ok = T.emit(event, %{queue_wait: 0}, perform(), :strict)
        assert_received {:event, ^event, _, _}
        assert_received {:event, [:telemetry, :handler, :failure], _, %{handler_id: ^id}}
        assert :telemetry.list_handlers(event) |> Enum.all?(&(&1.id != id))
        assert :ok = T.emit(event, %{queue_wait: 0}, perform(), :strict)
        assert_received {:event, ^event, _, _}
        refute_received {:event, [:telemetry, :handler, :failure], _, _}
      end
    end

    test "absent handler: emission is silent" do
      assert :telemetry.list_handlers([:elzoo, :effect, :stop]) == []

      assert :ok =
               T.emit(
                 [:elzoo, :effect, :stop],
                 %{duration: 1},
                 effect(%{outcome: :completed}),
                 :strict
               )
    end
  end
end
