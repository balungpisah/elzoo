# SPDX-License-Identifier: Apache-2.0
{:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.ExampleRegistry)
{:ok, _} = Registry.register(Elzoo.ExampleRegistry, "worker", :metadata)
IO.inspect(Registry.lookup(Elzoo.ExampleRegistry, "worker"))
Supervisor.stop(registry)
