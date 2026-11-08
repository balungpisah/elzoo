# SPDX-License-Identifier: Apache-2.0
# Reduced raw-byte and lifetime feasibility evidence; not production.
Code.require_file("boundary.exs", __DIR__)

defmodule Elz011Raw do
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= 16_384 do
    with {:ok, term} <- Jason.decode(bytes, keys: :strings, objects: :ordered_objects) do
      try do
        {map, _} = walk(term, 0, 128)
        Elz011Probe.normalize(map)
      catch
        :invalid -> {:error, :receipt_schema}
      end
    else
      _ -> {:error, :receipt_schema}
    end
  end

  def decode(_), do: {:error, :receipt_schema}
  defp walk(_, depth, budget) when depth > 8 or budget < 1, do: throw(:invalid)

  defp walk(%Jason.OrderedObject{values: pairs}, depth, budget) do
    keys = Enum.map(pairs, &elem(&1, 0))
    if length(keys) > 32 or length(Enum.uniq(keys)) != length(keys), do: throw(:invalid)

    {rev, left} =
      Enum.reduce(pairs, {[], budget - 1}, fn {k, v}, {acc, n} ->
        if not is_binary(k) or byte_size(k) > 128, do: throw(:invalid)
        {value, rest} = walk(v, depth + 1, n)
        {[{k, value} | acc], rest}
      end)

    {Map.new(rev), left}
  end

  defp walk(list, depth, budget) when is_list(list) do
    Enum.map_reduce(list, budget - 1, fn x, n -> walk(x, depth + 1, n) end)
  end

  defp walk(value, _, budget), do: {value, budget - 1}
end

defmodule Elz011Timed do
  def run(sup, fun, timeout) do
    task =
      Task.Supervisor.async(sup, fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :unknown}
        catch
          _, _ -> {:error, :unknown}
        end
      end)

    case Task.yield(task, timeout) do
      {:ok, value} ->
        value

      {:exit, _} ->
        {:error, :unknown}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :total_timeout}
    end
  end

  def drip do
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(l)
    parent = self()

    server =
      Task.async(fn ->
        try do
          {:ok, s} = :gen_tcp.accept(l, 3000)
          {:ok, _} = :gen_tcp.recv(s, 0, 3000)
          send(parent, :request_received)
          :gen_tcp.send(s, "HTTP/1.1 200 OK\r\ncontent-length: 20\r\nconnection: close\r\n\r\n")

          for _ <- 1..20 do
            :gen_tcp.send(s, "x")
            Process.sleep(50)
          end

          :gen_tcp.close(s)
        after
          :gen_tcp.close(l)
        end
      end)

    {"http://127.0.0.1:#{port}/p", server}
  end
end

# Actual function mutations: compile isolated copies of the function under test.
base =
  File.read!(Path.join(__DIR__, "boundary.exs"))
  |> String.split("defmodule Elz011Probe do", parts: 2)
  |> List.last()
  |> String.split("  def request(", parts: 2)
  |> hd()

for {name, before, after_text} <- [
      {Elz011RetainMutant, "\"trust\" => \"untrusted\"",
       "\"trust\" => \"untrusted\", \"secret\" => map[\"secret\"]"},
      {Elz011TrustMutant, "\"trust\" => \"untrusted\"", "\"trust\" => map[\"trust\"]"},
      {Elz011AckMutant, "ack when is_boolean(ack) <- map[\"ack\"]",
       "ack <- (map[\"ack\"] || true)"},
      {Elz011AtomMutant, "with 1 <- map[\"version\"],",
       "Enum.each(Map.keys(map), &String.to_atom/1)\n    with 1 <- map[\"version\"],"}
    ] do
  true = String.contains?(base, before)

  Code.compile_string(
    "defmodule #{inspect(name)} do" <> String.replace(base, before, after_text) <> "end"
  )
end

