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
        release(supervisor, task)
        {:ok, value}

      {:ok, :fault} ->
        release(supervisor, task)
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

  # ELZ-274: a child that has replied still holds its slot until the supervisor
  # handles its exit, so the next call on a full pool could be refused (the
  # owner authenticates a completion on the one-slot transport pool right after
  # the send task). Remove the child synchronously; it has nothing left to do.
  # Unlink first so its shutdown cannot reach the caller; keep the reply if the
  # supervisor is gone.
  defp release(supervisor, task) do
    Process.unlink(task.pid)
    Task.Supervisor.terminate_child(supervisor, task.pid)
  catch
    _, _ -> :ok
  end
end
