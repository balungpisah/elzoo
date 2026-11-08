# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Money.Codec do
  @moduledoc """
  Canonical bytes for an amount, with the registry version it was resolved
  under, so old records keep their identity and exponent after a registry update:

      elzoo-money/1 2026-09-17 BHD 048 3 1234

  Fields: format tag, registry version, alpha code, three-digit numeric code,
  minor-unit exponent, signed integer minor units. `decode/2` accepts only the
  canonical form `encode/1` writes. Persisting the bytes is the caller's Store;
  this module makes no storage or durability claim.
  """
  alias Elzoo.Money
  alias Elzoo.Money.{Amount, Registry}

  @tag "elzoo-money/1"

  @doc "Encode a registry-member amount."
  def encode(amount, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with {:ok, _} <- Money.to_decimal(amount, registry: registry) do
      c = amount.currency
      numeric = c.numeric |> Integer.to_string() |> String.pad_leading(3, "0")
      {:ok, Enum.join([@tag, c.version, c.alpha, numeric, c.minor_unit, amount.minor_units], " ")}
    end
  end

  @doc """
  Decode canonical bytes. Wrong shape or a non-canonical integer is
  `malformed_amount`; a version not held is `unknown_registry_version`; an
  alpha held in no version is `unknown_currency`; an identity that is not the
  one in effect at the stated version is `forged_currency`.
  """
  def decode(bytes, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with {:ok, version, alpha, numeric, exponent, minor} <- fields(bytes) do
      entry = Registry.entry(registry, version, alpha)

      cond do
        not Registry.held?(registry, version) ->
          {:error, {:unknown_registry_version, version}}

        entry && entry.numeric == numeric && entry.minor_unit == exponent ->
          {:ok, %Amount{currency: Money.currency(entry, version), minor_units: minor}}

        entry || Enum.any?(registry.versions, &Registry.entry(registry, &1, alpha)) ->
          {:error, {:forged_currency, %{version: version, alpha: alpha, numeric: numeric, exponent: exponent}}}

        true ->
          {:error, {:unknown_currency, alpha}}
      end
    end
  end

  defp fields(bytes) when is_binary(bytes) and byte_size(bytes) <= 128 do
    with [@tag, version, alpha, numeric, exponent, minor] <- String.split(bytes, " "),
         true <- Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, version),
         true <- Regex.match?(~r/\A[A-Z]{3}\z/, alpha),
         true <- Regex.match?(~r/\A\d{3}\z/, numeric),
         true <- Regex.match?(~r/\A(0|[1-9][0-9]?)\z/, exponent),
         true <- Regex.match?(~r/\A(0|-?[1-9][0-9]*)\z/, minor) do
      {:ok, version, alpha, String.to_integer(numeric), String.to_integer(exponent),
       String.to_integer(minor)}
    else
      _ -> {:error, {:malformed_amount, bytes}}
    end
  end

  defp fields(bytes), do: {:error, {:malformed_amount, bytes}}
end
