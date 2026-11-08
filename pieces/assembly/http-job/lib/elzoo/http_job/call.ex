# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpJob.Call do
  @moduledoc false
  # A separate bounded Task.Supervisor per owner/runner. Links stop a child when
  # its caller dies; timeout cannot undo an already queued owner operation.
  def run(supervisor, timeout, fun) do
    task =
      Task.Supervisor.async(supervisor, fn ->
        try do
          {:value, fun.()}
        rescue
          _ -> :fault
        catch
          _, _ -> :fault
        end
      end)

    case Task.yield(task, timeout) do
      {:ok, {:value, value}} ->
        {:ok, value}

      {:ok, :fault} ->
        {:error, :call_failed}

      {:exit, _} ->
        {:error, :call_failed}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :call_timeout}
    end
  rescue
    _ -> {:error, :call_unavailable}
  catch
    _, _ -> {:error, :call_unavailable}
  end
end
