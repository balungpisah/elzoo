# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.DiskLogComparisonTest do
  use ExUnit.Case, async: false
  @log :elzoo_durable_log_comparison
  setup do
    file = Path.join(System.user_home!(), "elzoo-disk-log-#{System.unique_integer([:positive])}")
    options = [name: @log, file: String.to_charlist(file), type: :halt, format: :internal]
    assert {:ok, @log} = :disk_log.open(options)

    on_exit(fn ->
      :disk_log.close(@log)
      File.rm(file)
    end)

    %{options: options}
  end

  defp reopen(options) do
    assert :ok = :disk_log.sync(@log)
    assert :ok = :disk_log.close(@log)
    assert {:ok, @log} = :disk_log.open(options)
    {_, terms} = :disk_log.chunk(@log, :start)
    terms
  end

  test "K2 negative: two writers accept the same expected revision without store CAS", %{
    options: options
  } do
    observer = self()

    writers =
      for nonce <- ["first", "second"] do
        Task.async(fn ->
          send(observer, {:ready, self()})

          receive do
            :go -> :disk_log.log(@log, {:record, "s", 1, nonce, "event"})
          end
        end)
      end

    for task <- writers do
      pid = task.pid
      assert_receive {:ready, ^pid}
    end

    Enum.each(writers, &send(&1.pid, :go))
    assert Enum.map(writers, &Task.await/1) == [:ok, :ok]
    terms = reopen(options)
    assert length(terms) == 2
    assert Enum.all?(terms, &match?({:record, "s", 1, _, "event"}, &1))
    IO.puts("disk_log K2 negative: both writers committed sequence 1; no expected-revision CAS")
  end

  test "K4 negative: the log accepts duplicate stream/sequence identities", %{options: options} do
    row = {:record, "s", 1, "nonce", "event"}
    writers = for _ <- 1..2, do: Task.async(fn -> :disk_log.log(@log, row) end)
    assert Enum.map(writers, &Task.await/1) == [:ok, :ok]
    assert reopen(options) == [row, row]
    IO.puts("disk_log K4 negative: duplicate stream/sequence accepted")
  end

  test "K5 negative: writer death between append calls leaves a partial head/record/outbox unit", %{
    options: options
  } do
    observer = self()

    {writer, monitor} =
      spawn_monitor(fn ->
        :ok = :disk_log.log(@log, {:head, 1})
        :ok = :disk_log.log(@log, {:record, "s", 1, "nonce", "event"})
        :ok = :disk_log.sync(@log)
        send(observer, {:before_outbox, self()})

        receive do
          :continue -> :disk_log.log(@log, {:outbox, "s", 1, "effect"})
        end
      end)

    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)
    assert_receive {:before_outbox, ^writer}
    other = Task.async(fn -> :disk_log.log(@log, {:record, "other", 1, "other-nonce", "event"}) end)
    assert :ok = Task.await(other)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}

    assert reopen(options) == [
             {:head, 1},
             {:record, "s", 1, "nonce", "event"},
             {:record, "other", 1, "other-nonce", "event"}
           ]

    IO.puts(
      "disk_log K5 negative: killed multi-call append left head/record without outbox; no transaction rollback"
    )
  end
end
