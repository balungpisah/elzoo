# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ObjectStore.Binding do
  @moduledoc """
  Consumer-parameterised `delivery/effect-intent` (ELZ-023) Binding for one object-store write
  operation:

      defmodule MyApp.ReportUpload do
        use Elzoo.ObjectStore.Binding,
          id: "report-upload",
          operation: :put,
          provider_account: "s3://reports-store/reports",
          recovery_grace_ms: :none
      end

  The helper compiles a fixed failure table through `Elzoo.EffectIntent.Binding.compile!/1`
  with `replay: :none` and `revision: :forbidden`. The consumer supplies the account, operation,
  identity and the owner's `adapter_context` built by `context/2`.

  Canonical arguments are the object reference (`arguments/2`), never the body: the EffectIntent
  argument bound is 64 KiB. The body comes from the context's `body` function at send time and
  is checked against the argument SHA-256 before dispatch.

  `poll/1` reconciles with a `head`: for a put, a matching stored SHA-256 completes; `absent` or
  another SHA-256 is `{:pending, evidence}`; a delete completes when `absent` is observed at poll
  (an observation, not proof that this attempt deleted anything). Poll never returns
  `:no_effect` or `:unknown_to_provider`. Results are sealed with a process-local HMAC key from
  the context, so a public observation cannot complete an attempt; after a restart nothing can
  complete a recovered attempt through this boundary (the conservative direction).
  """

  @local ~w(invalid_key too_large checksum_mismatch invalid_request)a
  @provider Enum.map(
              ~w(denied no_such_bucket precondition_failed too_large invalid_key checksum_mismatch)a,
              &:"provider_#{&1}"
            )

  @failures Map.merge(
              Map.merge(
                Map.new(@local, &{&1, {"rejected", "not_dispatched", "permanent"}}),
                %{credentials_unavailable: {"rejected", "not_dispatched", "unavailable"}}
              ),
              Map.merge(
                Map.new(@provider, &{&1, {"failed", "dispatched", "permanent"}}),
                %{
                  deadline: {"timed_out", "unknown", "unclassified"},
                  transport: {"unknown", "unknown", "unclassified"},
                  adapter_error: {"unknown", "unknown", "unclassified"},
                  server_error: {"unknown", "dispatched", "unclassified"},
                  unverified: {"unknown", "dispatched", "unclassified"},
                  unexpected: {"unknown", "dispatched", "unclassified"}
                }
              )
            )

  @doc "The fixed failure table: tag => {outcome, dispatch, error_class}."
  def failures, do: @failures

  @doc "Tags whose failure is decided before any connection (attested no-send)."
  def no_send_attestations, do: @local ++ [:credentials_unavailable]

  def failure_tags, do: Map.keys(@failures) |> Enum.sort()

  defmacro __using__(opts) do
    operation = Keyword.fetch!(opts, :operation)

    adapter =
      case operation do
        :put -> Elzoo.ObjectStore.Binding.Put
        :delete -> Elzoo.ObjectStore.Binding.Delete
      end

    quote do
      use Elzoo.EffectIntent.Binding,
        adapter: unquote(adapter),
        id: unquote(Keyword.fetch!(opts, :id)),
        provider_account: unquote(Keyword.fetch!(opts, :provider_account)),
        operation: unquote(Atom.to_string(operation)),
        clock: unquote(Keyword.get(opts, :clock, "unix-ms")),
        failures: unquote(Macro.escape(@failures)),
        no_send_attestations: unquote(@local ++ [:credentials_unavailable]),
        recovery_grace_ms: unquote(Keyword.get(opts, :recovery_grace_ms, :none)),
        replay: :none,
        revision: :forbidden
    end
  end

  @doc """
  The owner's `adapter_context`: `config` (an `Elzoo.ObjectStore.Config`), `body` (put only:
  a function of `%{key:, sha256:, bytes:, content_type:}` returning a binary or
  `{:stream, enumerable, length}`), `deadline_ms` (per send or poll) and a fresh process-local
  seal key. Inspecting the context shows no credential (the Config redacts it).
  """
  def context(config, opts \\ []) do
    %{
      config: config,
      body: Keyword.get(opts, :body),
      deadline_ms: Keyword.get(opts, :deadline_ms, config.default_deadline_ms),
      seal_key: :crypto.strong_rand_bytes(32)
    }
  end

  @doc "Canonical arguments: `arguments(:put, key:, sha256:, bytes:, content_type:)` or `arguments(:delete, key:)`."
  def arguments(:put, fields) do
    key = Keyword.fetch!(fields, :key)
    sha = Keyword.fetch!(fields, :sha256)
    bytes = Keyword.fetch!(fields, :bytes)
    ct = Keyword.get(fields, :content_type, "application/octet-stream")

    true = is_binary(sha) and byte_size(sha) == 32 and is_integer(bytes) and bytes >= 0

    "elzoo/object-store-put/1" <>
      frame(key) <> sha <> <<bytes::unsigned-64>> <> frame(ct)
  end

  def arguments(:delete, fields),
    do: "elzoo/object-store-delete/1" <> frame(Keyword.fetch!(fields, :key))

  defp frame(text) when is_binary(text), do: <<byte_size(text)::unsigned-16, text::binary>>

  @doc false
  def decode("elzoo/object-store-put/1" <> rest) do
    with <<kl::unsigned-16, key::binary-size(kl), sha::binary-size(32), bytes::unsigned-64,
           cl::unsigned-16, ct::binary-size(cl)>> <- rest,
         true <- Elzoo.ObjectStore.key?(key) do
      {:ok, %{operation: :put, key: key, sha256: sha, bytes: bytes, content_type: ct}}
    else
      _ -> :error
    end
  end

  def decode("elzoo/object-store-delete/1" <> rest) do
    with <<kl::unsigned-16, key::binary-size(kl)>> <- rest,
         true <- Elzoo.ObjectStore.key?(key) do
      {:ok, %{operation: :delete, key: key}}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  # ---- shared callback implementation

  @doc false
  def failure(%{status: :refused, reason: r, origin: :local}), do: {:error, r, :local}
  def failure(%{status: :refused, reason: r}), do: {:error, :"provider_#{r}", :provider}
  def failure(%{status: :unknown, reason: :integrity}), do: {:error, :unexpected, :integrity}
  def failure(%{status: :unknown, reason: r}), do: {:error, r, :unknown}

  @doc false
  def completed(req, schema, value) do
    %{
      "version" => 1,
      "message_id" => req.key,
      "correlation_id" => req.key,
      "attempt_id" => req.attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => Map.put(value, "seal", seal(req, "completed", value)),
      "value_schema_id" => schema,
      "value_schema_version" => 1
    }
  end

  @doc false
  def evidence(req, kind, data), do: Map.put(data, "seal", seal(req, Atom.to_string(kind), data))

  @doc false
  def seal(%{context: %{seal_key: k}, key: key, attempt_id: id}, kind, data) when is_binary(k) do
    payload = :erlang.term_to_binary({key, id, kind, Map.delete(data, "seal")}, [:deterministic])
    Base.encode16(:crypto.mac(:hmac, :sha256, k, payload), case: :lower)
  end

  @doc false
  def authenticate({kind, %{"seal" => s} = ev}, req) when is_atom(kind),
    do: if(safe_eq(s, seal(req, Atom.to_string(kind), ev)), do: :ok, else: :error)

  def authenticate(%{"outcome" => "completed", "value" => %{"seal" => s} = v}, req),
    do: if(safe_eq(s, seal(req, "completed", v)), do: :ok, else: :error)

  def authenticate(_, _), do: :error

  defp safe_eq(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp safe_eq(_, _), do: false

  @doc false
  def hex(raw), do: Base.encode16(raw, case: :lower)

  @doc false
  def unavailable(req, result),
    do:
      {:unavailable,
       evidence(req, :unavailable, %{"reason" => Atom.to_string(result_reason(result))})}

  defp result_reason(%{reason: r}), do: r
  defp result_reason(_), do: :unexpected
end

defmodule Elzoo.ObjectStore.Binding.Put do
  @moduledoc false
  alias Elzoo.ObjectStore
  alias Elzoo.ObjectStore.Binding, as: B

  @schema "elzoo/object-store-put-v1"
  @value_schema "elzoo/object-store-intent-put"

  def failure_tags, do: B.failure_tags()
  def schema, do: @schema

  def validate(bytes, @schema),
    do: if(match?({:ok, %{operation: :put}}, B.decode(bytes)), do: :ok, else: :error)

  def validate(_, _), do: :error

  def send_effect(%{context: ctx} = req) do
    with {:ok, %{operation: :put} = a} <- B.decode(req.arguments || ""),
         {:ok, body} <- body(ctx, a) do
      case ObjectStore.put(ctx.config, a.key, body,
             content_sha256: a.sha256,
             content_type: a.content_type,
             deadline_ms: ctx.deadline_ms
           ) do
        %{status: :committed} = r ->
          B.completed(req, @value_schema, %{
            "key" => a.key,
            "sha256" => r.sha256,
            "bytes" => r.bytes,
            "observation" => "committed"
          })

        r ->
          B.failure(r)
      end
    else
      _ -> {:error, :invalid_request, :local}
    end
  end

  defp body(%{body: fun}, a) when is_function(fun, 1) do
    case fun.(Map.take(a, [:key, :sha256, :bytes, :content_type])) do
      bin when is_binary(bin) and byte_size(bin) == a.bytes -> {:ok, bin}
      {:stream, _enum, len} = s when len == a.bytes -> {:ok, s}
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  defp body(_, _), do: :error

  def poll(%{context: ctx} = req) do
    with {:ok, %{operation: :put} = a} <- B.decode(req.arguments || "") do
      case ObjectStore.reconcile_put(ctx.config, a.key, a.sha256, deadline_ms: ctx.deadline_ms) do
        %{status: :reconciled, observation: :match} ->
          B.completed(req, @value_schema, %{
            "key" => a.key,
            "sha256" => B.hex(a.sha256),
            "bytes" => a.bytes,
            "observation" => "match_at_poll"
          })

        %{status: :reconciled, observation: obs} ->
          {:pending, B.evidence(req, :pending, %{"observation" => Atom.to_string(obs)})}

        other ->
          B.unavailable(req, other)
      end
    else
      _ -> B.unavailable(req, :arguments)
    end
  end

  def authenticate(result, req), do: B.authenticate(result, req)

  def validate_result(%{"value_schema_id" => @value_schema, "value" => v}, req) do
    case B.decode(req.arguments || "") do
      {:ok, a} ->
        if v["key"] == a.key and v["sha256"] == B.hex(a.sha256) and v["bytes"] == a.bytes,
          do: :ok,
          else: :error

      _ ->
        :error
    end
  end

  def validate_result(_, _), do: :error
end

defmodule Elzoo.ObjectStore.Binding.Delete do
  @moduledoc false
  alias Elzoo.ObjectStore
  alias Elzoo.ObjectStore.Binding, as: B

  @schema "elzoo/object-store-delete-v1"
  @value_schema "elzoo/object-store-intent-delete"

  def failure_tags, do: B.failure_tags()
  def schema, do: @schema

  def validate(bytes, @schema),
    do: if(match?({:ok, %{operation: :delete}}, B.decode(bytes)), do: :ok, else: :error)

  def validate(_, _), do: :error

  def send_effect(%{context: ctx} = req) do
    case B.decode(req.arguments || "") do
      {:ok, %{operation: :delete} = a} ->
        case ObjectStore.delete(ctx.config, a.key, deadline_ms: ctx.deadline_ms) do
          %{status: :committed} ->
            B.completed(req, @value_schema, %{"key" => a.key, "observation" => "acknowledged"})

          r ->
            B.failure(r)
        end

      _ ->
        {:error, :invalid_request, :local}
    end
  end

  def poll(%{context: ctx} = req) do
    case B.decode(req.arguments || "") do
      {:ok, %{operation: :delete} = a} ->
        case ObjectStore.head(ctx.config, a.key, deadline_ms: ctx.deadline_ms) do
          %{status: :absent} ->
            B.completed(req, @value_schema, %{"key" => a.key, "observation" => "absent_at_poll"})

          %{status: :found} ->
            {:pending, B.evidence(req, :pending, %{"observation" => "present"})}

          other ->
            B.unavailable(req, other)
        end

      _ ->
        B.unavailable(req, :arguments)
    end
  end

  def authenticate(result, req), do: B.authenticate(result, req)

  def validate_result(%{"value_schema_id" => @value_schema, "value" => v}, req) do
    case B.decode(req.arguments || "") do
      {:ok, a} -> if v["key"] == a.key, do: :ok, else: :error
      _ -> :error
    end
  end

  def validate_result(_, _), do: :error
end
