# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeTest.RecordFixture do
  import ExUnit.Assertions

  @sha256 %{
    scripted_agent: "47b89eeb004881e2cca32372a92d73ca71cef345af7a2bbd88b7887174a2d588",
    decision_graph: "ad10d47e1fb53258f54e9c42d70202a458403799e2a74e53deb8112f4a56f3ad",
    lua_module_call: "657bce1a7100a4453898304a385aded2c17687a20a85e2442a2e65a76da25c42",
    model_graph_after_restart: "6b590d899d3eed4f11ed70e3bd43954c6ae641a48e403df9d8854fa3bd5fed46"
  }

  def assert_record(name, record) do
    bytes = File.read!(Path.expand("../fixtures/recipe-test/#{name}.etf", __DIR__))
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == Map.fetch!(@sha256, name)
    assert record === :erlang.binary_to_term(bytes, [:safe])
  end
end
