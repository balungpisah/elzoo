# SPDX-License-Identifier: Apache-2.0
recipe_helper = Path.expand("recipe_test_helper.exs", __DIR__)

recipe_helper =
  if File.regular?(recipe_helper),
    do: recipe_helper,
    else:
      Path.expand(
        "../../../../runtime/recipe-test/test/support/recipe_test_helper.exs",
        __DIR__
      )

Code.require_file(recipe_helper)

defmodule Elzoo.Eval do
  @moduledoc """
  Versioned datasets of scripted recipe cases, read through `state/artifact`, run case by
  case through `Elzoo.RecipeTest.run/1` and scored into a report that is a plain value.
  A test-time helper: call `run/2` inside an ExUnit test of a module that started what
  `runtime/recipe-test` needs.
  """

  @max_bytes 16_777_216
  @max_version 2_147_483_647
  @outcomes %{
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "out_of_budget" => :out_of_budget,
    "out_of_time" => :out_of_time
  }
  @classes %{"failed" => :failed, "refused" => :refused, "unknown" => :unknown}
  @port %{
    "id" => "elzoo.eval.structured",
    "direction" => "output",
    "schema_id" => "elzoo.eval.structured",
    "schema_version" => 1
  }

  ## Dataset format, version 1

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) > @max_bytes,
    do: fault([], :too_large)

  def decode(bytes) when is_binary(bytes) do
    with {:ok, root} <- json_decode(bytes),
         :ok <- format_version(root),
         {:ok, root} <- object(root, [], root_fields()) do
      identity = %{
        dataset_id: root["dataset_id"],
        version: root["version"],
        sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      }

      {:ok, %{identity: identity, cases: root["cases"]}}
    end
  end

  def decode(_), do: fault([], :type)

  def load(artifact, caller, artifact_id, version) do
    case Elzoo.Artifact.get(artifact, caller, artifact_id, version) do
      {:ok, %{bytes: bytes}} -> decode(bytes)
      {:error, {:integrity_mismatch, _}} -> {:error, :integrity_mismatch}
      _ -> {:error, :artifact_unavailable}
    end
  end

  defp json_decode(bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, root} -> {:ok, root}
      {:error, _} -> fault([], :json)
    end
  end

  # A later format is refused as a whole, before its members are read as version 1.
  defp format_version(%Jason.OrderedObject{values: members}) do
    case List.keyfind(members, "format_version", 0) do
      {_, value} when value !== 1 -> fault(["format_version"], :format_version)
      _ -> :ok
    end
  end

  defp format_version(_), do: fault([], :type)

  defp root_fields,
    do: [
      {"format_version", fn _, _ -> {:ok, 1} end},
      {"dataset_id", &id/2},
      {"version", &int(&1, &2, 1, @max_version)},
      {"cases", &cases/2}
    ]

  defp cases(value, path) do
    items(value, path, 1, 256, MapSet.new(), fn item, item_path, seen ->
      fields = [
        {"case_id", &unique(&1, &2, seen, :duplicate_case)},
        {"input", &input/2},
        {"script", &script/2},
        {"restart_after", &restart_after/2},
        {"checks", &checks/2}
      ]

      with {:ok, c} <- object(item, item_path, fields) do
        decoded = %{
          case_id: c["case_id"],
          input: c["input"],
          script: c["script"],
          restart_after: c["restart_after"],
          checks: c["checks"]
        }

        {:ok, decoded, MapSet.put(seen, c["case_id"])}
      end
    end)
  end

  defp unique(value, path, seen, reason) do
    with {:ok, id} <- id(value, path) do
      if MapSet.member?(seen, id), do: fault(path, reason), else: {:ok, id}
    end
  end

  defp input(%Jason.OrderedObject{} = value, path), do: json(value, path)
  defp input("", path), do: fault(path, :bounds)
  defp input(value, _path) when is_binary(value), do: {:ok, value}
  defp input(_, path), do: fault(path, :type)

  defp restart_after(nil, _path), do: {:ok, nil}
  defp restart_after(value, path), do: int(value, path, 1, nil)

  defp script(value, path) do
    with {:ok, entries} <-
           items(value, path, 0, 256, MapSet.new(), fn item, item_path, seen ->
             fields = [
               {"key", &script_key(&1, &2, seen)},
               {"results", &results/2}
             ]

             with {:ok, entry} <- object(item, item_path, fields),
                  do: {:ok, {entry["key"], entry["results"]}, MapSet.put(seen, entry["key"])}
           end),
         do: {:ok, Map.new(entries)}
  end

  defp script_key(%Jason.OrderedObject{values: [{name, _} | _]} = value, path, seen)
       when name in ["model", "tool"] do
    with {:ok, key} <- object(value, path, [{name, &text/2}]) do
      key = {if(name == "model", do: :model, else: :tool), key[name]}
      if MapSet.member?(seen, key), do: fault(path, :duplicate_script_key), else: {:ok, key}
    end
  end

  defp script_key(%Jason.OrderedObject{values: [{name, _} | _]}, path, _seen),
    do: fault(path ++ [name], :unknown_key)

  defp script_key(%Jason.OrderedObject{values: []}, path, _seen),
    do: fault(path ++ ["model"], :missing_key)

  defp script_key(_, path, _seen), do: fault(path, :type)

  defp results(value, path) do
    items(value, path, 1, 256, nil, fn item, item_path, nil ->
      variants = %{
        "completed" => [{"value", &json/2}],
        "failed" => [{"reason", &reason/2}],
        "refused" => [{"reason", &reason/2}],
        "unknown" => [{"reason", &reason/2}]
      }

      with {:ok, entry} <- tagged(item, item_path, "class", variants, :bounds) do
        result =
          case entry["class"] do
            "completed" -> {:completed, entry["value"]}
            class -> {Map.fetch!(@classes, class), entry["reason"]}
          end

        {:ok, result, nil}
      end
    end)
  end

  defp reason(value, path) when is_binary(value) do
    if value =~ ~r/\A[a-z0-9_]{1,64}\z/, do: {:ok, value}, else: fault(path, :bounds)
  end

  defp reason(_, path), do: fault(path, :type)

  defp checks(value, path) do
    items(value, path, 1, 16, nil, fn item, item_path, nil ->
      with {:ok, check} <- tagged(item, item_path, "kind", check_kinds(), :unknown_kind),
           do: {:ok, check(check), nil}
    end)
  end

  defp check_kinds,
    do: %{
      "outcome_is" => [{"outcome", &outcome/2}],
      "final_text_equals" => [{"text", &bytes(&1, &2, 1, 65_536)}],
      "final_text_contains" => [{"text", &bytes(&1, &2, 1, 65_536)}],
      "structured_matches" => [{"schema", &schema/2}],
      "tool_called" => [{"alias", &text/2}, {"at_least", &int(&1, &2, 1, 256)}],
      "tool_not_called" => [{"alias", &text/2}],
      "max_steps" => [{"steps", &int(&1, &2, 1, 65_536)}]
    }

  defp check(%{"kind" => "outcome_is"} = c), do: %{kind: :outcome_is, outcome: c["outcome"]}

  defp check(%{"kind" => "final_text_equals"} = c),
    do: %{kind: :final_text_equals, text: c["text"]}

  defp check(%{"kind" => "final_text_contains"} = c),
    do: %{kind: :final_text_contains, text: c["text"]}

  defp check(%{"kind" => "structured_matches"} = c),
    do: %{kind: :structured_matches, schema: c["schema"]}

  defp check(%{"kind" => "tool_called"} = c),
    do: %{kind: :tool_called, alias: c["alias"], at_least: c["at_least"]}

  defp check(%{"kind" => "tool_not_called"} = c), do: %{kind: :tool_not_called, alias: c["alias"]}
  defp check(%{"kind" => "max_steps"} = c), do: %{kind: :max_steps, steps: c["steps"]}

  defp outcome(value, path) when is_binary(value) do
    case Map.fetch(@outcomes, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> fault(path, :bounds)
    end
  end

  defp outcome(_, path), do: fault(path, :type)

  defp schema(%Jason.OrderedObject{} = value, path) do
    with {:ok, schema} <- json(value, path) do
      case Elzoo.PayloadSchema.build(@port, schema) do
        {:ok, checked} -> {:ok, checked}
        {:error, _} -> fault(path, :schema)
      end
    end
  end

  defp schema(_, path), do: fault(path, :type)

  ## Shapes

  # An object with exactly `fields` ({key, validator}), walked in document order: a repeated
  # key, an unknown key or the first fault inside a value ends the walk; a missing key is
  # reported after the members, in the order of `fields`.
  defp object(%Jason.OrderedObject{values: members}, path, fields) do
    found =
      Enum.reduce_while(members, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        cond do
          Map.has_key?(acc, key) ->
            {:halt, fault(path ++ [key], :duplicate_key)}

          true ->
            case List.keyfind(fields, key, 0) do
              nil ->
                {:halt, fault(path ++ [key], :unknown_key)}

              {_, validate} ->
                case validate.(value, path ++ [key]) do
                  {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
                  error -> {:halt, error}
                end
            end
        end
      end)

    with {:ok, acc} <- found do
      case Enum.find(fields, fn {key, _} -> not Map.has_key?(acc, key) end) do
        nil -> {:ok, acc}
        {key, _} -> fault(path ++ [key], :missing_key)
      end
    end
  end

  defp object(_, path, _fields), do: fault(path, :type)

  # An object whose member `tag` names its variant: the first `tag` member decides the other
  # members. Before an unknown or missing tag, a member of any variant is not read.
  defp tagged(%Jason.OrderedObject{values: members} = value, path, tag, variants, unknown) do
    tag_field =
      {tag,
       fn
         name, p when is_binary(name) ->
           if Map.has_key?(variants, name), do: {:ok, name}, else: fault(p, unknown)

         _, p ->
           fault(p, :type)
       end}

    members_of =
      case List.keyfind(members, tag, 0) do
        {_, name} when is_map_key(variants, name) ->
          Map.fetch!(variants, name)

        _ ->
          for key <- Enum.uniq(for {_, fields} <- variants, {key, _} <- fields, do: key),
              do: {key, fn _, _ -> {:ok, nil} end}
      end

    object(value, path, [tag_field | members_of])
  end

  defp tagged(_, path, _tag, _variants, _unknown), do: fault(path, :type)

  # A list of min..max items; `step` decodes one item and threads `acc`.
  defp items(value, path, min, max, acc, step) when is_list(value) do
    if length(value) in min..max//1 do
      value
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], acc}, fn {item, index}, {:ok, done, acc} ->
        case step.(item, path ++ [index], acc) do
          {:ok, decoded, acc} -> {:cont, {:ok, [decoded | done], acc}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, done, _acc} -> {:ok, Enum.reverse(done)}
        error -> error
      end
    else
      fault(path, :bounds)
    end
  end

  defp items(_, path, _min, _max, _acc, _step), do: fault(path, :type)

  # JSON data with string-keyed maps; a repeated key in any object is refused.
  defp json(%Jason.OrderedObject{values: members}, path) do
    Enum.reduce_while(members, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if Map.has_key?(acc, key) do
        {:halt, fault(path ++ [key], :duplicate_key)}
      else
        case json(value, path ++ [key]) do
          {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp json(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, done} ->
      case json(item, path ++ [index]) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | done]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  defp json(value, _path), do: {:ok, value}

  # The text rule of the identities: 1..128 bytes of UTF-8 without C0 or C1 controls.
  defp id(value, path) when is_binary(value) do
    if byte_size(value) in 1..128 and printable?(value),
      do: {:ok, value},
      else: fault(path, :bounds)
  end

  defp id(_, path), do: fault(path, :type)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false

  defp text(value, _path) when is_binary(value), do: {:ok, value}
  defp text(_, path), do: fault(path, :type)

  defp bytes(value, path, min, max) when is_binary(value) do
    if byte_size(value) in min..max, do: {:ok, value}, else: fault(path, :bounds)
  end

  defp bytes(_, path, _min, _max), do: fault(path, :type)

  defp int(value, path, min, max) when is_integer(value) do
    if value >= min and (max == nil or value <= max),
      do: {:ok, value},
      else: fault(path, :bounds)
  end

  defp int(_, path, _min, _max), do: fault(path, :type)

  defp fault(path, reason), do: {:error, {:dataset, path, reason}}

  ## Score

  def score(record, checks) do
    root = root_finish(record)
    actions = for %{step: :action, action: action} <- record.steps, do: action
    results = Enum.map(checks, &result(&1, record, root, actions))
    status = if Enum.all?(results, &(&1.status == :passed)), do: :passed, else: :failed
    %{status: status, checks: results}
  end

  defp result(check, record, root, actions) do
    reason = failure(check, record, root, actions)
    %{kind: check.kind, status: if(reason, do: :failed, else: :passed), reason: reason}
  end

  defp failure(%{kind: :outcome_is, outcome: outcome}, record, _root, _actions),
    do: unless(record.outcome == outcome, do: :outcome)

  defp failure(%{kind: kind}, _record, nil, _actions)
       when kind in [:final_text_equals, :final_text_contains, :structured_matches],
       do: :no_root_finish

  defp failure(%{kind: kind, text: text}, record, root, _actions)
       when kind in [:final_text_equals, :final_text_contains] do
    case final_text(record, root) do
      nil -> :no_final_text
      final when kind == :final_text_equals -> unless(final == text, do: :text)
      final -> unless(:binary.match(final, text) != :nomatch, do: :text)
    end
  end

  defp failure(%{kind: :structured_matches, schema: schema}, _record, root, _actions),
    do: unless(Elzoo.PayloadSchema.check(schema, @port, root["payload"]) == :ok, do: :schema)

  defp failure(%{kind: :tool_called, alias: name, at_least: n}, _record, _root, actions),
    do: unless(calls(actions, name) >= n, do: :tool_count)

  defp failure(%{kind: :tool_not_called, alias: name}, _record, _root, actions),
    do: unless(calls(actions, name) == 0, do: :tool_called)

  defp failure(%{kind: :max_steps, steps: n}, _record, _root, actions),
    do: unless(length(actions) <= n, do: :steps)

  defp calls(actions, name),
    do: Enum.count(actions, &(&1["kind"] == "tool_call" and &1["payload"]["alias"] == name))

  # The last finish action of a completed record.
  defp root_finish(%{outcome: :completed, steps: steps}) do
    steps
    |> Enum.filter(&match?(%{step: :action, action: %{"kind" => "finish"}}, &1))
    |> List.last()
    |> case do
      nil -> nil
      %{action: action} -> action
    end
  end

  defp root_finish(_record), do: nil

  # The content of the completed model call that an answered agent finish names.
  defp final_text(record, %{"payload" => %{"status" => "answered", "action_id" => id}})
       when is_binary(id) do
    Enum.find_value(record.steps, fn
      %{
        step: :input,
        input: %{
          "kind" => "action_outcome",
          "action_id" => ^id,
          "outcome" => "completed",
          "payload" => %{"content" => content}
        }
      }
      when is_binary(content) ->
        content

      _ ->
        nil
    end)
  end

  defp final_text(_record, _root), do: nil

  ## Run

  def run(dataset, base_spec) do
    cases = Enum.map(dataset.cases, &run_case(&1, base_spec))
    count = fn status -> Enum.count(cases, &(&1.status == status)) end

    %{
      dataset: dataset.identity,
      package: package_identity(base_spec),
      passed: count.(:passed),
      failed: count.(:failed),
      errored: count.(:error),
      cases: cases
    }
  end

  defp package_identity(%{package: %{"identity" => identity}}), do: identity
  defp package_identity(_), do: nil

  defp run_case(c, base_spec) do
    spec = Map.merge(base_spec, %{input: c.input, script: c.script, restart_after: c.restart_after})

    outcome =
      try do
        Elzoo.RecipeTest.run(spec)
      rescue
        _ -> {:error, :harness}
      catch
        _, _ -> {:error, :harness}
      end

    case outcome do
      {:ok, record} ->
        score = score(record, c.checks)
        %{case_id: c.case_id, status: score.status, checks: score.checks, error: nil}

      {:error, reason} ->
        %{case_id: c.case_id, status: :error, checks: [], error: error(reason)}
    end
  end

  defp error(reason) when is_atom(reason), do: reason
  defp error(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp error(_reason), do: :harness
end
