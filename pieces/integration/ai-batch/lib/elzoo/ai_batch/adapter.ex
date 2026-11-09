# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Adapter do
  @moduledoc """
  Shared parts of the two `delivery/effect-intent` Adapters of the batch
  interface (`Elzoo.AiBatch.SubmitAdapter`, `Elzoo.AiBatch.CancelAdapter`): the
  result envelope, the volatile sink delivery, the process-local seal and the
  result checks. Failure details are fixed atoms; the completed envelope carries
  only the provider job id, a digest of the typed outcome and the seal.
  Credentials, prompts, outputs and submission bytes never enter EffectIntent
  state.
  """
  alias Elzoo.AiBatch.{Config, Sink}
  alias Elzoo.AiText.Outcome

  @doc false
  def failure_tags, do: Outcome.tags()

  @doc false
  def provider_tag(tag), do: if(tag in Outcome.provider_tags(), do: tag, else: :adapter_error)

  @doc false
  def meta(m) do
    case m do
      %{retry_after: s} when is_integer(s) and s >= 0 and s <= 86_400 -> %{retry_after: s}
      _ -> %{retry_after: nil}
    end
  end

  @doc false
  def completed(c, key, attempt_id, reference, outcome, value_schema) do
    _ = Sink.deliver(c.sink, key, attempt_id, outcome)
    digest = digest(outcome)

    %{
      "version" => 1,
      "message_id" => key,
      "correlation_id" => key,
      "attempt_id" => attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{
        "reference" => reference,
        "outcome_digest" => digest,
        "seal" => seal(c, key, attempt_id, reference, digest)
      },
      "value_schema_id" => value_schema,
      "value_schema_version" => 1
    }
  end

  @doc false
  # The failure path: deliver the typed outcome built by `shape` from the
  # Contract outcome of `tag`, then return the declared failure tag.
  def failed(c, key, attempt_id, tag, shape) do
    {:ok, contract} = Outcome.contract(tag)
    _ = Sink.deliver(c.sink, key, attempt_id, shape.(contract))
    failure(tag)
  end

  @doc false
  def failure(tag), do: {:error, tag, :ai_batch}

  @doc false
  def validate_result(
        %{
          "outcome" => "completed",
          "value_schema_id" => schema,
          "value_schema_version" => 1,
          "value" => %{"reference" => r, "outcome_digest" => d, "seal" => s} = v
        },
        schema
      ) do
    if map_size(v) == 3 and Elzoo.AiModel.text?(r, 256) and hex64?(d) and hex64?(s),
      do: :ok,
      else: :error
  end

  def validate_result(_, _), do: :error

  @doc false
  def authenticate({:unavailable, :no_status_query}, _), do: :ok

  def authenticate(
        %{
          "attempt_id" => attempt_id,
          "value" => %{"reference" => r, "outcome_digest" => d, "seal" => s}
        },
        %{key: key, attempt_id: attempt_id, context: %Config{} = c}
      )
      when is_binary(s) do
    expected = seal(c, key, attempt_id, r, d)

    if byte_size(s) == byte_size(expected) and :crypto.hash_equals(s, expected),
      do: :ok,
      else: :error
  rescue
    _ -> :error
  end

  def authenticate(_, _), do: :error

  defp hex64?(v), do: is_binary(v) and byte_size(v) == 64 and v =~ ~r/\A[0-9a-f]+\z/

  defp digest(outcome),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(outcome, [:deterministic]))
      |> Base.encode16(case: :lower)

  # Process-local integrity of this Adapter's own result, not provider
  # authentication: a forged or post-restart completion fails.
  defp seal(%Config{seal_key: k}, key, attempt_id, reference, digest) do
    data = Enum.map([key, attempt_id, reference, digest], &<<byte_size(&1)::32, &1::binary>>)
    :crypto.mac(:hmac, :sha256, k, data) |> Base.encode16(case: :lower)
  end
end

