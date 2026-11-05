# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.IngestHost do
  @moduledoc "Consumer-owned Application and one_for_one Unit supervision recipe."
  use Application
  @behaviour Supervisor

  @impl Application
  def start(_type, children), do: start_link(children)

  def start_link(children), do: Supervisor.start_link(__MODULE__, children)

  @impl Supervisor
  def init(children) do
    specs =
      Enum.map(children, fn {id, operator} ->
        %{id: id, start: {Elzoo.Unit, :start_link, [operator]}}
      end)

    Supervisor.init(specs, strategy: :one_for_one)
  end

  def lookup(supervisor, id) do
    case List.keyfind(Supervisor.which_children(supervisor), id, 0) do
      {^id, pid, _, _} -> pid
      nil -> :undefined
    end
  end
end
