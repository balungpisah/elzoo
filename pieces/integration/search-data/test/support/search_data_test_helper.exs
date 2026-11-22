# SPDX-License-Identifier: Apache-2.0
Postgrex.Types.define(
  Elzoo.SearchData.TestTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)

defmodule Elzoo.SearchData.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.SearchData.RestrictedRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.SearchData.TextRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.SearchData.QualifiedRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.SearchData.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.SearchData.ShortRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.SearchData.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

# Never started: a call that reaches the Repo fails, so a refusal through it came before any query.
defmodule Elzoo.SearchData.DownRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.SearchData.AppRole do
  @moduledoc false
  # after_connect of every application connection (ELZ-285).
  def set(conn, role), do: Postgrex.query!(conn, ~s(SET ROLE "#{role}"), [])

  # Telemetry handler: forward each query of the Repo to the test process.
  def forward(_event, _measurements, meta, pid), do: send(pid, {:query, meta.query, meta.result})
end

defmodule Elzoo.SearchData.FloorMigration do
  @moduledoc false
  use Ecto.Migration

  def up, do: Elzoo.SearchData.Migration.protect(:persistent_term.get({__MODULE__, :binding}))
end
