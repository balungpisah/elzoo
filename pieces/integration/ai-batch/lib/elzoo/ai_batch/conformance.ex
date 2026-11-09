# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Conformance do
  @moduledoc """
  The provider conformance kit of the batch interface: provider-neutral scenario
  data plus plain check functions (no ExUnit macro, no test-only dependency),
  exported with the interface so every provider Piece, and every consumer that
  copies one, runs the same expectations.

  A provider's own test realizes each scenario's stub meaning in its documented
  format (the kit never sees provider formats or stubs), drives the operation
  through `Elzoo.AiBatch` (and the EffectIntent owner for submit and cancel), and
  passes what it observed to the matching check, which returns `:ok` or
  `{:error, scenario, reason}`.

  The standard submission has four items, `item-a` to `item-d`, each an
  `integration/ai-text` request for one model.

  Scenarios and stub meanings:

  - `:submit_accepted`: the provider accepts the batch (job id `"job-1"`).
  - `:submit_lost`: a transport timeout after the create request was sent.
  - `:submit_throttled`: the documented rate-limit status with a 7-second
    retry-after.
  - `:status_sequence`: three reads answering in progress, cancelling or ending,
    then ended with counts `succeeded 1, errored 1, cancelled 1, expired 1`.
  - `:results_mixed`: one page, out of submission order: `item-d` expired,
    `item-a` succeeded (text `text/0`), `item-c` cancelled, `item-b` errored as
    an invalid request.
  - `:results_unknown_id`: a page naming `item-z`.
  - `:results_duplicate_id`: a page naming `item-a` twice.
  - `:results_missing`: an ended job whose results name only `item-a` to
    `item-c`.
  - `:cancel_accepted`: the provider acknowledges the cancel (cancelling).
  - `:cancel_lost`: a transport timeout after the cancel request was sent.
  - `:status_unauthorized`, `:status_not_found`: the documented 401 and 404.
  """
  alias Elzoo.AiBatch.Join

  @text "Batch conformance reply."
  @ids ["item-a", "item-b", "item-c", "item-d"]

  @scenarios [
    :submit_accepted,
    :submit_lost,
    :submit_throttled,
    :status_sequence,
    :results_mixed,
    :results_unknown_id,
    :results_duplicate_id,
    :results_missing,
    :cancel_accepted,
    :cancel_lost,
    :status_unauthorized,
    :status_not_found
  ]

  def text, do: @text
  def ids, do: @ids
  def scenarios, do: @scenarios

  @doc "The text request of item `id` for `model`."
  def item_request(id, model) do
    %{
      "version" => 1,
      "model" => model,
      "messages" => [
        %{"role" => "system", "text" => "Answer briefly."},
        %{"role" => "user", "text" => "Batch conformance prompt for " <> id <> "."}
      ],
      "max_output_tokens" => 256
    }
  end

  @doc "The standard submission object (or one over `ids`)."
  def submission(model, ids \\ @ids) do
    %{
      "version" => 1,
      "model" => model,
      "items" => Enum.map(ids, &%{"item_id" => &1, "request" => item_request(&1, model)})
    }
  end

  @doc "A submit declaration carrying `submission` for dispatch identity `ref`."
  def submit_declaration(submission, ref, deadline_unix_ms),
    do: declaration("submit", "elzoo/ai-batch-submission", submission, ref, deadline_unix_ms)

  @doc "A cancel declaration for `job_ref` with cancel identity `ref`."
  def cancel_declaration(job_ref, ref, deadline_unix_ms) do
    payload = %{
      "version" => 1,
      "job_ref" => %{
        "provider" => job_ref.provider,
        "provider_job_id" => job_ref.provider_job_id,
        "submitted_at" => job_ref.submitted_at
      }
    }

    declaration("cancel", "elzoo/ai-batch-cancel", payload, ref, deadline_unix_ms)
  end

  defp declaration(operation, schema, payload, ref, deadline) do
    %{
      "capability_id" => "integration/ai-batch",
      "operation" => operation,
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "msg-" <> ref,
        "schema_id" => schema,
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "conformance", "port_id" => "out"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => deadline,
        "payload" => Elzoo.AiText.Request.canonical(payload)
      }
    }
  end

  @doc "Checks a submit or cancel sink delivery and the observed request count."
  def check_write(id, delivery, requests) do
    o = outcome(delivery)

    result =
      cond do
        requests != 1 -> {:error, {:requests, requests}}
        true -> write(id, o)
      end

    tag(result, id)
  end

  defp write(:submit_accepted, {:submitted, %{job_ref: r, item_count: 4, orphans: []}}),
    do: is(r.provider_job_id == "job-1", :job_ref)

  defp write(:submit_lost, o), do: is(o == {:unknown, :timeout, %{orphans: []}}, :outcome)

  defp write(:submit_throttled, o),
    do: is(o == {:refused, :throttled, %{retry_after: 7, orphans: []}}, :outcome)

  defp write(:cancel_accepted, {:cancelled, state}), do: is(state in [:ending, :cancelled], :state)
  defp write(:cancel_lost, o), do: is(o == {:unknown, :timeout}, :outcome)
  defp write(_, _), do: {:error, :outcome}

  @doc "Checks the three `status/2` results of `:status_sequence`, or one of the error scenarios."
  def check_status(:status_sequence, [r1, r2, r3]) do
    with :ok <- is(r1 == {:ok, %{state: :running}} or r1 == {:ok, %{state: :pending}}, :first),
         :ok <- is(r2 == {:ok, %{state: :ending}}, :second) do
      is(
        r3 == {:ok, %{state: {:ended, %{succeeded: 1, errored: 1, cancelled: 1, expired: 1}}}},
        :third
      )
    end
    |> tag(:status_sequence)
  end

  def check_status(:status_unauthorized, r),
    do: is(r == {:error, :authentication_failed}, :outcome) |> tag(:status_unauthorized)

  def check_status(:status_not_found, r),
    do: is(r == {:error, :not_found}, :outcome) |> tag(:status_not_found)

  def check_status(id, _), do: {:error, id, :unknown_scenario}

  @doc "Checks a `results/4` return (and, for `:results_missing`, the job state)."
  def check_results(id, result, job_state \\ nil)

  def check_results(:results_mixed, {:ok, %{items: items, next: :done, join: j}}, _) do
    by_id = Map.new(items)

    with :ok <- is(Enum.map(items, &elem(&1, 0)) == ["item-d", "item-a", "item-c", "item-b"], :order),
         :ok <- is(by_id["item-d"] == :expired and by_id["item-c"] == :cancelled, :not_attempted),
         :ok <- is(by_id["item-b"] == {:errored, :invalid_request}, :errored),
         {:succeeded, c} <- by_id["item-a"] || {:error, :succeeded},
         :ok <- is(c.content == @text and c.finish == :stop, :completed),
         :ok <- is(is_integer(Elzoo.AiModel.Usage.amount(c.usage, :output_tokens)), :usage) do
      is(Join.missing(j, {:ended, %{succeeded: 1, errored: 1, cancelled: 1, expired: 1}}) == {:ok, []}, :missing)
    else
      {:error, _} = e -> e
      _ -> {:error, :succeeded}
    end
    |> tag(:results_mixed)
  end

  def check_results(id, r, _) when id in [:results_unknown_id, :results_duplicate_id],
    do: is(r == {:error, :malformed_page}, :outcome) |> tag(id)

  def check_results(:results_missing, {:ok, %{next: :done, join: j}}, state) do
    is(Join.missing(j, state) == {:ok, ["item-d"]}, :missing) |> tag(:results_missing)
  end

  def check_results(id, _, _), do: {:error, id, :outcome}

  defp outcome({:outcome, _attempt, o}), do: o
  defp outcome(other), do: {:no_outcome, other}

  defp tag(:ok, _), do: :ok
  defp tag({:error, reason}, id), do: {:error, id, reason}

  defp is(true, _), do: :ok
  defp is(_, reason), do: {:error, reason}
end
