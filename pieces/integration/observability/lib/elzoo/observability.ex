# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Observability do
  @moduledoc """
  Opt-in v1 Prometheus counts and total microseconds for the fixed Elzoo events.

  The host starts prometheus, exclusively owns the registry, serializes manual
  lifecycle calls and keeps application-wide global labels absent or empty.
  No process, queue, network, retry, automatic recovery or durable accounting.
  See the Piece README for loss, lifetime, configuration and contention limits.
  """

  @registry :elzoo_observability_v1
  @handler {:elzoo_observability, 1}
  @events for family <- [:job, :effect],
              phase <- [:start, :stop, :exception],
              do: [:elzoo, family, phase]
  @pairs %{
    {"assembly/durable-job", :perform} => :job,
    {"assembly/durable-job", :relay} => :job,
    {"assembly/http-job", :perform} => :job,
    {"assembly/http-job", :send} => :effect,
    {"assembly/http-job", :poll} => :effect
  }
  @count :elzoo_v1_events_total
  @duration :elzoo_v1_duration_microseconds_total
  @probe ["assembly/durable-job", "perform", "stop"]

  @doc "Declare both counters once per provider lifetime; refuse existing state."
  def initialize do
    with :ok <- safe_config() do
      try do
        case :prometheus_registry.collectors(@registry) do
          [] -> initialize_empty()
          _ -> {:error, :conflict}
        end
      catch
        _, _ -> {:error, :unavailable}
      end
    end
  end

  defp initialize_empty do
    # Check even unpopulated definitions before new/1 can register a collector.
    # An arity error also means a foreign definition: never adopt or delete it.
    if definition_present?(@count) or definition_present?(@duration) do
      {:error, :conflict}
    else
      try do
        new(@count, ~c"Accepted Elzoo v1 event observations")
        new(@duration, ~c"Observed Elzoo v1 terminal duration in microseconds")
        :ok
      catch
        _, _ ->
          # Entry was empty under the host's exclusive, serialized ownership.
          # Collector cleanup also removes a partly declared metric family.
          :prometheus_counter.deregister(@registry, @count)
          :prometheus_registry.deregister_collector(@registry, :prometheus_counter)
          {:error, :unavailable}
      end
    end
  end

  defp definition_present?(name) do
    :prometheus_counter.value(@registry, name, @probe)
    true
  catch
    :error, {:unknown_metric, @registry, ^name} -> false
    :error, {:invalid_metric_arity, _, _} -> true
  end

  defp new(name, help) do
    :prometheus_counter.new(
      registry: @registry,
      name: name,
      help: help,
      labels: [:adapter, :operation, :phase]
    )
  end

  @doc "Attach the fixed singleton after checking configuration and definitions."
  def attach do
    with :ok <- safe_config(), :ok <- initialized() do
      try do
        case :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, :v1) do
          :ok -> :ok
          {:error, :already_exists} -> {:error, :already_attached}
        end
      catch
        _, _ -> {:error, :unavailable}
      end
    end
  end

  @doc "Detach only the singleton; counters survive and selected callbacks may finish."
  def detach do
    try do
      case :telemetry.detach(@handler) do
        :ok -> :ok
        {:error, :not_found} -> {:error, :not_attached}
      end
    catch
      _, _ -> {:error, :unavailable}
    end
  end

  @doc "Return the maintained formatter's standard text body for the host's endpoint."
  def scrape do
    with :ok <- safe_config(), :ok <- initialized() do
      try do
        {:ok,
         %{
           content_type: :prometheus_text_format.content_type(),
           body: :prometheus_text_format.format(@registry)
         }}
      catch
        _, _ -> {:error, :unavailable}
      end
    end
  end

  defp safe_config do
    case Application.get_env(:prometheus, :global_labels, []) do
      [] -> :ok
      _ -> {:error, :unsafe_config}
    end
  end

  defp initialized do
    try do
      case :prometheus_registry.collectors(@registry) do
        [:prometheus_counter] ->
          :prometheus_counter.value(@registry, @count, @probe)
          :prometheus_counter.value(@registry, @duration, @probe)
          :ok

        _ ->
          {:error, :unavailable}
      end
    catch
      _, _ -> {:error, :unavailable}
    end
  end

  @doc false
  def handle_event(event, measurements, metadata, :v1) do
    # Catch here, before telemetry's failure path can emit configuration,
    # exception reason or stacktrace. Only constants and finite enum labels
    # reach the provider; ignored fields are never traversed or inspected.
    try do
      with [:elzoo, family, phase] <- event,
           true <- event in @events,
           %{adapter: adapter, operation: operation} <- metadata,
           ^family <- Map.get(@pairs, {adapter, operation}) do
        labels = [adapter, Atom.to_string(operation), Atom.to_string(phase)]
        :prometheus_counter.inc(@registry, @count, labels, 1)

        if phase in [:stop, :exception] do
          case measurements do
            %{duration: duration}
            when is_integer(duration) and duration >= 0 and duration <= 9_223_372_036_854_775_807 ->
              :prometheus_counter.inc(@registry, @duration, labels, duration)

            _ ->
              :ok
          end
        end
      end
    catch
      _, _ -> :ok
    end

    :ok
  end
end
