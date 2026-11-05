# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RequestReplyTest do
  use ExUnit.Case, async: false
  alias Elzoo.RequestReply, as: RR
  @source File.read!(Path.expand("../../cure/elzoo/request_reply.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp examples do
    path = Path.expand("../../../../core/envelope/examples/shared.exs", __DIR__)
    {examples, _} = Code.eval_file(if(File.exists?(path), do: path, else: "examples/shared.exs"))

    examples
  end

  test "named endpoint, explicit and fallback correlation, Unicode and repeated acceptance" do
    %{message: request, reply: reply, results: results} = examples()
    assert RR.reply_endpoint(request) == {:ok, request["reply_to"]}
    assert RR.expected_correlation(request) == {:ok, request["correlation_id"]}

    assert RR.expected_correlation(Map.delete(request, "correlation_id")) ==
             {:ok, request["message_id"]}

    assert RR.reply_endpoint(Map.delete(request, "reply_to")) ==
             {:error, {:correlation, :missing_reply_to}}

    result = results["completed"]

    for _ <- 1..2 do
      assert RR.correlate(request, result) == {:ok, result}
      assert RR.accept_reply(request, reply, request["reply_to"]) == {:ok, result}
    end

    request = Map.put(request, "correlation_id", "résultat.合計")
    result = Map.put(result, "correlation_id", "résultat.合計")
    assert RR.correlate(request, result) == {:ok, result}
    request = Map.drop(request, ~w(correlation_id attempt_id deadline_unix_ms))

    result =
      result
      |> Map.drop(~w(attempt_id deadline_unix_ms))
      |> Map.put("correlation_id", request["message_id"])

    assert RR.correlate(request, result) == {:ok, result}
  end

  test "every shared outcome and unknown dispatched passes through unchanged without classification" do
    %{message: request, reply: reply, results: results} = examples()
    rows = Map.values(results) ++ [Map.put(results["lost_observation"], "dispatch", "dispatched")]

    for result <- rows, kind <- ~w(reply error) do
      assert RR.correlate(request, result) == {:ok, result}
      wrapper = reply |> Map.put("payload", result) |> Map.put("kind", kind)
      assert RR.accept_reply(request, wrapper, request["reply_to"]) == {:ok, result}

      assert RR.accept_reply(request, Map.delete(wrapper, "causation_id"), request["reply_to"]) ==
               {:ok, result}
    end
  end

  test "correlation errors are ordered and optional identity uses exact presence" do
    %{message: request, results: results} = examples()
    result = results["completed"]

    fields = [
      {"message_id", :message_mismatch},
      {"correlation_id", :correlation_mismatch},
      {"attempt_id", :attempt_mismatch},
      {"deadline_unix_ms", :deadline_mismatch}
    ]

    for {{field, reason}, index} <- Enum.with_index(fields) do
      invalid =
        Enum.drop(fields, index)
        |> Enum.reduce(result, fn {key, _}, acc ->
          Map.put(acc, key, if(key == "deadline_unix_ms", do: 0, else: "different"))
        end)

      assert RR.correlate(request, invalid) == {:error, {:correlation, reason}}

      assert RR.correlate(request, Map.delete(result, field)) ==
               if(field in ~w(message_id correlation_id),
                 do: {:error, {:result, :invalid_shape}},
                 else: {:error, {:correlation, reason}}
               )
    end

    for field <- ~w(attempt_id deadline_unix_ms) do
      assert RR.correlate(Map.delete(request, field), result) ==
               {:error,
                {:correlation,
                 if(field == "attempt_id", do: :attempt_mismatch, else: :deadline_mismatch)}}
    end
  end

  test "request and result decoder errors are preserved before correlation" do
    %{message: request, results: results} = examples()
    result = results["completed"]

    request_cases = [
      {nil, :invalid_shape},
      {Map.put(request, "version", 2), :invalid_version},
      {Map.put(request, "message_id", ""), :invalid_message_id},
      {Map.put(request, "schema_id", ""), :invalid_schema_id},
      {Map.put(request, "schema_version", 0), :invalid_schema_version},
      {Map.put(request, "kind", "bad"), :invalid_kind},
      {Map.put(request, "producer", %{"unit_id" => "", "port_id" => "x"}), :invalid_producer},
      {Map.put(request, "reply_to", %{"unit_id" => "", "port_id" => "x"}), :invalid_reply_to},
      {Map.put(request, "attempt_id", ""), :invalid_attempt_id},
      {Map.put(request, "correlation_id", ""), :invalid_metadata},
      {Map.put(request, "sequence", -1), :invalid_sequence},
      {Map.put(request, "deadline_unix_ms", -1), :invalid_deadline}
    ]

    for {invalid, reason} <- request_cases do
      expected = {:error, {:request, reason}}
      assert RR.correlate(invalid, nil) == expected
      assert RR.accept_reply(invalid, nil, nil) == expected
      assert RR.reply_endpoint(invalid) == expected
      assert RR.expected_correlation(invalid) == expected
    end

    for {field, value, reason} <- [
          {"version", 2, :invalid_version},
          {"message_id", "", :invalid_message_id},
          {"correlation_id", "", :invalid_correlation_id},
          {"attempt_id", "", :invalid_attempt_id},
          {"deadline_unix_ms", -1, :invalid_deadline},
          {"outcome", "bad", :invalid_outcome},
          {"dispatch", "bad", :invalid_result_fields}
        ] do
      invalid = Map.put(result, field, value)
      assert RR.correlate(request, invalid) == {:error, {:result, reason}}
    end

    assert RR.correlate(request, %{}) == {:error, {:result, :invalid_shape}}
  end

  test "reply phases and all wrapper errors precede payload validation in documented order" do
    %{message: request, reply: reply} = examples()
    endpoint = request["reply_to"]

    for invalid <- [
          nil,
          self(),
          %{},
          Map.put(endpoint, "extra", true),
          Map.put(endpoint, "unit_id", ""),
          Map.put(endpoint, "port_id", <<255>>)
        ] do
      assert RR.accept_reply(request, nil, invalid) == {:error, {:arrival, :invalid_shape}}
    end

    assert RR.accept_reply(request, nil, endpoint) == {:error, {:reply, :invalid_shape}}

    assert RR.accept_reply(request, Map.put(reply, "version", 2), endpoint) ==
             {:error, {:reply, :invalid_version}}

    invalid =
      reply
      |> Map.put("payload", nil)
      |> Map.put("causation_id", "wrong")
      |> Map.put("correlation_id", "wrong")

    wrong_endpoint = Map.put(endpoint, "port_id", "wrong")

    assert RR.accept_reply(
             request,
             Map.merge(invalid, %{"kind" => "event", "schema_id" => "wrong"}),
             wrong_endpoint
           ) == {:error, {:reply, :invalid_reply_kind}}

    for wrapper <- [Map.put(invalid, "schema_id", "wrong"), Map.put(invalid, "schema_version", 2)] do
      assert RR.accept_reply(request, wrapper, wrong_endpoint) ==
               {:error, {:reply, :invalid_reply_schema}}
    end

    assert RR.accept_reply(Map.delete(request, "reply_to"), invalid, endpoint) ==
             {:error, {:reply, :missing_reply_to}}

    assert RR.accept_reply(request, invalid, wrong_endpoint) ==
             {:error, {:reply, :endpoint_mismatch}}

    for wrapper <- [invalid, Map.delete(invalid, "correlation_id")] do
      assert RR.accept_reply(request, wrapper, endpoint) ==
               {:error, {:reply, :correlation_mismatch}}
    end

    invalid = Map.put(invalid, "correlation_id", request["correlation_id"])
    assert RR.accept_reply(request, invalid, endpoint) == {:error, {:reply, :causation_mismatch}}

    assert RR.accept_reply(request, Map.delete(invalid, "causation_id"), endpoint) ==
             {:error, {:result, :invalid_shape}}

    bad_result = Map.put(reply["payload"], "attempt_id", "late")

    assert RR.accept_reply(request, Map.put(reply, "payload", bad_result), endpoint) ==
             {:error, {:correlation, :attempt_mismatch}}
  end

  test "source audit has no foreign axioms, holes or unchecked totality and no duplicate record tags" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for field <- [:unaudited, :unresolved, :holes, :axioms, :not_proven_total],
        do: assert(Map.fetch!(audit, field) == [])

    assert audit.absurd == 0
    assert Regex.scan(~r/^\s*rec\s+(\w+)/m, @source) == []

    tags =
      Path.wildcard("pieces/**/*.cure")
      |> Enum.flat_map(fn path ->
        Regex.scan(~r/^\s*rec\s+(\w+)/m, File.read!(path), capture: :all_but_first)
        |> List.flatten()
      end)

    assert length(tags) == length(Enum.uniq(tags))
  end
end
