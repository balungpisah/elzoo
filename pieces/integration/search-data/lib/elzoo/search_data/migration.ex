# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.SearchData.Migration do
  @moduledoc """
  Install an immutable index declaration, its fixed-dimension vector table and its delete-mark
  table; never creates the extension. `protect/1` puts both tables under the
  `state/tenant-isolation` floor from a consumer's Ecto migration.
  """
  alias Elzoo.SearchData, as: Store
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @protect_message "search data binding has no tenant_isolation option"

  def install(binding) do
    with :ok <- Store.validate_binding(binding) do
      Store.transaction(binding, :install, nil, fn ->
        # Prefix-wide serialization also protects first creation of the registry.
        Store.lock!(
          %{binding | declaration: %{binding.declaration | index_identity: "registry"}},
          :migration
        )

        # Before anything is created: a text-search index needs a UTF-8 database and a
        # pg_catalog configuration of the declared name.
        text_search = Map.get(binding.declaration, :text_search)
        if text_search, do: check_text_search!(binding, text_search.config)

        Store.sql!(
          binding,
          """
          CREATE TABLE IF NOT EXISTS #{Store.registry(binding)}
          (index_identity text PRIMARY KEY, descriptor bytea NOT NULL, table_name text UNIQUE NOT NULL)
          """,
          []
        )

        result =
          Store.sql!(
            binding,
            "SELECT descriptor FROM #{Store.registry(binding)} WHERE index_identity=$1",
            [binding.declaration.index_identity]
          )

        case result.rows do
          [[bytes]] ->
            if bytes != Store.declaration_bytes(binding.declaration),
              do: binding.repo.rollback({:refused, :incompatible_embedding})

          [] ->
            Store.sql!(binding, "INSERT INTO #{Store.registry(binding)} VALUES($1,$2,$3)", [
              binding.declaration.index_identity,
              Store.declaration_bytes(binding.declaration),
              Store.table_name(binding.declaration.index_identity)
            ])
        end

        dimensions = binding.declaration.descriptor.dimensions
        # convert_from is not immutable, so the tsvector is a plain column filled by the INSERT.
        text_column = if text_search, do: "text_vector tsvector NOT NULL,", else: ""

        Store.sql!(
          binding,
          """
          CREATE TABLE IF NOT EXISTS #{Store.table(binding)} (
            tenant text NOT NULL, source_ref text NOT NULL, version bigint NOT NULL,
            chunk_index integer NOT NULL, content bytea NOT NULL, content_digest bytea NOT NULL,
            source_digest bytea NOT NULL, start_byte bigint NOT NULL, end_byte bigint NOT NULL,
            embedding vector(#{dimensions}) NOT NULL, embedding_descriptor bytea NOT NULL,
            embedding_provenance bytea NOT NULL, batch_index integer NOT NULL, #{text_column}
            PRIMARY KEY(tenant,source_ref,version,chunk_index),
            CHECK(version > 0 AND chunk_index >= 0 AND start_byte >= 0 AND end_byte > start_byte),
            CHECK(octet_length(content_digest)=32 AND octet_length(source_digest)=32),
            CHECK(octet_length(content)>0 AND octet_length(content)<=1048576),
            CHECK(end_byte-start_byte=octet_length(content))
          )
          """,
          []
        )

        if text_search do
          name = Store.identifier(Store.table_name(binding.declaration.index_identity) <> "_text")

          Store.sql!(
            binding,
            "CREATE INDEX IF NOT EXISTS #{name} ON #{Store.table(binding)} USING gin (text_vector)",
            []
          )
        end

        # Also created by a re-run over an index installed before delete marks existed.
        Store.sql!(
          binding,
          """
          CREATE TABLE IF NOT EXISTS #{Store.marks(binding)} (
            tenant text NOT NULL, source_ref text NOT NULL, version bigint NOT NULL,
            PRIMARY KEY(tenant,source_ref), CHECK(version > 0)
          )
          """,
          []
        )

        {:ok, binding}
      end)
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp check_text_search!(binding, config) do
    %{rows: [[encoding, found]]} =
      Store.sql!(
        binding,
        """
        SELECT pg_catalog.getdatabaseencoding(),
               EXISTS(SELECT 1 FROM pg_catalog.pg_ts_config c
                      JOIN pg_catalog.pg_namespace n ON n.oid=c.cfgnamespace
                      WHERE n.nspname='pg_catalog' AND c.cfgname=$1)
        """,
        [config]
      )

    cond do
      encoding != "UTF8" -> binding.repo.rollback({:refused, :database_encoding})
      not found -> binding.repo.rollback({:refused, :unknown_text_search_config})
      true -> :ok
    end
  end

  @doc """
  From the `up/0` of a consumer Ecto migration, after the run-time `install/1` of the index:
  install the `state/tenant-isolation` readers in the binding's `tenant_isolation` prefix and
  protect the vector table and the delete-mark table (`tenant_column: "tenant"`,
  `space_column: nil`). A binding without `tenant_isolation` raises `ArgumentError` before any DDL.
  """
  def protect(binding) do
    p =
      case {Store.validate_binding(binding), binding} do
        {:ok, %{tenant_isolation: %{prefix: p}}} -> p
        _ -> raise ArgumentError, @protect_message
      end

    Floor.install(p)
    id = binding.declaration.index_identity

    for name <- [Store.table_name(id), Store.mark_name(id)],
        do:
          Floor.protect({binding.prefix, name},
            prefix: p,
            tenant_column: "tenant",
            space_column: nil
          )

    :ok
  end
end
