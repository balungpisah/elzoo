# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeTest.ScriptedAdapter do
  @moduledoc """
  Test Adapter. It sends each call to the test host (`request.context`) and
  waits for the host's reply: `:completed` gives an acknowledgement envelope,
  `:other` gives a timeout.
  """

  def failure_tags, do: [:timeout]
  def schema, do: "recipe-test-v1"
  def validate(_, _), do: :ok
  def authenticate(_, _), do: :ok
  def validate_result(_, _), do: :ok
  def poll(_), do: {:unavailable, "scripted"}

  def send_effect(request) do
    send(request.context, {:recipe_test_call, self(), request})

    receive do
      {:recipe_test_reply, :completed} ->
        %{
          "version" => 1,
          "message_id" => request.key,
          "correlation_id" => request.key,
          "attempt_id" => request.attempt_id,
          "outcome" => "completed",
          "dispatch" => "dispatched",
          "value" => %{},
          "value_schema_id" => "elzoo.recipe-test.ack",
          "value_schema_version" => 1
        }

      {:recipe_test_reply, :other} ->
        {:error, :timeout, :unavailable}
    end
  end
end
