# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableJob.Run do
  @moduledoc """
  Record schemas (schema_version 1 only), request validation and the two pure
  folds of `assembly/durable-job`: the submission stream `jobs/<queue>` and the
  Run stream `job/<queue>/<job_key>`. Folds raise on any record that is not
  admissible for the current phase; ELZ-009 replay turns that into a damaged
  prefix (`reducer_failure`), so a Writer refuses the stream.
  """
  @version 1
  @run_kinds ~w(accepted attempt_started attempt_failed succeeded failed exhausted expired cancelled)
  @terminal ~w(succeeded failed exhausted expired cancelled)a
  @max_inputs 64
  @int_bound 9_007_199_254_740_992

  def version, do: @version
  def submission_stream(queue), do: "jobs/" <> queue
  def run_stream(queue, job_key), do: "job/" <> queue <> "/" <> job_key

  @doc "Fold for a Store shared by both stream kinds (configure the Store with this)."
  def store_fold do
    %{
      initial: nil,
      kinds: Map.new(["requested" | @run_kinds], &{&1, :state_bearing}),
      versions: [@version],
      destinations: ["jobs"],
      reduce: &__MODULE__.reduce_run/4
    }
  end

  def limits, do: %{max_record_bytes: 4_096, max_batch_size: 2, max_checkpoint_bytes: 65_536}
  def submission_fold, do: %{store_fold() | initial: %{}, reduce: &__MODULE__.reduce_submission/4}

  def run_fold,
    do: %{
      store_fold()
      | initial: %{
          phase: :none,
          first: nil,
          request: nil,
          submission: nil,
          bound_job: 0,
          last_attempt: 0,
          last_oban_attempt: 0,
          attempts_made: 0,
          result: nil
        },
        reduce: &__MODULE__.reduce_run/4
    }

  def queue?(q),
    do: is_binary(q) and byte_size(q) in 1..32 and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, q)

  def job_key?(k),
    do:
      is_binary(k) and byte_size(k) in 1..160 and String.valid?(k) and
        not String.contains?(k, ["/", <<0>>])

  @doc "Validate a submission; returns the canonical request map or `{:error, {:invalid, field}}`."
  def request(job_key, input, policy, deadline_ms, now_ms) do
    max = Keyword.get(policy, :max_attempts, 3)
    base = Keyword.get(policy, :base_backoff_ms, 1_000)
    cap = Keyword.get(policy, :max_backoff_ms, 60_000)

    cond do
      not job_key?(job_key) ->
        {:error, {:invalid, :job_key}}

      not (is_list(input) and length(input) <= @max_inputs and Enum.all?(input, &int?/1)) ->
        {:error, {:invalid, :input}}

      not (Keyword.keyword?(policy) and is_integer(max) and max in 1..20) ->
        {:error, {:invalid, :max_attempts}}

      match?(
        {:error, _},
        Elzoo.RetryTimeout.policy(max_attempts: max, base_backoff_ms: base, max_backoff_ms: cap)
      ) ->
        {:error, {:invalid, :backoff}}

      not (is_integer(deadline_ms) and deadline_ms > now_ms) ->
        {:error, {:invalid, :deadline_ms}}

      true ->
        {:ok,
         %{
           "v" => @version,
           "job_key" => job_key,
           "input" => input,
           "max_attempts" => max,
           "base_backoff_ms" => base,
           "max_backoff_ms" => cap,
           "mode" => "redispatch_forbidden",
           "deadline_ms" => deadline_ms,
           "submitted_ms" => now_ms
         }}
    end
  end

  def policy(request) do
    {:ok, policy} =
      Elzoo.RetryTimeout.policy(
        max_attempts: request["max_attempts"],
        base_backoff_ms: request["base_backoff_ms"],
        max_backoff_ms: request["max_backoff_ms"],
        mode: :redispatch_forbidden
      )

    policy
  end

  @doc "Request identity used for duplicate detection (submitted_ms excluded)."
  def digest(request),
    do:
      :crypto.hash(
        :sha256,
        Jason.encode!(Jason.OrderedObject.new(request |> Map.delete("submitted_ms") |> Enum.sort()))
      )

  def encode(map), do: Jason.encode!(map)

  def decode!(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = map} -> map
      _ -> raise ArgumentError, "payload is not a JSON object"
    end
  end

  def reduce_submission(model, "requested", 1, payload) do
    request = decode!(payload)
    key = request["job_key"]
    if not job_key?(key) or Map.has_key?(model, key), do: raise(ArgumentError, "bad submission")
    Map.put(model, key, digest(request))
  end

  def reduce_submission(_, _, _, _), do: raise(ArgumentError, "not a submission record")

  def terminal?(phase), do: phase in @terminal

  def reduce_run(model, kind, 1, payload) when kind in @run_kinds do
    data = decode!(payload)
    run(model, kind, data)
  end

  def reduce_run(_, _, _, _), do: raise(ArgumentError, "not a Run record")

  defp run(%{phase: :none} = m, "accepted", %{"request" => r, "submission" => s}) when is_map(r),
    do: %{m | phase: :requested, first: "accepted", request: r, submission: s}

  defp run(%{phase: :none} = m, "cancelled", %{"attempt" => 0}),
    do: %{m | phase: :cancelled, first: "cancelled"}

  defp run(%{phase: p} = m, "attempt_started", %{
         "attempt" => n,
         "oban_job_id" => j,
         "oban_attempt" => k
       })
       when p in [:requested, :waiting, :active] and is_integer(j) and is_integer(k) do
    if n != m.attempts_made + 1 or (m.bound_job != 0 and m.bound_job != j),
      do: raise(ArgumentError, "inconsistent attempt")

    %{m | phase: :active, bound_job: j, last_attempt: n, last_oban_attempt: k, attempts_made: n}
  end

  defp run(%{phase: :active, last_attempt: n} = m, "attempt_failed", %{"attempt" => n}),
    do: %{m | phase: :waiting}

  defp run(%{phase: :active, last_attempt: n} = m, "succeeded", %{"attempt" => n, "result" => r}),
    do: %{m | phase: :succeeded, result: r}

  defp run(%{phase: p} = m, kind, %{"attempt" => n})
       when p in [:requested, :waiting, :active] and kind in ~w(failed exhausted expired cancelled) and
              is_integer(n),
       do: %{m | phase: String.to_existing_atom(kind)}

  defp run(_, kind, _), do: raise(ArgumentError, "inadmissible #{kind}")

  defp int?(v), do: is_integer(v) and abs(v) <= @int_bound
end
