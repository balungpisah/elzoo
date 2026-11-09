# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ObjectStore.Config do
  @moduledoc """
  One validated binding of an S3-compatible endpoint and one bucket under a caller-chosen
  backing-store identity. A plain struct: no process, no application environment, no
  global state. `credentials` is a reference (an `{module, function, args}` tuple or a
  zero-arity function) resolved at each call; the struct never holds the credential
  values, and `inspect/1` shows only the store, the endpoint host, the bucket and the region.
  A change of any setting is a new struct value; there is no hot update.
  """

  @five_gib 5 * 1024 * 1024 * 1024
  @timer_max 4_294_967_295
  @presign_limit 604_800

  @enforce_keys [:store_id, :endpoint, :bucket, :region, :credentials]
  defstruct [
    :store_id,
    :endpoint,
    :bucket,
    :region,
    :credentials,
    :finch,
    max_object_bytes: 64 * 1024 * 1024,
    max_page_size: 1000,
    default_page_size: 100,
    presign_default_s: 900,
    presign_max_s: 3600,
    default_deadline_ms: 30_000
  ]

  @type t :: %__MODULE__{}

  @keys [
    :store_id,
    :endpoint,
    :bucket,
    :region,
    :credentials,
    :finch,
    :max_object_bytes,
    :max_page_size,
    :default_page_size,
    :presign_default_s,
    :presign_max_s,
    :default_deadline_ms
  ]

  @doc "Validate construction options; `{:ok, config}` or `{:error, {:invalid_config, setting}}`."
  def new(opts) when is_list(opts) or is_map(opts) do
    opts = Map.new(opts)

    with :ok <- known_keys(opts),
         {:ok, config} <- build(opts),
         :ok <- check(config) do
      {:ok, config}
    end
  end

  def new(_), do: {:error, {:invalid_config, :options}}

  defp known_keys(opts) do
    case Enum.find(Map.keys(opts), &(&1 not in @keys)) do
      nil -> :ok
      _other -> {:error, {:invalid_config, :unknown_option}}
    end
  end

  defp build(opts) do
    case Enum.find(@enforce_keys, &(not Map.has_key?(opts, &1))) do
      nil -> {:ok, struct(__MODULE__, opts)}
      missing -> {:error, {:invalid_config, missing}}
    end
  end

  defp check(c) do
    checks = [
      store_id: text?(c.store_id, 128),
      endpoint: endpoint?(c.endpoint),
      bucket: bucket?(c.bucket),
      region: text?(c.region, 64),
      credentials: credentials_ref?(c.credentials),
      finch: is_nil(c.finch) or is_atom(c.finch),
      max_object_bytes: int_in?(c.max_object_bytes, 1, @five_gib),
      max_page_size: int_in?(c.max_page_size, 1, 1000),
      default_page_size: int_in?(c.default_page_size, 1, c.max_page_size),
      presign_max_s: int_in?(c.presign_max_s, 1, @presign_limit),
      presign_default_s: int_in?(c.presign_default_s, 1, c.presign_max_s),
      default_deadline_ms: int_in?(c.default_deadline_ms, 1, @timer_max)
    ]

    case Enum.find(checks, fn {_k, ok} -> ok != true end) do
      nil -> :ok
      {key, _} -> {:error, {:invalid_config, key}}
    end
  end

  @doc false
  def timer_max, do: @timer_max

  @doc false
  def text?(v, max),
    do:
      is_binary(v) and String.valid?(v) and byte_size(v) in 1..max and
        not String.match?(v, ~r/[\x00-\x1f\x7f]/u)

  defp int_in?(v, lo, hi), do: is_integer(v) and is_integer(hi) and v >= lo and v <= hi

  defp endpoint?(v) when is_binary(v) do
    case URI.new(v) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        uri.path in [nil, "", "/"]

      _ ->
        false
    end
  end

  defp endpoint?(_), do: false

  # S3 bucket naming: 3..63 bytes, lowercase letters, digits, '-' and '.', starting and
  # ending with a letter or digit.
  defp bucket?(v),
    do: is_binary(v) and String.match?(v, ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/)

  defp credentials_ref?({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: true
  defp credentials_ref?(fun) when is_function(fun, 0), do: true
  defp credentials_ref?(_), do: false

  @doc false
  # Resolve the credential Need. Returns `{:ok, access_key_id, secret}` or `:error`; never the
  # term the Need returned, raised or exited with.
  def resolve_credentials(%__MODULE__{credentials: ref}) do
    result =
      case ref do
        {m, f, a} -> apply(m, f, a)
        fun -> fun.()
      end

    case result do
      {:ok, %{access_key_id: ak, secret_access_key: sk}}
      when is_binary(ak) and ak != "" and is_binary(sk) and sk != "" ->
        {:ok, ak, sk}

      _ ->
        :error
    end
  catch
    _, _ -> :error
  end

  defimpl Inspect do
    def inspect(c, _opts) do
      host = URI.parse(c.endpoint).host

      "#Elzoo.ObjectStore.Config<store=#{Kernel.inspect(c.store_id)} host=#{Kernel.inspect(host)} " <>
        "bucket=#{Kernel.inspect(c.bucket)} region=#{Kernel.inspect(c.region)} credentials=redacted>"
    end
  end
end
