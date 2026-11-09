# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch do
  @moduledoc """
  The provider-neutral batch job-mode interface over text requests: trusted
  construction (`configure/1`); submit and cancel as writes through `core/effect`
  admission (`admit_submit/2`, `admit_cancel/2`) and the `delivery/effect-intent`
  owner (`Elzoo.AiBatch.SubmitAdapter`, `Elzoo.AiBatch.CancelAdapter`); status and
  result pages as call-scoped reads (`status/2`, `results/4`) joined by item id
  (`Elzoo.AiBatch.Join`). The Contract is in the Piece documentation.
  """
  alias Elzoo.AiBatch.{Binding, Config, Join, Provider, Submission}
  alias Elzoo.AiModel.Job
  alias Elzoo.AiText.Outcome

  @capability "integration/ai-batch"
  @submit_schema "elzoo/ai-batch-submission"
  @cancel_schema "elzoo/ai-batch-cancel"
  @max_bigint 9_223_372_036_854_775_807
  @mib 1_048_576
  @options [
    :submit_binding,
    :cancel_binding,
    :tenant,
    :provider,
    :provider_config,
    :credentials,
    :submissions,
    :models,
    :max_output_tokens,
    :max_items,
    :max_create_wire_bytes,
    :max_submission_bytes,
    :max_item_bytes,
    :page_size,
    :max_line_bytes,
    :max_scan_bytes,
    :receive_timeout_ms,
    :sink
  ]
  @read_reasons [
    :invalid_request,
    :credentials_unavailable,
    :authentication_failed,
    :permission_denied,
    :not_found,
    :too_large,
    :throttled,
    :overloaded,
    :timeout,
    :transport,
    :provider_error,
    :malformed_response
  ]

  @doc "Reasons a `status/2` call may return; `results/4` adds `results_reasons/0`."
  def read_reasons, do: @read_reasons
  def results_reasons, do: @read_reasons ++ [:malformed_page, :result_line_limit, :result_scan_limit]

  @doc """
  Builds the trusted Config. Options: `submit_binding` and `cancel_binding`
  (modules using `Elzoo.AiBatch.Binding` with operation `:submit` and `:cancel`),
  `tenant`, `provider` (a module implementing `Elzoo.AiBatch.Provider`),
  `provider_config` (its construction term), `credentials` (the injected
  credential Need, a zero-arity function returning `{:ok, binary}`),
  `submissions` (the submission lookup Need, a 2-arity function, see
  `Elzoo.AiBatch.Staging`), `models` (allowlist, 1..64), `sink` (see
  `Elzoo.AiBatch.Sink`) and the bounds, each an integer:

  - `max_output_tokens`: 1..1,000,000, default 64,000 (per item);
  - `max_items`: 1..the provider's `max_items` (default the provider's);
  - `max_create_wire_bytes`: 1..the provider's `max_create_wire_bytes` (default
    the provider's), measured on the exact encoded create body;
  - `max_submission_bytes`: 1..1,073,741,824, default 268,435,456 (the
    declaration payload and its canonical form);
  - `max_item_bytes`: 1..65,536, default 65,536 (each item's canonical request);
  - `page_size`: 1..1,000, default 100 (result lines per page);
  - `max_line_bytes`: 1..16 MiB, default 1 MiB (one result line);
  - `max_scan_bytes`: 1..1 GiB, default 64 MiB (all bytes read by one results
    call, including skipped lines);
  - `receive_timeout_ms`: 1..600,000, default 120,000.

  Fixed for the Config's lifetime; no hot update.
  """
  def configure(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @options)),
         {:ok, _} <- Binding.load(opts[:submit_binding], :submit),
         {:ok, _} <- Binding.load(opts[:cancel_binding], :cancel),
         true <- Outcome.verify(),
         true <- Elzoo.AiModel.text?(opts[:tenant], 256),
         provider when is_atom(provider) <- opts[:provider],
         true <- Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0),
         caps = provider.capabilities(),
         true <- Provider.valid_capabilities?(caps),
         true <- Code.ensure_loaded?(caps.item_provider),
         true <- Elzoo.AiText.Provider.valid_capabilities?(caps.item_provider.capabilities()),
         true <- is_function(opts[:credentials], 0) and is_function(opts[:sink], 2),
         true <- is_function(opts[:submissions], 2),
         models when is_list(models) and length(models) in 1..64 <- opts[:models],
         true <- Enum.all?(models, &Elzoo.AiModel.text?(&1, 256)),
         {:ok, out} <- bound(opts, :max_output_tokens, 1_000_000, 64_000),
         {:ok, items} <- bound(opts, :max_items, caps.max_items, caps.max_items),
         {:ok, wire} <-
           bound(opts, :max_create_wire_bytes, caps.max_create_wire_bytes, caps.max_create_wire_bytes),
         {:ok, sub} <- bound(opts, :max_submission_bytes, 1024 * @mib, 256 * @mib),
         {:ok, item} <- bound(opts, :max_item_bytes, 65_536, 65_536),
         {:ok, page} <- bound(opts, :page_size, 1_000, 100),
         {:ok, line} <- bound(opts, :max_line_bytes, 16 * @mib, @mib),
         {:ok, scan} <- bound(opts, :max_scan_bytes, 1024 * @mib, 64 * @mib),
         {:ok, timeout} <- bound(opts, :receive_timeout_ms, 600_000, 120_000) do
      {:ok,
       %Config{
         submit_binding: opts[:submit_binding],
         cancel_binding: opts[:cancel_binding],
         tenant: opts[:tenant],
         provider: provider,
         provider_config: Keyword.get(opts, :provider_config),
         credentials: opts[:credentials],
         submissions: opts[:submissions],
         models: models,
         max_output_tokens: out,
         max_items: items,
         max_create_wire_bytes: wire,
         max_submission_bytes: sub,
         max_item_bytes: item,
         page_size: page,
         max_line_bytes: line,
         max_scan_bytes: scan,
         receive_timeout_ms: timeout,
         sink: opts[:sink],
         seal_key: :crypto.strong_rand_bytes(32)
       }}
    else
      _ -> {:error, :configuration}
    end
  rescue
    _ -> {:error, :configuration}
  end

  def configure(_), do: {:error, :configuration}

  defp bound(opts, key, max, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n >= 1 and n <= max -> {:ok, n}
      _ -> :error
    end
  end

  @doc false
  def bounds(%Config{} = c),
    do: %{
      max_submission_bytes: c.max_submission_bytes,
      max_item_bytes: c.max_item_bytes,
      max_items: c.max_items
    }

  @doc false
  # The text interface's Config for the neutral item checks (no binding, sink or
  # credential: Elzoo.AiText.check/2 reads only the allowlist, output cap,
  # tenant and provider).
  def text_config(%Config{} = c) do
    struct!(Elzoo.AiText.Config,
      binding: nil,
      tenant: c.tenant,
      provider: c.provider.capabilities().item_provider,
      provider_config: nil,
      credentials: nil,
      models: c.models,
      max_request_bytes: c.max_item_bytes,
      max_output_tokens: c.max_output_tokens,
      receive_timeout_ms: c.receive_timeout_ms,
      sink: nil,
      seal_key: nil
    )
  end

  ## submit

  @doc """
  Admits a submit declaration: untrusted classification, capability
  `integration/ai-batch`, operation `submit`, command schema
  `elzoo/ai-batch-submission` version 1, explicit `idempotency_key` (the dispatch
  identity) and `deadline_unix_ms`, payload the submission JSON
  (`Elzoo.AiBatch.Submission`). Returns `{:ok, %{key, identity, arguments,
  deadline, binding_digest, manifest_digest, submission}}` (`arguments` is the
  manifest; the host stages `submission` for the lookup Need and starts
  `Elzoo.EffectIntent` with `adapter_context: config`), `{:error, {:refused,
  reason, %{retry_after: nil, orphans: []}}}` with `reason` in
  `:invalid_request | :unsupported_feature | :too_large`, or
  `{:error, :declaration}`. It never creates an intent, reads the credential or
  sends a request.
  """
  def admit_submit(%Config{} = c, declaration) do
    with {:ok, command, ref, deadline} <- command(declaration, "submit", @submit_schema),
         payload when is_binary(payload) <- command["payload"],
         {:ok, b} <- Binding.load(c.submit_binding, :submit),
         {:ok, _} <- Elzoo.EffectIntent.Binding.recovery_deadline(deadline, b.recovery_grace_ms) do
      with {:ok, submission, canonical} <- Submission.decode(payload, bounds(c)),
           {:ok, _wire} <- prepare(c, submission) do
        manifest = Submission.manifest(submission, canonical)
        identity = [c.tenant, b.provider_account, b.id, b.operation, ref]

        {:ok,
         %{
           key: Elzoo.EffectIntent.Model.key(identity),
           identity: identity,
           arguments: manifest,
           deadline: deadline,
           binding_digest: b.digest,
           manifest_digest: Submission.sha256(manifest),
           submission: canonical
         }}
      else
        {:error, reason} when reason in [:invalid_request, :unsupported_feature, :too_large] ->
          refused(reason)

        _ ->
          refused(:invalid_request)
      end
    else
      _ -> {:error, :declaration}
    end
  rescue
    _ -> {:error, :declaration}
  end

  def admit_submit(_, _), do: {:error, :declaration}

  defp refused(reason), do: {:error, {:refused, reason, %{retry_after: nil, orphans: []}}}

  @doc """
  The neutral checks shared by admission and the Adapter: declared and valid
  provider options; each item through `Elzoo.AiText.check/2` (the same checks and
  pure translation as a synchronous call); the provider's pure `prepare/2`; and
  the exact create body against `max_create_wire_bytes`. Returns `{:ok, wire}`
  or `{:error, reason}`.
  """
  def prepare(%Config{} = c, submission) do
    caps = c.provider.capabilities()
    text = text_config(c)

    with true <- options_valid?(submission.provider_options, caps.options) || {:error, :invalid_request},
         {:ok, items} <- items(text, submission.items),
         {:ok, %{body: body} = wire} when is_binary(body) <-
           c.provider.prepare(%{submission | items: items}, c.provider_config) do
      if byte_size(body) <= c.max_create_wire_bytes,
        do: {:ok, wire},
        else: {:error, :too_large}
    else
      {:refused, r} when r in [:invalid_request, :unsupported_feature, :too_large] -> {:error, r}
      {:error, r} when r in [:invalid_request, :unsupported_feature, :too_large] -> {:error, r}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp items(text, items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case Elzoo.AiText.check(text, item.request) do
        {:ok, wire} -> {:cont, {:ok, [Map.put(item, :wire, wire) | acc]}}
        {:error, r} -> {:halt, {:error, r}}
      end
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  defp options_valid?(options, declared) do
    Enum.all?(options, fn {k, v} ->
      case Map.fetch(declared, k) do
        {:ok, validator} -> validator.(v) == :ok
        :error -> false
      end
    end)
  end

  ## cancel

  @doc """
  Admits a cancel declaration: capability `integration/ai-batch`, operation
  `cancel`, command schema `elzoo/ai-batch-cancel` version 1, `idempotency_key`
  the caller's cancel identity (1..120 bytes), payload
  `{"version": 1, "job_ref": {"provider", "provider_job_id", "submitted_at"}}`
  naming a job of this provider (job id 1..128 bytes). The intent identity's
  request reference joins the job id and the cancel identity, so one cancel
  identity names one job. Returns `{:ok, %{key, identity, arguments, deadline}}`,
  `{:error, {:refused, :invalid_request, %{retry_after: nil}}}` or
  `{:error, :declaration}`.
  """
  def admit_cancel(%Config{} = c, declaration) do
    with {:ok, command, ref, deadline} <- command(declaration, "cancel", @cancel_schema),
         true <- byte_size(ref) <= 120,
         payload when is_binary(payload) <- command["payload"],
         {:ok, b} <- Binding.load(c.cancel_binding, :cancel),
         {:ok, _} <- Elzoo.EffectIntent.Binding.recovery_deadline(deadline, b.recovery_grace_ms) do
      case cancel_arguments(c, payload) do
        {:ok, job_ref, canonical} ->
          id = job_ref.provider_job_id
          identity = [c.tenant, b.provider_account, b.id, b.operation, "#{byte_size(id)}:#{id}:#{ref}"]

          {:ok,
           %{
             key: Elzoo.EffectIntent.Model.key(identity),
             identity: identity,
             arguments: canonical,
             deadline: deadline
           }}

        _ ->
          {:error, {:refused, :invalid_request, %{retry_after: nil}}}
      end
    else
      _ -> {:error, :declaration}
    end
  rescue
    _ -> {:error, :declaration}
  end

  def admit_cancel(_, _), do: {:error, :declaration}

  @doc false
  def cancel_arguments(%Config{} = c, payload) when is_binary(payload) and byte_size(payload) <= 4096 do
    with {:ok, %{"version" => 1, "job_ref" => %{} = r} = v} when map_size(v) == 2 <-
           Jason.decode(payload),
         true <- Enum.sort(Map.keys(r)) == ["provider", "provider_job_id", "submitted_at"],
         {:ok, job_ref} <- job_ref(c, r) do
      {:ok, job_ref, Elzoo.AiText.Request.canonical(v)}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def cancel_arguments(_, _), do: {:error, :invalid_request}

  defp job_ref(c, %{"provider" => p, "provider_job_id" => id, "submitted_at" => at}),
    do: job_ref(c, %{provider: p, provider_job_id: id, submitted_at: at})

  defp job_ref(c, %{} = ref) do
    with {:ok, ref} <- Job.validate_ref(ref),
         true <- ref.provider == c.provider.capabilities().provider,
         true <- byte_size(ref.provider_job_id) <= 128 do
      {:ok, ref}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp job_ref(_, _), do: {:error, :invalid_request}

  defp command(declaration, operation, schema) do
    with {:ok, _} <- Elzoo.Effect.validate(declaration),
         "untrusted" <- declaration["classification"],
         @capability <- declaration["capability_id"],
         ^operation <- declaration["operation"],
         command = declaration["command"],
         ^schema <- command["schema_id"],
         1 <- command["schema_version"],
         ref when is_binary(ref) <- command["idempotency_key"],
         true <- Elzoo.AiModel.text?(ref, 256),
         deadline when is_integer(deadline) and deadline >= 0 and deadline <= @max_bigint <-
           command["deadline_unix_ms"] do
      {:ok, command, ref, deadline}
    else
      _ -> {:error, :declaration}
    end
  end

  ## reads

  @doc """
  Reads the job's state: `{:ok, %{state: job_state}}` or `{:error, reason}` with
  `reason` in `read_reasons/0`. One request; the credential comes from the
  injected Need.
  """
  def status(%Config{} = c, job_ref) do
    with {:ok, ref} <- job_ref(c, job_ref),
         {:ok, secret} <- credential(c) do
      case c.provider.status(ref.provider_job_id, call_opts(c, secret)) do
        {:ok, state} ->
          case Job.validate_state(state) do
            {:ok, state} -> {:ok, %{state: state}}
            _ -> {:error, :malformed_response}
          end

        {:failure, tag, _meta} ->
          {:error, read_reason(tag)}

        _ ->
          {:error, :provider_error}
      end
    end
  rescue
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end

  def status(_, _), do: {:error, :invalid_request}

  @doc """
  Reads one bounded page of results from `cursor` (the ordinal of the first
  result line; it must equal the join's next cursor) and joins it to the
  submitted items by item id. Returns `{:ok, %{items, next: cursor | :done,
  join}}`, items `{item_id, {:succeeded, completed} | {:errored, class} |
  :cancelled | :expired}` (`class` in `:invalid_request | :provider_error |
  :malformed_response`), or `{:error, reason}` with `reason` in
  `results_reasons/0`; on an error the join is unchanged.
  """
  def results(%Config{} = c, job_ref, cursor, %Join{} = join)
      when is_integer(cursor) and cursor >= 0 do
    with true <- cursor == join.next and not join.done || {:error, :invalid_request},
         {:ok, ref} <- job_ref(c, job_ref),
         {:ok, secret} <- credential(c) do
      page_opts = %{
        cursor: cursor,
        page_size: c.page_size,
        max_line_bytes: c.max_line_bytes,
        max_scan_bytes: c.max_scan_bytes
      }

      case c.provider.results(ref.provider_job_id, page_opts, call_opts(c, secret)) do
        {:ok, %{lines: lines, done: done}} when is_list(lines) and is_boolean(done) ->
          page(c, join, cursor, lines, done)

        {:failure, tag, _} when tag in [:result_line_limit, :result_scan_limit] ->
          {:error, tag}

        {:failure, tag, _} ->
          {:error, read_reason(tag)}

        _ ->
          {:error, :malformed_response}
      end
    end
  rescue
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end

  def results(_, _, _, _), do: {:error, :invalid_request}

  defp page(c, join, cursor, lines, done) do
    with true <- length(lines) <= c.page_size || {:error, :malformed_page},
         true <- Enum.all?(lines, &match?({id, _} when is_binary(id), &1)) || {:error, :malformed_page},
         {:ok, joined} <- Join.add(join, cursor, lines, done) do
      caps = c.provider.capabilities()
      item_provider = caps.item_provider

      items =
        Enum.map(lines, fn {id, result} ->
          {:ok, request} = Join.request(joined, id)
          {id, item(caps, item_provider, request, result)}
        end)

      if Enum.all?(items, fn {_, r} -> r != :invalid end),
        do: {:ok, %{items: items, next: if(done, do: :done, else: joined.next), join: joined}},
        else: {:error, :malformed_page}
    end
  end

  defp item(caps, item_provider, request, {:succeeded, exchange}) do
    with {:ok, raw} <- item_provider.decode(exchange, request),
         {:completed, completed} <- Elzoo.AiBatch.Completion.complete(caps, request, raw) do
      {:succeeded, completed}
    else
      _ -> {:errored, :malformed_response}
    end
  rescue
    _ -> {:errored, :malformed_response}
  end

  defp item(_, _, _, {:errored, class}) when class in [:invalid_request, :provider_error],
    do: {:errored, class}

  defp item(_, _, _, :cancelled), do: :cancelled
  defp item(_, _, _, :expired), do: :expired
  defp item(_, _, _, _), do: :invalid

  @doc false
  def read_reason(tag) do
    case Outcome.contract(tag) do
      {:ok, {_, reason}} when reason != :credentials_unavailable -> reason
      _ -> :provider_error
    end
  end

  @doc false
  def call_opts(%Config{} = c, secret),
    do: %{
      credential: secret,
      receive_timeout_ms: c.receive_timeout_ms,
      provider_config: c.provider_config
    }

  @doc false
  # The injected Need: {:ok, binary} of 1..1024 printable ASCII bytes without
  # whitespace. Anything else, or a raise/throw/exit, is credentials_unavailable.
  # The value is never inspected or interpolated.
  def credential(%Config{credentials: need}) do
    case need.() do
      {:ok, secret} when is_binary(secret) and byte_size(secret) in 1..1024 ->
        if printable?(secret), do: {:ok, secret}, else: {:error, :credentials_unavailable}

      _ ->
        {:error, :credentials_unavailable}
    end
  rescue
    _ -> {:error, :credentials_unavailable}
  catch
    _, _ -> {:error, :credentials_unavailable}
  end

  defp printable?(<<>>), do: true
  defp printable?(<<ch, rest::binary>>) when ch in 0x21..0x7E, do: printable?(rest)
  defp printable?(_), do: false
end
