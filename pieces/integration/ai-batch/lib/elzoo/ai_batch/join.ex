# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Join do
  @moduledoc """
  The join of a batch's result pages to its submitted items, by item id only
  (never by position). Pure; the caller carries it between
  `Elzoo.AiBatch.results/4` calls.

  `new(config, submission_bytes)` decodes the submitted bytes (the same bytes the
  admission returned) and holds each item's decoded request, which the
  completion checks need, the ids already seen, the next cursor and whether the
  provider's result stream ended.

  `add(join, cursor, lines, done?)` accepts one page: the cursor must equal the
  join's next cursor (pages are contiguous); an id the submission does not name,
  or an id already seen in this or an earlier page, refuses the whole page
  (`{:error, :malformed_page}`, join unchanged).

  `missing(join, job_state)` returns `{:ok, ids}`, the submitted ids absent from
  every page, only when the stream ended and the job is `{:ended, _}`; otherwise
  `{:error, :not_ended}`. A missing item is never reported succeeded.
  """
  @enforce_keys [:requests, :seen, :next, :done]
  defstruct @enforce_keys

  defimpl Inspect do
    def inspect(j, _),
      do:
        "#Elzoo.AiBatch.Join<items: #{map_size(j.requests)}, seen: #{MapSet.size(j.seen)}, " <>
          "next: #{j.next}, done: #{j.done}>"
  end

  def new(%Elzoo.AiBatch.Config{} = c, bytes) do
    case Elzoo.AiBatch.Submission.decode(bytes, Elzoo.AiBatch.bounds(c)) do
      {:ok, s, _} ->
        {:ok,
         %__MODULE__{
           requests: Map.new(s.items, &{&1.item_id, &1.request}),
           seen: MapSet.new(),
           next: 0,
           done: false
         }}

      _ ->
        {:error, :invalid_request}
    end
  end

  def new(_, _), do: {:error, :invalid_request}

  def request(%__MODULE__{requests: r}, id), do: Map.fetch(r, id)

  def add(%__MODULE__{} = j, cursor, lines, done?) when is_list(lines) and is_boolean(done?) do
    ids = Enum.map(lines, &elem(&1, 0))

    cond do
      j.done or cursor != j.next ->
        {:error, :invalid_request}

      not Enum.all?(ids, &Map.has_key?(j.requests, &1)) ->
        {:error, :malformed_page}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, :malformed_page}

      Enum.any?(ids, &MapSet.member?(j.seen, &1)) ->
        {:error, :malformed_page}

      true ->
        {:ok,
         %{
           j
           | seen: Enum.into(ids, j.seen),
             next: j.next + length(ids),
             done: done?
         }}
    end
  end

  def add(_, _, _, _), do: {:error, :invalid_request}

  def missing(%__MODULE__{done: true} = j, {:ended, _}) do
    {:ok, j.requests |> Map.keys() |> Enum.reject(&MapSet.member?(j.seen, &1)) |> Enum.sort()}
  end

  def missing(_, _), do: {:error, :not_ended}
end