defmodule Elzoo.AiBatch.SubmitAdapter do
  @moduledoc """
  The `delivery/effect-intent` Adapter of one batch submission. Order inside the
  send task: binding and manifest checks (the manifest's body length within
  `max_create_wire_bytes`); the host's submission store keyed by intent key,
  binding digest and manifest digest; length and SHA-256 of the returned bytes
  against the manifest; then the credential Need (a failure is the only attested
  no-send, `credentials_unavailable`); exactly one provider `submit/2` with
  **exactly those bytes** and the manifest's provider metadata (no translation
  or encoding happens here: the body was prepared once at admission); the
  volatile sink; the envelope. A missing or mismatched body is `adapter_error`
  before the credential is read (nothing is sent, but no further no-send tag
  exists, so the result is conservatively unknown). The Adapter never retries.

  Delivered outcomes: `{:submitted, %{job_ref, item_count, orphans}}`,
  `{:refused, reason, %{retry_after, orphans}}`, `{:unknown, reason, %{orphans}}`.
  """
  alias Elzoo.AiBatch.{Adapter, Binding, Config, Submission}

  @schema "elzoo/ai-batch-manifest-v1"
  @value_schema "elzoo/ai-batch-submitted"

  def failure_tags, do: Adapter.failure_tags()
  def schema, do: @schema

  def validate(bytes, @schema) do
    case Submission.decode_manifest(bytes) do
      {:ok, _} -> :ok
      _ -> {:error, :schema}
    end
  end

  def validate(_, _), do: {:error, :schema}

  def send_effect(req) do
    with %{context: %Config{} = c, key: key, attempt_id: attempt_id} <- req,
         {:ok, b} <- Binding.load(c.submit_binding, :submit),
         true <- b.digest == req.binding,
         true <- is_binary(req.arguments),
         {:ok, manifest} <- Submission.decode_manifest(req.arguments),
         true <- manifest.wire_bytes <= c.max_create_wire_bytes,
         {:ok, bytes} <- fetch(c, key, req.binding, Submission.sha256(req.arguments)),
         true <- Submission.matches?(manifest, bytes) do
      wire = %{body: bytes, meta: manifest.provider_meta}

      case Elzoo.AiBatch.credential(c) do
        {:ok, secret} ->
          c
          |> exchange(wire, secret)
          |> finish(c, key, attempt_id, manifest.item_count)

        _ ->
          finish({:failure, :credentials_unavailable, %{}}, c, key, attempt_id, 0)
      end
    else
      _ -> local_failure(req)
    end
  rescue
    _ -> Adapter.failure(:adapter_error)
  catch
    _, _ -> Adapter.failure(:adapter_error)
  end

  defp fetch(%Config{submissions: {module, server}}, key, binding_digest, manifest_digest) do
    case module.fetch(server, key, %{
           binding_digest: binding_digest,
           manifest_digest: manifest_digest
         }) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  # A failure before the credential was read (binding, manifest, lookup,
  # digest or checks): nothing was sent, but the outcome is reported unknown
  # because the reused failure table attests no-send only for credentials.
  defp local_failure(%{context: %Config{} = c, key: key, attempt_id: attempt_id}) do
    finish({:failure, :adapter_error, %{}}, c, key, attempt_id, 0)
  rescue
    _ -> Adapter.failure(:adapter_error)
  end

  defp local_failure(_), do: Adapter.failure(:adapter_error)

  # Exactly one provider submission. Every exception after the credential was
  # read is adapter_error (unknown): bytes may have reached transport.
  defp exchange(c, wire, secret) do
    case c.provider.submit(wire, Elzoo.AiBatch.call_opts(c, secret)) do
      {:ok, %{provider_job_id: id, orphans: orphans}} ->
        if orphans?(orphans) and Elzoo.AiModel.text?(id, 256),
          do: {:ok, id, orphans},
          else: {:failure, :malformed_response, %{orphans: valid_orphans(orphans)}}

      {:failure, tag, meta} when is_map(meta) ->
        {:failure, Adapter.provider_tag(tag), meta}

      _ ->
        {:failure, :adapter_error, %{}}
    end
  rescue
    _ -> {:failure, :adapter_error, %{}}
  catch
    _, _ -> {:failure, :adapter_error, %{}}
  end

  defp finish({:ok, id, orphans}, c, key, attempt_id, count) do
    provider = c.provider.capabilities().provider

    {:ok, job_ref} =
      Elzoo.AiModel.Job.validate_ref(%{
        provider: provider,
        provider_job_id: id,
        submitted_at: System.system_time(:millisecond)
      })

    outcome = {:submitted, %{job_ref: job_ref, item_count: count, orphans: orphans}}
    Adapter.completed(c, key, attempt_id, id, outcome, @value_schema)
  end

  defp finish({:failure, tag, meta}, c, key, attempt_id, _count) do
    orphans = valid_orphans(Map.get(meta, :orphans, []))

    Adapter.failed(c, key, attempt_id, tag, fn
      {:refused, reason} -> {:refused, reason, Map.put(Adapter.meta(meta), :orphans, orphans)}
      {:unknown, reason} -> {:unknown, reason, %{orphans: orphans}}
    end)
  end

  @doc false
  def orphans?(list) do
    is_list(list) and length(list) <= 1024 and
      Enum.all?(list, fn o ->
        Elzoo.AiModel.exact_keys?(o, [:kind, :provider_ref]) and Elzoo.AiModel.text?(o.kind, 64) and
          Elzoo.AiModel.text?(o.provider_ref, 256)
      end)
  end

  # An orphan list that fails validation is reported as one opaque record so an
  # orphan is never silently dropped.
  defp valid_orphans([]), do: []

  defp valid_orphans(list),
    do:
      if(orphans?(list),
        do: list,
        else: [%{kind: "unreported", provider_ref: "invalid-orphan-list"}]
      )

  @doc "No provider status query for a lost submission: an unknown outcome stays unknown."
  def poll(_req), do: {:unavailable, :no_status_query}

  def validate_result(envelope, _req), do: Adapter.validate_result(envelope, @value_schema)
  def authenticate(observation, req), do: Adapter.authenticate(observation, req)
