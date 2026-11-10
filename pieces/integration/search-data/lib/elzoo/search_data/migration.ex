# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.SearchData.Migration do
  @moduledoc "Install an immutable index declaration and fixed-dimension vector table; never creates the extension."
  alias Elzoo.SearchData, as: Store

  def install(binding) do
    with {:ok, ^binding} <-
           Store.new(binding.repo, binding.declaration,
             prefix: binding.prefix,
             statement_timeout_ms: binding.statement_timeout_ms
           ) do
      Store.transaction(binding, :install, fn ->
        # Prefix-wide serialization also protects first creation of the registry.
        Store.lock!(
          %{binding | declaration: %{binding.declaration | index_identity: "registry"}},
          :migration
        )

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

        Store.sql!(
          binding,
          """
          CREATE TABLE IF NOT EXISTS #{Store.table(binding)} (
            tenant text NOT NULL, source_ref text NOT NULL, version bigint NOT NULL,
            chunk_index integer NOT NULL, content bytea NOT NULL, content_digest bytea NOT NULL,
            source_digest bytea NOT NULL, start_byte bigint NOT NULL, end_byte bigint NOT NULL,
            embedding vector(#{dimensions}) NOT NULL, embedding_descriptor bytea NOT NULL,
            embedding_provenance bytea NOT NULL, batch_index integer NOT NULL,
            PRIMARY KEY(tenant,source_ref,version,chunk_index),
            CHECK(version > 0 AND chunk_index >= 0 AND start_byte >= 0 AND end_byte > start_byte),
            CHECK(octet_length(content_digest)=32 AND octet_length(source_digest)=32),
            CHECK(octet_length(content)>0 AND octet_length(content)<=1048576),
            CHECK(end_byte-start_byte=octet_length(content))
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
end
