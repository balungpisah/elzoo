# SPDX-License-Identifier: Apache-2.0
# Usage sketch against a disposable S3-compatible server. The credential is an injected Need:
# here a function the application owns reads it from the application's own secret source (this
# example reads the variables of scripts/ci-minio.py); the Piece itself never reads the
# environment. Run with: mix run examples/object_store.exs (after starting :req).
{:ok, _} = Application.ensure_all_started(:req)

defmodule Elzoo.ObjectStore.Example do
  def credentials do
    {:ok,
     %{
       access_key_id: System.fetch_env!("ELZOO_TEST_S3_ACCESS_KEY_ID"),
       secret_access_key: System.fetch_env!("ELZOO_TEST_S3_SECRET_ACCESS_KEY")
     }}
  end

  def run do
    {:ok, store} =
      Elzoo.ObjectStore.new(
        store_id: "example-minio",
        endpoint: System.fetch_env!("ELZOO_TEST_S3_URL"),
        bucket: System.fetch_env!("ELZOO_TEST_S3_BUCKET"),
        region: System.fetch_env!("ELZOO_TEST_S3_REGION"),
        credentials: {__MODULE__, :credentials, []}
      )

    key = "example/#{System.unique_integer([:positive])}.txt"
    body = "report body"

    case Elzoo.ObjectStore.put(store, key, body, content_type: "text/plain", deadline_ms: 5_000) do
      %{status: :committed} ->
        %{status: :found, body: ^body} = Elzoo.ObjectStore.get(store, key)

      %{status: :unknown} ->
        # Never re-send blindly: reconcile first.
        Elzoo.ObjectStore.reconcile_put(store, key, :crypto.hash(:sha256, body))

      %{status: :refused} = refused ->
        refused
    end

    %{status: :listed} = Elzoo.ObjectStore.list(store, "example/", page_size: 10)
    {:ok, link} = Elzoo.ObjectStore.presign(store, key, expires_s: 60)
    # `link.url` is a bearer capability: hand it to its holder, never log it.
    _ = link
    %{status: :committed} = Elzoo.ObjectStore.delete(store, key)
    :ok
  end
end

Elzoo.ObjectStore.Example.run()
