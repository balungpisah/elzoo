# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RegistryRecipeTest do
  use ExUnit.Case, async: false

  test "OTP Registry owns local unique names and does not provide durable identity" do
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RecipeRegistry)

    try do
      assert {:ok, _} = Registry.register(Elzoo.RecipeRegistry, "worker", :metadata)
      assert Registry.lookup(Elzoo.RecipeRegistry, "worker") == [{self(), :metadata}]
      Registry.unregister(Elzoo.RecipeRegistry, "worker")
      assert Registry.lookup(Elzoo.RecipeRegistry, "worker") == []
    after
      Supervisor.stop(registry)
    end
  end
end
