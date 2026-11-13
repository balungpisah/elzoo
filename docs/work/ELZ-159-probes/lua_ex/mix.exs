defmodule LuaFit.MixProject do
  use Mix.Project

  def project,
    do: [app: :lua_fit, version: "0.0.0", elixir: "~> 1.20", deps: [{:lua, "== 1.0.2"}]]

  def application, do: [extra_applications: [:logger]]
end
