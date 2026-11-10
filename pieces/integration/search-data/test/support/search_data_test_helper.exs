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
