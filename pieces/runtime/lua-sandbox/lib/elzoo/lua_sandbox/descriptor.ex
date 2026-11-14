# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandbox.Descriptor do
  @moduledoc false
  # Policy version 2 as immutable plain data (maps with string keys, integer and
  # string leaves). The identity is the SHA-256 of its canonical JSON.

  alias Elzoo.LuaSandbox.Json

  @globals ~w(assert error ipairs pcall select tonumber tostring type)
  @string ~w(byte char find format gmatch gsub len lower match pack packsize rep reverse sub unpack upper)
  @table ~w(concat insert move pack remove sort unpack)
  @math_functions ~w(abs acos asin atan ceil cos deg exp floor fmod log max min modf rad sin sqrt tan tointeger type ult)
  @math_constants %{
    "math.huge" => "inf",
    "math.maxinteger" => "9223372036854775807",
    "math.mininteger" => "-9223372036854775808",
    "math.pi" => "3.1415926535897931"
  }
  @operators ~w(__add __div __idiv __mod __mul __pow __sub __unm)

  # The helpers that exist in the host: fields of the global `helpers`.
  @helpers ~w(json_encode null object text_split text_trim text_utf8_len)

  @bounds %{
    "steps" => 1_000_000,
    "call_depth" => 64,
    "value_bytes" => 65_536,
    "memory_bytes" => 16_777_216,
    "wall_ms" => 1_000,
    "source_bytes" => 65_536,
    "containers" => 32,
    "frame_bytes" => 1_048_576
  }

  def bounds, do: @bounds

  def globals, do: @globals

  @doc "Fully qualified function names (library members and globals that are functions)."
  def function_names do
    Enum.sort(
      @globals ++
        Enum.map(@string, &("string." <> &1)) ++
        Enum.map(@table, &("table." <> &1)) ++ Enum.map(@math_functions, &("math." <> &1))
    )
  end

  def library_names, do: ["math", "string", "table"]
  def constants, do: @math_constants

  def descriptor do
    %{
      "policy_version" => 2,
      "names" => %{
        "functions" => function_names(),
        "libraries" => library_names(),
        "constants" => @math_constants
      },
      "string_metatable" => %{
        "index" => "strict view of the listed string functions",
        "keys" => Enum.sort(["__index" | @operators])
      },
      "wrappers" => %{
        "pcall" => 1,
        "string.char" => 1,
        "string.format" => 1,
        "string.gsub" => 1,
        "string.pack" => 1,
        "string.rep" => 1,
        "table.concat" => 1,
        "table.insert" => 1,
        "table.move" => 1,
        "table.remove" => 1,
        "table.sort" => 1,
        "table.unpack" => 1,
        "tostring" => 1
      },
      "numeric" => %{
        "float_bits" => 64,
        "float_text" => "%.14g in the C locale",
        "hash_seed" => "fixed at build",
        "integer_bits" => 64,
        "integer_overflow" => "two's complement wrap",
        "locale" => "C",
        "pivot_randomization" => "none",
        "result_float_text" => "shortest round-trip digits"
      },
      "iteration" => %{
        "ipairs" => "upstream, stops at the first nil",
        "next" => "absent",
        "pairs" => "absent",
        "sparse_tables" => "dense-array operations refuse tables whose keys are not exactly 1..n",
        "traversal" => "unordered map traversal is not a capability"
      },
      "data" => %{
        "array" => "dense table with keys 1..n, or a decoded array",
        "empty_array" => "decoded empty array, or an unrecorded empty table",
        "empty_object" => "decoded empty object, or helpers.object()",
        "float" => "finite binary64",
        "integer" => "signed 64-bit",
        "null" => "single light userdata sentinel, compares equal with ==, tostring refuses it",
        "object" => "table with string keys only, encoded with sorted keys",
        "string" => "UTF-8",
        "nil_result" => "a single nil result encodes as null"
      },
      "bounds" => @bounds,
      "framing" => %{
        "body" => "UTF-8 JSON",
        "length" => "unsigned 32-bit little-endian",
        "version" => 1
      },
      "helpers" => Enum.map(Enum.sort(@helpers), &%{"name" => &1, "version" => 1}),
      "bindings" => %{}
    }
  end

  def identity(descriptor) do
    "policy-v2:sha256:" <>
      Base.encode16(:crypto.hash(:sha256, Json.encode(descriptor)), case: :lower)
  end
end
