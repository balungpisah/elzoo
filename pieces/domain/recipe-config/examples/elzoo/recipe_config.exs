# SPDX-License-Identifier: Apache-2.0
# Values only: no resolver is called. Host injection code receives the
# checked references and translates them to fixed atom keys.
reference = %{
  "type" => "object",
  "required" => ["ref", "scope"],
  "properties" => %{
    "ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
    "scope" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
  },
  "additionalProperties" => false
}

descriptor = %{
  "version" => 1,
  "id" => "example/greeter",
  "revision" => 1,
  "port" => %{
    "id" => "greeter.settings",
    "direction" => "input",
    "schema_id" => "example/greeter-settings",
    "schema_version" => 1
  },
  "schema" => %{
    "type" => "object",
    "required" => ["greeting", "model_key"],
    "properties" => %{"greeting" => %{"type" => "string"}, "model_key" => reference},
    "additionalProperties" => false
  },
  "secrets" => ["model_key"]
}

host_injection = fn checked_settings, secrets ->
  for name <- secrets, Map.has_key?(checked_settings, name) do
    %{"ref" => ref, "scope" => scope} = checked_settings[name]
    {name, %{ref: ref, scope: scope}}
  end
end

{:ok, checked} = Elzoo.RecipeConfig.build(descriptor)
settings = %{"greeting" => "hello", "model_key" => %{"ref" => "key-1", "scope" => "tenant-a/model"}}
{:ok, checked_settings} = Elzoo.RecipeConfig.check(checked, settings)

%{
  settings: checked_settings,
  requests: host_injection.(checked_settings, descriptor["secrets"]),
  raw_value: Elzoo.RecipeConfig.check(checked, %{settings | "model_key" => "credential-bytes"})
}
