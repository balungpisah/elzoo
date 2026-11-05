# SPDX-License-Identifier: Apache-2.0
child = %{id: :counter, start: {Agent, :start_link, [fn -> 0 end]}}
{:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)
IO.inspect(Supervisor.which_children(supervisor))
Supervisor.stop(supervisor)
