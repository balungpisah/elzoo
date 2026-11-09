# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ObjectStore.Presigned do
  @moduledoc """
  A presigned URL: a bearer capability. By S3 design its query carries the access-key ID
  (never the secret). `inspect/1` shows the method, store, bucket, key and expiry but never
  the URL; the Adapter never logs or emits it. Read `url` only to hand it to its holder.
  """
  @enforce_keys [:url, :method, :expires_at, :store, :bucket, :key]
  defstruct [:url, :method, :expires_at, :store, :bucket, :key, operation: :presign]

  defimpl Inspect do
    def inspect(p, _opts) do
      "#Elzoo.ObjectStore.Presigned<#{p.method} store=#{Kernel.inspect(p.store)} " <>
        "bucket=#{Kernel.inspect(p.bucket)} key=#{Kernel.inspect(p.key)} " <>
        "expires_at=#{DateTime.to_iso8601(p.expires_at)} url=redacted>"
    end
  end
end