end

defmodule Elzoo.AiBatch.CancelAdapter do
  @moduledoc """
  The `delivery/effect-intent` Adapter of one cancel request. Order: binding and
  argument checks; the credential Need (a failure is the only attested no-send);
  exactly one provider `cancel/2`; the volatile sink; the envelope. Delivered
  outcomes: `{:cancelled, job_state}` (the provider acknowledged the request),
  `{:refused, reason, %{retry_after}}`, `{:unknown, reason}`. A later status
  observation of `:ending` or `{:ended, _}` is not a ground for this attempt.
  """
  alias Elzoo.AiBatch.{Adapter, Binding, Config}

  @schema "elzoo/ai-batch-cancel-v1"
  @value_schema "elzoo/ai-batch-cancelled"

  def failure_tags, do: Adapter.failure_tags()
  def schema, do: @schema

  def validate(bytes, @schema) when is_binary(bytes) do
    with {:ok, %{"version" => 1, "job_ref" => %{"provider_job_id" => id}}} <- Jason.decode(bytes),
         true <- Elzoo.AiModel.text?(id, 128) do
      :ok
    else
      _ -> {:error, :schema}
    end
  end

  def validate(_, _), do: {:error, :schema}

  def send_effect(req) do
    with %{context: %Config{} = c, key: key, attempt_id: attempt_id} <- req,
         {:ok, b} <- Binding.load(c.cancel_binding, :cancel),
         true <- b.digest == req.binding,
         {:ok, job_ref, _} <- Elzoo.AiBatch.cancel_arguments(c, req.arguments) do
      case Elzoo.AiBatch.credential(c) do
        {:ok, secret} ->
          c |> exchange(job_ref.provider_job_id, secret) |> finish(c, key, attempt_id, job_ref)

        _ ->
          finish({:failure, :credentials_unavailable, %{}}, c, key, attempt_id, job_ref)
      end
    else
      _ -> local_failure(req)
    end
  rescue
    _ -> Adapter.failure(:adapter_error)
  catch
    _, _ -> Adapter.failure(:adapter_error)
  end

  defp local_failure(%{context: %Config{} = c, key: key, attempt_id: attempt_id}) do
    finish({:failure, :adapter_error, %{}}, c, key, attempt_id, nil)
  rescue
    _ -> Adapter.failure(:adapter_error)
  end

  defp local_failure(_), do: Adapter.failure(:adapter_error)

  defp exchange(c, id, secret) do
    case c.provider.cancel(id, Elzoo.AiBatch.call_opts(c, secret)) do
      {:ok, state} ->
        case Elzoo.AiModel.Job.validate_state(state) do
          {:ok, state} -> {:ok, state}
          _ -> {:failure, :malformed_response, %{}}
        end

      {:failure, tag, meta} when is_map(meta) ->
        {:failure, Adapter.provider_tag(tag), meta}

      _ ->
        {:failure, :adapter_error, %{}}
    end
  rescue
    _ -> {:failure, :adapter_error, %{}}
  catch
    _, _ -> {:failure, :adapter_error, %{}}
  end

  defp finish({:ok, state}, c, key, attempt_id, job_ref),
    do:
      Adapter.completed(
        c,
        key,
        attempt_id,
        job_ref.provider_job_id,
        {:cancelled, state},
        @value_schema
      )

  defp finish({:failure, tag, meta}, c, key, attempt_id, _job_ref) do
    Adapter.failed(c, key, attempt_id, tag, fn
      {:refused, reason} -> {:refused, reason, Adapter.meta(meta)}
      {:unknown, reason} -> {:unknown, reason}
    end)
  end

  @doc "No cancel receipt exists: an unknown cancel stays unknown."
  def poll(_req), do: {:unavailable, :no_status_query}

  def validate_result(envelope, _req), do: Adapter.validate_result(envelope, @value_schema)
  def authenticate(observation, req), do: Adapter.authenticate(observation, req)
end
