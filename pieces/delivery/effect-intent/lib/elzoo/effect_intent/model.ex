# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EffectIntent.Model do
  @moduledoc false
  alias Elzoo.EffectIntent.{Binding, Policy}
  alias Elzoo.DurableLog.Codec
  @max 9_223_372_036_854_775_807
  @priority [:settlement, :contradiction, :refused]
  @model_keys ~w(version key identity binding arguments schema deadline policy attempts evidence events anchor pending unavailable)a
  def limits, do: %{max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
  def binary(term), do: :erlang.term_to_binary(term, [:deterministic])
  def hash(bytes), do: :crypto.hash(:sha256, bytes)

  def key(identity),
    do:
      hash(IO.iodata_to_binary([<<1>> | Enum.map(identity, &Codec.field/1)]))
      |> Base.encode16(case: :lower)

  def stream(key), do: "intent/" <> key
  def attempt_id(model, n), do: model.key <> "/attempt/" <> Integer.to_string(n)

  def valid_identity?(identity),
    do: is_list(identity) and length(identity) == 5 and Enum.all?(identity, &Binding.text?/1)

  def fold(binding) do
    %{
      initial: nil,
      kinds: %{"intent" => :state_bearing},
      versions: [1],
      reduce: fn model, "intent", 1, bytes ->
        with {:ok, delta} <- decode_term(bytes, 131_072),
             {:ok, next, _} <- apply_delta(model, delta, binding) do
          next
        else
          _ -> raise ArgumentError, "invalid intent event"
        end
      end,
      limits: limits()
    }
  end

  def encode(model) do
    if valid?(model), do: binary(model), else: raise(ArgumentError, "invalid intent snapshot")
  end

  def decode(bytes, binding) do
    with {:ok, m} <- decode_term(bytes, 1_048_576),
         true <- valid?(m),
         true <- m.binding == binding.digest do
      {:ok, m}
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  def decode_term(bytes, max) when is_binary(bytes) do
    # Our canonical writer emits uncompressed ETF; compressed terms are refused
    # before decoding, so a small checkpoint cannot be a decompression bomb.
    with true <- byte_size(bytes) <= max,
         <<131, tag, _::binary>> <- bytes,
         true <- tag != 80,
         term <- :erlang.binary_to_term(bytes, [:safe]),
         true <- binary(term) == bytes do
      {:ok, term}
    else
      _ -> {:error, :encoding}
    end
  rescue
    _ -> {:error, :encoding}
  end

  def decode_term(_, _), do: {:error, :encoding}

  def admission(identity, args, schema, deadline, now),
    do: {:admit, 1, identity, args, schema, deadline, now}

  def transition(event, attempt, now, options \\ %{}), do: {:step, 1, event, attempt, now, options}

  def apply_delta(nil, {:admit, 1, identity, args, schema, deadline, now}, binding) do
    with true <- valid_identity?(identity),
         [_, account, adapter, operation, _] <- identity,
         true <-
           account == binding.provider_account and adapter == binding.id and
             operation == binding.operation,
         true <- is_binary(args) and byte_size(args) <= 65_536 and Binding.text?(schema),
         {:ok, config} <- Policy.config(binding, deadline, nil, now),
         {:Decision, policy, :Stop} <- Policy.decide(Policy.initial(), :Admit, 0, config) do
      m = %{
        version: 1,
        key: key(identity),
        identity: identity,
        binding: binding.digest,
        arguments: args,
        schema: schema,
        deadline: deadline,
        policy: policy,
        attempts: [],
        evidence: %{},
        events: 1,
        anchor: nil,
        pending: 0,
        unavailable: 0
      }

      finish(m, :Stop)
    else
      _ -> {:error, :admission}
    end
  end

  def apply_delta(m, {:step, 1, event, attempt, now, opts}, binding)
      when is_map(m) and is_map(opts) do
    with true <- m.binding == binding.digest and Policy.event?(event),
         true <- is_integer(attempt) and attempt in 0..length(m.attempts),
         true <- Enum.all?(Map.keys(opts), &(&1 in [:arguments, :schema, :evidence])),
         {:ok, config} <- Policy.config(binding, m.deadline, m.anchor, now),
         :ok <- validate_revision(m, event, opts, config),
         normalized <- Policy.classify(m.policy, event, attempt),
         {:Decision, policy, action} <- Policy.decide(m.policy, event, attempt, config),
         {:ok, next} <-
           decorate(%{m | policy: policy, events: m.events + 1}, m, event, opts, action, now),
         {:ok, next} <- retain(next, opts, normalized, attempt) do
      finish(next, action)
    else
      false -> {:error, :event}
      {:error, _} = e -> e
      _ -> {:error, :event}
    end
  rescue
    _ -> {:error, :event}
  end

  def apply_delta(_, _, _), do: {:error, :event}

  defp validate_revision(m, :Revise, opts, config) do
    if Policy.permitted?(m.policy, :Revise, config) and
         is_binary(opts[:arguments]) and byte_size(opts.arguments) <= 65_536 and
         Binding.text?(opts[:schema]), do: :ok, else: {:error, :revision_refused}
  end

  defp validate_revision(_, _, opts, _) do
    if Map.has_key?(opts, :arguments) or Map.has_key?(opts, :schema),
      do: {:error, :unexpected_revision},
      else: :ok
  end

  defp decorate(next, old, :Revise, opts, _, _) do
    if Policy.revisions(next.policy) == Policy.revisions(old.policy) + 1,
      do: {:ok, %{next | arguments: opts.arguments, schema: opts.schema}},
      else: {:error, :revision_refused}
  end

  defp decorate(next, old, :Arm, _, :Dispatch, now) do
    n = Policy.count(next.policy)
    entry = {n, old.schema, hash(old.arguments), old.binding, now}
    {:ok, %{next | attempts: old.attempts ++ [entry], anchor: old.anchor || now}}
  end

  defp decorate(next, _, event, _, _, _)
       when event in [:Pending, :Lost, :TimedOut, :Failed, :Resume] do
    key = if event == :Pending, do: :pending, else: :unavailable
    {:ok, Map.update!(next, key, &min(&1 + 1, @max))}
  end

  defp decorate(next, _, _, _, _, _), do: {:ok, next}

  defp retain(next, opts, event, attempt) do
    case Map.fetch(opts, :evidence) do
      :error ->
        {:ok, next}

      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 512 ->
        category =
          case event do
            e when e in [:Completed, :NoSend, :PermanentNoSend, :NoEffect] -> :settlement
            :Contradiction -> :contradiction
            :Refused -> :refused
            _ -> :optional
          end

        reserved = attempt > 0 and category in @priority
        slot = if reserved, do: {attempt, category}, else: {:optional, next.events}
        # A second result never replaces the first priority record.
        slot = if Map.has_key?(next.evidence, slot), do: {:optional, next.events}, else: slot
        {:ok, %{next | evidence: Map.put(next.evidence, slot, bytes)}}

      _ ->
        {:error, :evidence_limit}
    end
  end

  def planned?(m),
    do:
      match?({:Intended, _, _}, Policy.phase(m.policy)) and
        Policy.count(m.policy) + Policy.revisions(m.policy) < 256

  def priority_used(m),
    do:
      Enum.count(m.evidence, fn {slot, _} ->
        match?({n, k} when is_integer(n) and n > 0 and k in @priority, slot)
      end)

  def held(m), do: 3 * length(m.attempts) - priority_used(m) + if(planned?(m), do: 3, else: 0)

  def capacity?(m) do
    map_size(m.evidence) + held(m) <= 1024 and
      m.events + held(m) + if(planned?(m), do: 1, else: 0) <= 4096 and
      Policy.count(m.policy) + Policy.revisions(m.policy) <= 256
  end

  defp finish(m, action) do
    cond do
      not capacity?(m) -> {:error, :capacity}
      not valid?(m) -> {:error, :model}
      true -> {:ok, m, action}
    end
  end

  def evidence(event, attempt, now, raw) do
    # Only bounded summary/digest is retained; raw provider values are never
    # copied to checkpoints or status. Positive evidence is authenticated first;
    # refused input is only an untrusted digest and never settlement authority.
    binary({1, event, attempt, now, hash(binary(raw))})
  end

  # Size-only envelope for all outstanding priority commitments and one planned
  # attempt: full 512-byte evidence, maximum scalar encodings, complete witnesses.
  # This is not a fabricated accepted model and is never written to the Store.
  def reserved_checkpoint_size(m) do
    n = length(m.attempts)
    planned = if planned?(m), do: 1, else: 0
    total = n + planned

    evidence =
      if total == 0,
        do: m.evidence,
        else:
          Enum.reduce(1..total, m.evidence, fn i, acc ->
            Enum.reduce(@priority, acc, fn kind, acc ->
              Map.put_new(acc, {i, kind}, :binary.copy(<<0>>, 512))
            end)
          end)

    attempts =
      if planned == 0,
        do: m.attempts,
        else: m.attempts ++ [{total, String.duplicate("s", 256), <<0::256>>, m.binding, @max}]

    policy =
      {:State, {:Intended, {:After, :ProviderReplaySafe}, 256}, false, false, false, false, 256,
       List.duplicate(:EffectCompleted, total)}

    worst = %{
      m
      | policy: policy,
        attempts: attempts,
        evidence: evidence,
        events: 4096,
        schema: String.duplicate("s", 256),
        anchor: @max,
        pending: @max,
        unavailable: @max
    }

    events = m.events + held(m) + planned
    seen = Map.new(1..events, fn i -> {i, <<0::256>>} end)

    c = %Elzoo.Checkpoint{
      stream: stream(m.key),
      sequence: events,
      fold_version: 1,
      model: binary(worst),
      cursor: {events, false, []},
      seen: seen,
      nonce: <<0::128>>
    }

    byte_size(Codec.checkpoint_bytes(c)) + 32
  end

  def valid?(m) when is_map(m) do
    MapSet.new(Map.keys(m)) == MapSet.new(@model_keys) and
      m.version == 1 and valid_identity?(m.identity) and m.key == key(m.identity) and
      is_binary(m.binding) and byte_size(m.binding) == 32 and
      is_binary(m.arguments) and byte_size(m.arguments) <= 65_536 and Binding.text?(m.schema) and
      Binding.uint?(m.deadline) and Policy.valid?(m.policy) and
      is_list(m.attempts) and length(m.attempts) == Policy.count(m.policy) and
      Enum.all?(Enum.with_index(m.attempts, 1), fn
        {{n, s, a, b, t}, i} ->
          n == i and Binding.text?(s) and is_binary(a) and byte_size(a) == 32 and
            b == m.binding and Binding.uint?(t)

        _ ->
          false
      end) and is_map(m.evidence) and map_size(m.evidence) <= 1024 and
      Enum.all?(m.evidence, fn {slot, b} ->
        valid_slot?(slot, m) and is_binary(b) and byte_size(b) <= 512
      end) and
      is_integer(m.events) and m.events in 1..4096 and
      (m.anchor == nil or Binding.uint?(m.anchor)) and
      (m.attempts == [] or elem(hd(m.attempts), 4) == m.anchor) and
      Binding.uint?(m.pending) and Binding.uint?(m.unavailable) and capacity?(m)
  rescue
    _ -> false
  end

  def valid?(_), do: false
  defp valid_slot?({:optional, n}, m), do: is_integer(n) and n in 1..m.events

  defp valid_slot?({n, k}, m),
    do: is_integer(n) and n > 0 and n <= length(m.attempts) and k in @priority

  defp valid_slot?(_, _), do: false
end
