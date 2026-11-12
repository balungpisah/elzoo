# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Secrets do
  @moduledoc """
  Opt-in scoped release of a consumer-owned credential snapshot.

  `resolve/2` accepts an exact `%{ref: binary, scope: binary}` request and
  trusted host context containing `grant`, a two-argument `resolver`, and an
  optional zero-argument Unix-millisecond `clock`. The host supplies fresh
  authority; identifiers do not authenticate a caller. Callbacks execute
  synchronously, without caching, retries or a timeout process.

  Success is valid only at the post-lookup expiry sample. Previously released
  bytes cannot be recalled. See the README for the exact schemas and limits.
  """

  alias Elzoo.Secrets.Credential

  @max_integer 9_007_199_254_740_991

  @doc "Resolve one exact reference and scope under trusted host authority."
  def resolve(request, context) do
    cond do
      not binding?(request) ->
        {:error, :malformed}

      not context?(context) ->
        {:error, :unavailable}

      context.grant != request ->
        {:error, :denied}

      true ->
        lookup(request, context)
    end
  end

  @doc "Reveal bytes for trusted injection code; does not recheck expiry or revocation."
  def reveal(%Credential{value: value}), do: value

  defp binding?(%{ref: ref, scope: scope} = binding)
       when is_map(binding) and not is_struct(binding) and map_size(binding) == 2 and
              is_binary(ref) and byte_size(ref) in 1..128 and
              is_binary(scope) and byte_size(scope) in 1..128,
       do: true

  defp binding?(_), do: false

  defp context?(%{grant: grant, resolver: resolver} = context)
       when not is_struct(context) and map_size(context) in 2..3 and is_function(resolver, 2) do
    keys = Map.keys(context)

    Enum.all?(keys, &(&1 in [:grant, :resolver, :clock])) and
      (grant == :deny or binding?(grant)) and
      (not Map.has_key?(context, :clock) or is_function(context.clock, 0))
  end

  defp context?(_), do: false

  defp lookup(request, context) do
    result =
      try do
        context.resolver.(request.ref, request.scope)
      catch
        _, _ -> {:error, :unavailable}
      end

    case result do
      {:ok, snapshot} -> release(snapshot, request, context)
      {:error, reason} when reason in [:denied, :missing, :unavailable] -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  defp release(
         %{
           ref: ref,
           scope: scope,
           value: value,
           version: version,
           expires_at_unix_ms: expiry
         } = snapshot,
         %{ref: ref, scope: scope},
         context
       )
       when not is_struct(snapshot) and map_size(snapshot) == 5 and
              is_binary(value) and byte_size(value) in 1..16_384 and
              is_integer(version) and version in 1..@max_integer and
              is_integer(expiry) and expiry in 0..@max_integer do
    clock = Map.get(context, :clock, fn -> System.system_time(:millisecond) end)

    now =
      try do
        clock.()
      catch
        _, _ -> :unavailable
      end

    cond do
      not is_integer(now) or now < 0 or now > @max_integer ->
        {:error, :unavailable}

      now >= expiry ->
        {:error, :expired}

      true ->
        {:ok, %Credential{value: value, version: version, expires_at_unix_ms: expiry}}
    end
  end

  defp release(_, _, _), do: {:error, :malformed}
end
