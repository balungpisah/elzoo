# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EgressPolicy do
  @moduledoc """
  Decides whether an outbound URL supplied by a tenant or a model may be contacted.

  Admitted means an `https` URL to an exact allowlisted DNS name and port, all of
  whose resolved addresses are public. `check/2` is pure; `resolve/3` calls the
  injected resolver Need once, after `check/2` passes. Errors are fixed atoms and
  never echo the URL or host. The module reads no clock, opens no socket and
  emits no telemetry or log.
  """

  import Bitwise

  @enforce_keys [:hosts, :ports]
  defstruct [:hosts, :ports]

  @opaque t :: %__MODULE__{hosts: MapSet.t(String.t()), ports: MapSet.t(pos_integer())}

  @type check_reason :: :malformed | :scheme | :host | :not_allowed | :port
  @type resolve_reason :: check_reason() | :dns_failed | :unavailable | :non_public_address
  @type resolver :: (String.t() ->
                       {:ok, [:inet.ip_address()]}
                       | {:error, :nxdomain}
                       | {:error, :unavailable})

  @invalid "invalid Elzoo.EgressPolicy options"
  @max_url_bytes 2048
  @max_hosts 256
  @max_ports 16
  @max_addresses 32

  # Refused IPv4 ranges: {network, prefix length}.
  @v4_refused [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  # IPv6 outside ::ffff:0:0/96 is public only inside 2000::/3 and outside these.
  @v6_global {{0x2000, 0, 0, 0, 0, 0, 0, 0}, 3}
  @v6_refused [
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    {{0x3FFF, 0, 0, 0, 0, 0, 0, 0}, 20}
  ]

  @doc """
  Builds a policy from exactly `hosts:` (1..256 unique names that satisfy the
  name rule as given) and `ports:` (1..16 unique integers in 1..65_535).

  Raises `ArgumentError` with a fixed message that contains no option data.
  """
  @spec policy(keyword()) :: t()
  def policy(opts) do
    with {:ok, hosts, ports} <- options(opts),
         {:ok, hosts} <- members(hosts, @max_hosts, &name?/1),
         {:ok, ports} <- members(ports, @max_ports, &(is_integer(&1) and &1 in 1..65_535)) do
      %__MODULE__{hosts: hosts, ports: ports}
    else
      _ -> raise ArgumentError, @invalid
    end
  end

  @doc """
  Checks `url` against `policy` without I/O.

  Returns `{:ok, %{host: host, port: port}}` with the host lowercased and the
  port explicit or 443, or `{:error, reason}`.
  """
  @spec check(term(), t()) ::
          {:ok, %{host: String.t(), port: pos_integer()}} | {:error, check_reason()}
  def check(url, %__MODULE__{hosts: hosts, ports: ports}) do
    with {:ok, %URI{scheme: scheme, host: host, port: port}} <- parse(url) do
      host = String.downcase(host, :ascii)

      cond do
        scheme != "https" -> {:error, :scheme}
        not name?(host) -> {:error, :host}
        not MapSet.member?(hosts, host) -> {:error, :not_allowed}
        not MapSet.member?(ports, port) -> {:error, :port}
        true -> {:ok, %{host: host, port: port}}
      end
    end
  end

  @doc """
  Runs `check/2`, then calls `resolver.(host)` exactly once and admits the URL
  only when every resolved address is public.

  The returned `addresses` are distinct and in Erlang term order; the caller
  must connect only to one of them.
  """
  @spec resolve(term(), t(), resolver()) ::
          {:ok, %{host: String.t(), port: pos_integer(), addresses: [:inet.ip_address()]}}
          | {:error, resolve_reason()}
  def resolve(url, policy, resolver) do
    with {:ok, %{host: host} = target} <- check(url, policy),
         {:ok, addresses} <- lookup(resolver, host) do
      if Enum.all?(addresses, &public?/1) do
        {:ok, Map.put(target, :addresses, addresses |> Enum.uniq() |> Enum.sort())}
      else
        {:error, :non_public_address}
      end
    end
  end

  defp options([{:hosts, hosts}, {:ports, ports}]), do: {:ok, hosts, ports}
  defp options([{:ports, ports}, {:hosts, hosts}]), do: {:ok, hosts, ports}
  defp options(_opts), do: :error

  # Walks at most `max` elements; refuses improper, empty, oversized, invalid or duplicate lists.
  defp members(list, max, valid?), do: members(list, max, valid?, MapSet.new())

  defp members([], _max, _valid?, set) do
    if MapSet.size(set) > 0, do: {:ok, set}, else: :error
  end

  defp members([item | rest], max, valid?, set) do
    if MapSet.size(set) < max and valid?.(item) and not MapSet.member?(set, item) do
      members(rest, max, valid?, MapSet.put(set, item))
    else
      :error
    end
  end

  defp members(_improper, _max, _valid?, _set), do: :error

  defp parse(url) when is_binary(url) and byte_size(url) in 1..@max_url_bytes do
    case URI.new(url) do
      {:ok, %URI{host: host, userinfo: nil, fragment: nil} = uri}
      when is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :malformed}
    end
  end

  defp parse(_url), do: {:error, :malformed}

  defp name?(host) when is_binary(host) and byte_size(host) <= 253 do
    labels = String.split(host, ".")

    length(labels) in 2..127 and Enum.all?(labels, &label?/1) and
      not numeric_label?(List.last(labels))
  end

  defp name?(_host), do: false

  defp label?(label) do
    byte_size(label) in 1..63 and label_bytes?(label) and :binary.first(label) != ?- and
      :binary.last(label) != ?-
  end

  defp label_bytes?(<<byte, rest::binary>>)
       when byte in ?a..?z or byte in ?0..?9 or byte == ?-,
       do: label_bytes?(rest)

  defp label_bytes?(<<>>), do: true
  defp label_bytes?(_label), do: false

  # WHATWG and :inet.parse_address/1 read such a last label as IPv4.
  defp numeric_label?("0x" <> hex), do: hex_digits?(hex)
  defp numeric_label?(label), do: decimal_digits?(label)

  defp hex_digits?(<<byte, rest::binary>>) when byte in ?0..?9 or byte in ?a..?f,
    do: hex_digits?(rest)

  defp hex_digits?(<<>>), do: true
  defp hex_digits?(_label), do: false

  defp decimal_digits?(<<byte, rest::binary>>) when byte in ?0..?9, do: decimal_digits?(rest)
  defp decimal_digits?(<<>>), do: true
  defp decimal_digits?(_label), do: false

  defp lookup(resolver, host) do
    answer =
      try do
        resolver.(host)
      catch
        _kind, _reason -> :failed
      end

    case answer do
      {:error, :nxdomain} ->
        {:error, :dns_failed}

      {:ok, []} ->
        {:error, :dns_failed}

      {:ok, addresses} ->
        if addresses?(addresses, @max_addresses),
          do: {:ok, addresses},
          else: {:error, :unavailable}

      _other ->
        {:error, :unavailable}
    end
  end

  defp addresses?([], _left), do: true

  defp addresses?([address | rest], left) when left > 0,
    do: address?(address) and addresses?(rest, left - 1)

  defp addresses?(_addresses, _left), do: false

  defp address?(address) when tuple_size(address) == 4, do: fields?(address, 0xFF)
  defp address?(address) when tuple_size(address) == 8, do: fields?(address, 0xFFFF)
  defp address?(_address), do: false

  defp fields?(address, max) do
    address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= max))
  end

  defp public?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: public_v4?(high <<< 16 ||| low)
  defp public?(address) when tuple_size(address) == 4, do: public_v4?(to_integer(address, 8))

  defp public?(address) do
    value = to_integer(address, 16)

    within?(value, 128, @v6_global) and
      not Enum.any?(@v6_refused, &within?(value, 128, &1))
  end

  defp public_v4?(value), do: not Enum.any?(@v4_refused, &within?(value, 32, &1))

  defp within?(value, bits, {network, length}) do
    shift = bits - length
    value >>> shift == to_integer(network, div(bits, tuple_size(network))) >>> shift
  end

  defp to_integer(address, field_bits) do
    address |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< field_bits ||| &1))
  end
end
