defmodule Elzoo.Application do
  @moduledoc """
  OTP host for the Elzoo runtime sample.

  The decision code itself lives in Cure. This application owns only the
  lifecycle boundary used by the executable example.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: Elzoo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
