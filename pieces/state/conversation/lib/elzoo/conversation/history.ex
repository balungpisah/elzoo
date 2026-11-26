# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Conversation.History do
  @moduledoc """
  The pure model of one conversation and its decisions. The model maps each
  message ID to its kind and content digest, and each input to its Run
  association and whether it is answered. The Cure table `decide/2` of
  `cure/elzoo/conversation.cure` decides every write; Elixir computes the
  checks it reads. Stored history is folded with the same decisions: each
  stored row must be a new admissible record, so a duplicate ID, a reference
  before its definition, a second association, a second answer or a repeated
  identical row is damage.
  """
  alias Elzoo.Conversation.Record

  @cure :"Cure.Elzoo.Conversation"

  @doc "The model of an empty conversation."
  def new, do: %{messages: %{}, inputs: %{}}

  @doc """
  Decide one validated entry against the model. `completed` is the answer's Run
  completion fact. Returns `:proceed`, `:already_present` or `{:refused, code}`.
  """
  def decide(model, entry, completed \\ true),
    do: decision(entry.kind, checks(model, entry, completed))

  @doc "Apply an entry that `decide/3` admitted."
  def admit(model, %{kind: :input} = entry) do
    id = :binary.copy(entry.message_id)

    %{
      model
      | messages: Map.put(model.messages, id, {:input, entry.digest}),
        inputs: Map.put(model.inputs, id, {nil, false})
    }
  end

  def admit(model, %{kind: :association} = entry) do
    {nil, answered} = Map.fetch!(model.inputs, entry.input_message_id)
    run = :binary.copy(entry.run_id)
    %{model | inputs: Map.put(model.inputs, entry.input_message_id, {run, answered})}
  end

  def admit(model, %{kind: :answer} = entry) do
    {run, false} = Map.fetch!(model.inputs, entry.input_message_id)

    %{
      model
      | messages: Map.put(model.messages, :binary.copy(entry.message_id), {:answer, entry.digest}),
        inputs: Map.put(model.inputs, entry.input_message_id, {run, true})
    }
  end

  @doc """
  Validate stored rows as the records from `sequence` on and fold them. Each
  row must decode (`Elzoo.Conversation.Record.decode/5`) and be a new
  admissible record of the folded history. Returns `{:ok, model, next_sequence}`
  or `{:error, :damaged}`.
  """
  def fold_rows(model, rows, context, sequence) do
    Enum.reduce_while(rows, {:ok, model, sequence}, fn row, {:ok, model, sequence} ->
      with {:ok, entry} <-
             Record.decode(row, context.stream, sequence, context.fold, context.limits),
           :proceed <- decide(model, entry) do
        {:cont, {:ok, admit(model, entry), sequence + 1}}
      else
        _ -> {:halt, {:error, :damaged}}
      end
    end)
  end

  @doc """
  Decide prepared intents in order against a copy of the model: an admitted
  intent is applied to the copy before the next one is decided. Each intent is
  `{:ok, entry, completed}` or `:invalid` (a malformed DTO). Returns one
  decision per intent: `:ok`, `{:ok, :already_present}` or `{:refused, code}`.
  """
  def check(model, intents) do
    {decisions, _model} =
      Enum.map_reduce(intents, model, fn
        :invalid, model ->
          {{:refused, "invalid_request"}, model}

        {:ok, entry, completed}, model ->
          case decide(model, entry, completed) do
            :proceed -> {:ok, admit(model, entry)}
            :already_present -> {{:ok, :already_present}, model}
            {:refused, code} -> {{:refused, code}, model}
          end
      end)

    decisions
  end

  @doc "The nine booleans that the Cure table reads, for one entry against the model."
  def checks(model, %{kind: :input} = entry, _completed) do
    existing = Map.get(model.messages, entry.message_id)

    flags(
      identical: existing == {:input, entry.digest},
      duplicate_message_id: existing != nil
    )
  end

  def checks(model, %{kind: :association} = entry, _completed) do
    input = Map.get(model.messages, entry.input_message_id)
    {run, _answered} = Map.get(model.inputs, entry.input_message_id, {nil, false})

    flags(
      identical: run != nil and run == entry.run_id,
      input_exists: input != nil,
      input_is_input: match?({:input, _}, input),
      already_associated: run != nil
    )
  end

  def checks(model, %{kind: :answer} = entry, completed) do
    existing = Map.get(model.messages, entry.message_id)
    input = Map.get(model.messages, entry.input_message_id)
    {run, answered} = Map.get(model.inputs, entry.input_message_id, {nil, false})

    flags(
      identical: existing == {:answer, entry.digest},
      duplicate_message_id: existing != nil,
      input_exists: input != nil,
      input_is_input: match?({:input, _}, input),
      association_exists: run != nil,
      association_matches: run != nil and run == entry.run_id,
      already_answered: answered,
      completed: completed == true
    )
  end

  @doc "Run the compiled Cure `decide/2` for a mode and its checks."
  def decision(mode, checks) do
    flags = [
      checks.identical,
      checks.duplicate_message_id,
      checks.input_exists,
      checks.input_is_input,
      checks.already_associated,
      checks.association_exists,
      checks.association_matches,
      checks.already_answered,
      checks.completed
    ]

    cure_mode =
      case mode do
        :input -> :AppendInput
        :association -> :AssociateRun
        :answer -> :AppendAnswer
      end

    case Kernel.apply(@cure, :decide, [cure_mode, List.to_tuple([:ConversationChecks | flags])]) do
      :ConversationProceed -> :proceed
      :ConversationAlreadyPresent -> :already_present
      :ConversationDuplicateMessageId -> {:refused, "duplicate_message_id"}
      :ConversationMissingInput -> {:refused, "missing_input"}
      :ConversationAlreadyAssociated -> {:refused, "already_associated"}
      :ConversationRunNotCompleted -> {:refused, "run_not_completed"}
      :ConversationAssociationMismatch -> {:refused, "association_mismatch"}
      :ConversationAlreadyAnswered -> {:refused, "already_answered"}
    end
  end

  defp flags(values) do
    [
      identical: false,
      duplicate_message_id: false,
      input_exists: false,
      input_is_input: false,
      already_associated: false,
      association_exists: false,
      association_matches: false,
      already_answered: false,
      completed: false
    ]
    |> Keyword.merge(values)
    |> Map.new()
  end
end
