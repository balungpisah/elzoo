# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcess.Provider do
  @moduledoc """
  Starts the erlexec provider application when it is not running yet.

  erlexec's port program refuses to run as root unless it is given an effective user. When the
  VM's effective user id is 0 (observed with the host `id -u` utility) and the consumer has not
  configured erlexec's `root`/`user` application environment, this module sets `root: true` and
  `user: provider_user` (default `"nobody"`), so the port program and every child run as that
  unprivileged user. erlexec also requires `SHELL` in the environment; when it is unset this
  module sets it to `/bin/sh` for the VM. A consumer that starts erlexec itself (its own
  application tree and configuration) is used as is.
  """

  @doc "`:ok` when the provider runs, else `{:error, {:provider_start_failed, reason}}`."
  def ensure_started(provider_user \\ "nobody") when is_binary(provider_user) do
    if is_pid(Process.whereis(:exec)) do
      :ok
    else
      with :ok <- load() do
        configure(provider_user)

        case Application.ensure_all_started(:erlexec) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:provider_start_failed, reason}}
        end
      end
    end
  end

  @doc "True when the VM's effective user id is 0, observed with `id -u`."
  def root? do
    case System.find_executable("id") do
      nil -> false
      id -> match?({"0\n", 0}, System.cmd(id, ["-u"], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  defp load do
    case Application.load(:erlexec) do
      :ok -> :ok
      {:error, {:already_loaded, :erlexec}} -> :ok
      {:error, reason} -> {:error, {:provider_start_failed, reason}}
    end
  end

  defp configure(provider_user) do
    if System.get_env("SHELL") in [nil, ""], do: System.put_env("SHELL", "/bin/sh")

    unconfigured? =
      Application.get_env(:erlexec, :root) in [nil, false] and
        Application.get_env(:erlexec, :user) in [nil, ""]

    if root?() and unconfigured? do
      Application.put_env(:erlexec, :root, true)
      Application.put_env(:erlexec, :user, String.to_charlist(provider_user))
    end

    :ok
  end
end
