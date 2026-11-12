# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunEngine.DocumentPublication do
  @moduledoc """
  Pure non-agent caller. The host binds nested_callable to validation/2 with
  typed document input and a narrowed share, local_work to its validator,
  ask_person to an authenticated editor and tool_call to exact publication.
  Authorization, genuine consent and the host gate remain engine facilities.
  The host routes the Adapter sink only after its raw outcome input commits.
  """

  def step(%{stage: :validate} = state, _input),
    do: output(%{state | stage: :material}, "validation", "nested_callable", state.document)

  def step(%{stage: :material} = state, %{"action_id" => "validation", "outcome" => "completed"}),
    do:
      output(%{state | stage: :publication}, "material", "ask_person", %{
        "question" => "Missing material?"
      })

  def step(%{stage: :publication} = state, %{"kind" => "person_answer", "payload" => material}),
    do:
      output(
        %{state | stage: :finish},
        "publication",
        "tool_call",
        Map.put(state.document, "material", material)
      )

  def step(%{stage: :finish} = state, %{"action_id" => "publication", "outcome" => "completed"}),
    do: output(%{state | stage: :done}, "finish", "finish", %{"action_id" => "publication"})

  def step(state, _), do: {:Transition, state, :none}

  def validation(:start, %{"payload" => document}),
    do: output(:finish, "validated", "local_work", document)

  def validation(:finish, %{"action_id" => "validated", "outcome" => "completed"}),
    do: output(:done, "validation_finished", "finish", %{"action_id" => "validated"})

  def validation(state, _), do: {:Transition, state, :none}

  def gate({:PatternStep, %{"actions" => [action]}}, _trusted) do
    if action["payload"]["target"] == "restricted",
      do: {:deny, "restricted_target"},
      else: :allow
  end

  defp output(state, id, kind, payload) do
    {:Transition, state,
     {:some,
      %{
        "type" => "request",
        "version" => 1,
        "actions" => [
          %{
            "id" => id,
            "kind" => kind,
            "schema_id" => "action",
            "schema_version" => 1,
            "payload" => payload
          }
        ]
      }}}
  end

  @doc "Read-only audit of complete retained history; no outbox, status or pattern calls."
  def audit(store, stream) do
    fold = %{kinds: %{"input" => :state_bearing, "result" => :state_bearing}, versions: [1]}
    read_audit(store, stream, fold, 1, nil, nil, %{verdicts: %{}, settlements: %{}, charges: %{}})
  rescue
    _ -> {:error, :incompatible_or_damaged_history}
  catch
    _, _ -> {:error, :incompatible_or_damaged_history}
  end

  defp read_audit(store, stream, fold, from, pending, previous, audit) do
    with {:ok, rows, head} <- Elzoo.DurableLog.read(store, stream, from, 1_000),
         true <- head.low_water == 0 do
      committed =
        Enum.filter(rows, fn row ->
          if row.sequence <= head.revision do
            true
          else
            true = head.capabilities.append_visibility == :staged_uncommitted_tail

            true =
              head.staged_tail == %{sequence: row.sequence, nonce: row.nonce, uncommitted: true}

            true = row.sequence == head.revision + 1
            false
          end
        end)

      {next, pending, previous, audit} =
        Enum.reduce(committed, {from, pending, previous, audit}, fn row,
                                                                    {seq, pending, previous, audit} ->
          true = row.sequence == seq
          :ok = Elzoo.DurableLog.validate_row(row, fold, %{max_record_bytes: 16_777_216})
          {1, {id, value}} = :erlang.binary_to_term(row.payload, [:safe])

          case row.kind do
            "input" ->
              true = pending == nil
              true = value.version == 1
              {seq + 1, {id, value}, previous, audit}

            "result" ->
              {^id, _record} = pending
              %{version: 1, control: control, slots: slots, requests: _} = value
              run = control.run_id

              audit =
                Enum.reduce(slots, audit, fn {key, slot}, acc ->
                  identity = {run, key}

                  acc =
                    if slot.verdict,
                      do: update_in(acc.verdicts, &Map.put_new(&1, identity, slot.verdict)),
                      else: acc

                  if slot.phase == :settled,
                    do: update_in(acc.settlements, &Map.put_new(&1, identity, slot.outcome)),
                    else: acc
                end)

              audit =
                Enum.reduce(control.receipts, audit, fn {ordinal, receipt}, acc ->
                  update_in(acc.charges, &Map.put_new(&1, {run, ordinal}, receipt.disposition))
                end)

              true = control.count == map_size(control.receipts)

              if previous && previous.control.run_id == run do
                true = control.count >= previous.control.count
              end

              {seq + 1, nil, value, audit}
          end
        end)

      if next > head.revision,
        do: {:ok, audit},
        else:
          (
            true = committed != []
            read_audit(store, stream, fold, next, pending, previous, audit)
          )
    else
      _ -> {:error, :unavailable_or_pruned_history}
    end
  end
end
