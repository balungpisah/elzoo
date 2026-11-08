# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Effect do
  @moduledoc "Data-only declaration wrapping an unchanged Envelope command; Needs membership is not authority."
  @keys ~w(capability_id operation classification command)
  @core :"Cure.Elzoo.Effect"

  def decode(declaration) when is_map(declaration) do
    with true <- Enum.sort(Map.keys(declaration)) == Enum.sort(@keys),
         true <- text?(declaration["capability_id"]) and text?(declaration["operation"]),
         class when class in ["trusted", "untrusted"] <- declaration["classification"],
         {:ok, command} <- Elzoo.Envelope.decode(declaration["command"]),
         record =
           {:EffectDeclaration, string(declaration["capability_id"]),
            string(declaration["operation"]), string(class), command},
         true <- apply(@core, :valid, [record]) do
      {:ok, record}
    else
      _ -> {:error, :declaration}
    end
  end

  def decode(_), do: {:error, :declaration}

  def validate(declaration) do
    with {:ok, _} <- decode(declaration), do: {:ok, declaration}
  end

  def encode({:EffectDeclaration, {:String, cap}, {:String, op}, {:String, class}, command}),
    do: %{
      "capability_id" => List.to_string(cap),
      "operation" => List.to_string(op),
      "classification" => List.to_string(class),
      "command" => Elzoo.Envelope.encode(command)
    }

  def declared?(declaration, needs) do
    with {:ok, {:EffectDeclaration, cap, _, _, _}} <- decode(declaration),
         true <- is_list(needs) and length(needs) <= 64 and Enum.all?(needs, &text?/1) do
      apply(@core, :declared, [cap, Enum.map(needs, &string/1)])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp string(s), do: {:String, String.to_charlist(s)}

  defp text?(s),
    do:
      is_binary(s) and byte_size(s) in 1..128 and String.valid?(s) and
        not String.contains?(s, <<0>>)
end
