# SPDX-License-Identifier: Apache-2.0
policy = Elzoo.EgressPolicy.policy(hosts: ["api.example.com"], ports: [443, 8443])

# A fixed resolver keeps the example offline; the README shows an :inet recipe.
public = fn _host -> {:ok, [{0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}, {8, 8, 8, 8}]} end
rebound = fn _host -> {:ok, [{8, 8, 8, 8}, {10, 0, 0, 1}]} end

IO.inspect(Elzoo.EgressPolicy.check("https://API.example.com:8443/v1", policy))
IO.inspect(Elzoo.EgressPolicy.check("https://127.0.0.1/", policy))
IO.inspect(Elzoo.EgressPolicy.resolve("https://api.example.com/v1?q=1", policy, public))
IO.inspect(Elzoo.EgressPolicy.resolve("https://api.example.com/v1", policy, rebound))