defmodule Elz011TimingJsonTest do
  use ExUnit.Case, async: false

  defp map,
    do: %{
      "version" => 1,
      "key" => String.duplicate("b", 64),
      "digest" => String.duplicate("a", 64),
      "kind" => "publication",
      "ack" => true
    }

  test "raw JSON duplicate rejection including escaped keys precedes map conversion" do
    valid = Jason.encode!(map())
    assert {:ok, _} = Elz011Raw.decode(valid)

    for duplicate <- ["\"ack\":false,", "\"\\u0061ck\":false,"] do
      assert {:error, :receipt_schema} =
               Elz011Raw.decode("{" <> duplicate <> String.trim_leading(valid, "{"))
    end

    nested = Map.put(map(), "extra", %{"inner" => true}) |> Jason.encode!()
    nested = String.replace(nested, "\"inner\":true", "\"inner\":false,\"inner\":true")
    assert {:error, :receipt_schema} = Elz011Raw.decode(nested)
  end

  test "raw JSON validates version numeric type, ack type, and depth/node/bytes" do
    for field <- [%{map() | "version" => 1.0}, %{map() | "ack" => 1}, %{map() | "ack" => "true"}] do
      assert {:error, :receipt_schema} = Elz011Raw.decode(Jason.encode!(field))
    end

    deep = Enum.reduce(1..9, true, fn _, acc -> [acc] end)

    for extra <- [deep, Enum.to_list(1..130), String.duplicate("x", 16_384)] do
      assert {:error, :receipt_schema} =
               Elz011Raw.decode(Jason.encode!(Map.put(map(), "extra", extra)))
    end

    assert {:error, :receipt_schema} = Elz011Raw.decode(<<255>>)
  end

  test "raw string keys remain uninterned and normalization is idempotent" do
    key = "elz011_raw_#{System.unique_integer([:positive])}"
    raw = Map.merge(map(), %{key => "ignored", "trust" => "trusted", "kind" => key})
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert {:ok, n} = Elz011Raw.decode(Jason.encode!(raw))
    assert n["trust"] == "untrusted"
    assert n["kind"] == key
    refute Map.has_key?(n, key)
    assert Elz011Probe.normalize(n) == {:ok, n}
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "real function mutants fail retained-field, trust, ack and no-atom properties" do
    raw = Map.merge(map(), %{"secret" => "secret", "trust" => "trusted"})
    assert {:ok, original} = Elz011Probe.normalize(raw)
    refute Map.has_key?(original, "secret")
    {:ok, retained} = Elz011RetainMutant.normalize(raw)
    assert Map.has_key?(retained, "secret")
    {:ok, trusted} = Elz011TrustMutant.normalize(raw)
    refute trusted["trust"] == "untrusted"
    assert {:error, :receipt_schema} = Elz011Probe.normalize(Map.delete(raw, "ack"))
    assert {:ok, _} = Elz011AckMutant.normalize(Map.delete(raw, "ack"))
    key = "elz011_mutant_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert {:ok, _} = Elz011AtomMutant.normalize(Map.put(raw, key, "x"))
    assert is_atom(String.to_existing_atom(key))
  end

  test "slow drip exceeds per-read timeout but real outer timer caps lifetime; timer-removal mutant fails" do
    sup = start_supervised!({Task.Supervisor, max_children: 1})
    {url, server} = Elz011Timed.drip()
    t = System.monotonic_time(:millisecond)

    assert {:error, :total_timeout} =
             Elz011Timed.run(sup, fn -> Elz011Probe.request(:req, url, "{}", 200) end, 250)

    elapsed = System.monotonic_time(:millisecond) - t
    assert elapsed < 800
    assert_receive :request_received
    assert Task.Supervisor.children(sup) == []
    Task.shutdown(server, :brutal_kill)
    {url2, server2} = Elz011Timed.drip()
    t2 = System.monotonic_time(:millisecond)
    # Actual same request call with outer timer removed.
    assert {:ok, 200, _} = Elz011Probe.request(:req, url2, "{}", 200)
    assert System.monotonic_time(:millisecond) - t2 >= 800
    assert_receive :request_received
    Task.await(server2)
  end

  test "killing the outer request caller also kills its linked bounded child" do
    sup = start_supervised!({Task.Supervisor, max_children: 1})
    parent = self()

    outer =
      spawn(fn ->
        Elz011Timed.run(
          sup,
          fn ->
            send(parent, {:inner, self()})
            Process.sleep(:infinity)
          end,
          3000
        )
      end)

    assert_receive {:inner, inner}, 1000
    ref = Process.monitor(inner)
    Process.exit(outer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^inner, :killed}, 1000
    assert Task.Supervisor.children(sup) == []
  end

  test "bounded wrapper also stops hung preparation/authenticator or observer callback" do
    sup = start_supervised!({Task.Supervisor, max_children: 1})

    assert {:error, :unknown} = Elz011Timed.run(sup, fn -> throw(:observer_fault) end, 100)
    assert {:error, :unknown} = Elz011Timed.run(sup, fn -> raise "callback failure" end, 100)

    for _stage <- [:preparation, :authenticator, :observer] do
      assert {:error, :total_timeout} = Elz011Timed.run(sup, fn -> Process.sleep(:infinity) end, 20)
      assert Task.Supervisor.children(sup) == []
    end
  end
end
