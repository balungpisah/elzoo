# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TenantIsolation.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration (call it from `up/0`; nothing here is reversible).

  `install/1` creates the two `STABLE` setting readers in schema `prefix`. `protect/2` enables
  and forces row-level security on a table and creates the restrictive `elzoo_tenant_floor`
  policy and the permissive `elzoo_tenant_allow` policy. Every identifier must match
  `^[a-z_][a-z0-9_]{0,62}$` and is quoted; anything else raises `ArgumentError` with a fixed
  message before any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]

  @message "invalid tenant isolation identifier or options"
  @option_keys [:prefix, :space_column, :tenant_column]

  @doc "Create `prefix.elzoo_tenant_id()` and `prefix.elzoo_space_ids()`."
  def install(prefix) do
    p = identifier!(prefix)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.elzoo_tenant_id() RETURNS text LANGUAGE sql STABLE
    AS $$ SELECT NULLIF(current_setting('elzoo.tenant_id', true), '') $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION #{p}.elzoo_space_ids() RETURNS text[] LANGUAGE sql STABLE
    AS $$ SELECT COALESCE(NULLIF(current_setting('elzoo.space_ids', true), '')::text[], '{}') $$
    """)
  end

  @doc """
  Enable and force row-level security on `table` (`"name"` or `{schema, name}`) and create the
  floor and allow policies. Options: exactly `prefix:`, `tenant_column:` and `space_column:`
  (`nil` for a flat table).
  """
  def protect(table, opts) do
    %{table: t, floor: floor} = policy!(table, opts)
    execute("ALTER TABLE #{t} ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE #{t} FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY elzoo_tenant_floor ON #{t} AS RESTRICTIVE FOR ALL TO PUBLIC USING (#{floor}) WITH CHECK (#{floor})"
    )

    execute(
      "CREATE POLICY elzoo_tenant_allow ON #{t} AS PERMISSIVE FOR ALL TO PUBLIC USING (true) WITH CHECK (true)"
    )
  end

  @doc false
  # The quoted table name, the floor expression and the quoted distinct protected columns,
  # shared by protect/2 and Elzoo.TenantIsolation.verify/3.
  def policy!(table, opts) do
    unless Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == @option_keys,
      do: raise(ArgumentError, @message)

    p = identifier!(opts[:prefix])
    tenant = identifier!(opts[:tenant_column])
    tenant_floor = "#{tenant} = (SELECT #{p}.elzoo_tenant_id())"

    {floor, columns} =
      case opts[:space_column] do
        nil ->
          {tenant_floor, [opts[:tenant_column]]}

        space ->
          s = identifier!(space)

          {"#{tenant_floor} AND #{s} = ANY ((SELECT #{p}.elzoo_space_ids())::text[])",
           Enum.uniq([opts[:tenant_column], space])}
      end

    %{table: table!(table), floor: floor, columns: columns}
  end

  defp table!({schema, name}), do: identifier!(schema) <> "." <> identifier!(name)
  defp table!(name), do: identifier!(name)

  defp identifier!(name) do
    if is_binary(name) and name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/,
      do: ~s("#{name}"),
      else: raise(ArgumentError, @message)
  end
end
