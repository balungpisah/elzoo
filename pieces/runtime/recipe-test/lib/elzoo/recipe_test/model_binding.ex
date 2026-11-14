# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeTest.ModelBinding do
  @moduledoc "EffectIntent binding of the scripted model calls."

  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.RecipeTest.ScriptedAdapter,
    id: "recipe-test-model",
    provider_account: "scripted",
    operation: "call",
    clock: "unix-ms",
    failures: %{timeout: {"timed_out", "unknown", "unavailable"}}
end
