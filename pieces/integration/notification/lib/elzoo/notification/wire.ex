# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Notification.Wire do
  @moduledoc """
  Request bytes (`elzoo/notification-email` v1): exact JSON object with
  `version` 1, `to` (1..50 addresses), `subject`, `text` and `html` (string or
  null). Strict decoding: duplicate or unknown keys are refused.
  """
  @max 65_536
  @fields ~w(html subject text to version)
  def max, do: @max

  @local ~r/\A[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+)*\z/
  @label ~r/\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/

  @doc "Decodes and checks request bytes against `max_bytes` before anything else."
  def request(bytes, max_bytes) when is_binary(bytes) and is_integer(max_bytes) do
    cond do
      byte_size(bytes) > max_bytes or byte_size(bytes) > @max -> {:error, :too_large}
      true -> decode(bytes)
    end
  end

  def request(_, _), do: {:error, :schema}

  defp decode(bytes) do
    with {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(bytes, objects: :ordered_objects),
         keys = Enum.map(pairs, &elem(&1, 0)),
         true <- Enum.sort(keys) == @fields,
         m = Map.new(pairs),
         1 <- m["version"],
         true <- subject?(m["subject"]),
         true <- is_binary(m["text"]) and String.valid?(m["text"]),
         true <- is_nil(m["html"]) or (is_binary(m["html"]) and String.valid?(m["html"])),
         to when is_list(to) and to != [] and length(to) <= 50 <- m["to"] do
      if Enum.all?(to, &address?/1),
        do: {:ok, %{to: to, subject: m["subject"], text: m["text"], html: m["html"]}},
        else: {:error, :invalid_address}
    else
      _ -> {:error, :schema}
    end
  rescue
    _ -> {:error, :schema}
  end

  defp subject?(s),
    do:
      is_binary(s) and byte_size(s) in 1..255 and String.valid?(s) and
        not Regex.match?(~r/\p{Cc}/u, s)

  @doc "ASCII `local@domain`; no CR, LF, NUL, brackets, commas or whitespace."
  def address?(a) when is_binary(a) and byte_size(a) <= 254 do
    case String.split(a, "@") do
      [local, domain] ->
        byte_size(local) in 1..64 and Regex.match?(@local, local) and domain?(domain)

      _ ->
        false
    end
  end

  def address?(_), do: false

  def domain(address), do: address |> String.split("@") |> List.last()

  defp domain?(d) do
    labels = String.split(d, ".")
    byte_size(d) <= 253 and length(labels) >= 2 and Enum.all?(labels, &Regex.match?(@label, &1))
  end

  @doc "Relay: lowercase DNS name or dotted IPv4, at most 253 bytes."
  def relay?(r) when is_binary(r) and byte_size(r) in 1..253 do
    ipv4?(r) or
      String.split(r, ".")
      |> Enum.all?(&Regex.match?(~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/, &1))
  end

  def relay?(_), do: false

  def ipv4?(r) when is_binary(r),
    do: match?({:ok, {_, _, _, _}}, :inet.parse_strict_address(String.to_charlist(r)))

  def ipv4?(_), do: false

  def loopback?(r), do: r in ["127.0.0.1", "localhost"]

  @doc "Bounded printable text without control characters."
  def text?(v, max),
    do:
      is_binary(v) and byte_size(v) in 1..max and String.valid?(v) and
        not Regex.match?(~r/\p{Cc}/u, v)

  def hex?(v), do: is_binary(v) and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)
end
