# SPDX-License-Identifier: Apache-2.0
defmodule Elz099ProviderConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :elz099_provider_consumer,
      version: "0.1.0",
      elixir: "== 1.20.4",
      deps: [{:fuse, "== 2.5.0"}, {:server_sent_events, "== 1.1.0"}]
    ]
  end
end
