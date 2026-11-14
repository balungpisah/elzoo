# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandboxInputCheckTest do
  @moduledoc """
  The size check of the request, one group for each `describe`: `input_check_is_bounded` (a
  term that shares subterms is refused by a walk whose work is bounded by `value_bytes`, no
  process starts, no wall time is read), `size_answers_are_exact` (the exact bound of the
  canonical encoding, and the answer for a term that is over the size and not plain data),
  and `held_string_limit` (the stated gap of the string guard, with `value_bytes` 4).
  """
  use ExUnit.Case, async: false

  alias Elzoo.LuaSandbox
  alias Elzoo.LuaSandbox.Json

  Code.require_file("lua_sandbox_helper.exs", __DIR__)
  alias Elzoo.LuaSandboxHelper, as: Helper

  @moduletag timeout: 120_000

  # One short string doubled 22 times is a list tree with 2^22 (about four million) leaves
  # that costs a few hundred bytes of memory, because each level holds the level below twice.
  @doublings 22

  # The calling process uses fewer reductions than this for one refused call. Measured on the
  # repaired walk with 22 doublings: 574 (value_bytes 4) and 209,968 (value_bytes 65,536).
  # Measured on the walk without the budget: 12 million with 18 doublings and 199 million
  # with 22 (3.7 GB of memory): the bound is five times the repaired count and far under the
  # unrepaired one.
  @reduction_bound 1_000_000

  setup_all do
    {executable, directory} = Helper.build!("inputcheck")
    marker = Path.join(directory, "fake-ran")
    fake = Helper.fake!(directory, "fake-host", "touch '#{marker}'")
    control_marker = Path.join(directory, "control-ran")
    control = Helper.fake!(directory, "control-host", "touch '#{control_marker}'")

    %{
      executable: executable,
      fake: fake,
      marker: marker,
      control: control,
      control_marker: control_marker
    }
  end

  @valid "return function() return 1 end"

  defp doubled(0, leaf), do: leaf
  defp doubled(count, leaf), do: doubled(count - 1, [leaf, leaf])

  defp reductions, do: elem(Process.info(self(), :reductions), 1)

  # The refusal of the request and the reductions of the calling process that it took.
  defp measured(executable, request) do
    before = reductions()
    result = LuaSandbox.run(executable, request)
    {result, reductions() - before}
  end

  defp record(arguments, result), do: %{name: "a", arguments: arguments, result: result}

  defp replay(records), do: %{mode: "replay", names: ["a"], recorded: records}

  describe "input_check_is_bounded" do
    test "an input that shares subterms is value_size, no process starts, in few reductions",
         %{fake: fake, marker: marker} do
      term = doubled(@doublings, "a")

      for value_bytes <- [4, 65_536] do
        request = Helper.request(@valid, term, %{value_bytes: value_bytes})
        {result, used} = measured(fake, request)

        assert result == {:refused, :value_size}, "value_bytes #{value_bytes}"
        assert used < @reduction_bound, "value_bytes #{value_bytes}: #{used} reductions"
      end

      refute File.exists?(marker)
    end

    test "the same term as a recorded argument and as a recorded result is value_size",
         %{fake: fake, marker: marker} do
      term = doubled(@doublings, "a")

      for value_bytes <- [4, 65_536],
          calls <- [replay([record(term, nil)]), replay([record(nil, term)])] do
        request = Helper.request(@valid, nil, %{value_bytes: value_bytes}, calls)
        {result, used} = measured(fake, request)

        assert result == {:refused, :value_size}, "value_bytes #{value_bytes}"
        assert used < @reduction_bound, "value_bytes #{value_bytes}: #{used} reductions"
      end

      refute File.exists?(marker)
    end

    test "a control: a small well-formed request does start the process", ctx do
      refute File.exists?(ctx.control_marker)
      request = Helper.request(@valid, doubled(2, "a"), %{value_bytes: 65_536})
      assert {:host_outcome, _} = LuaSandbox.run(ctx.control, request)
      assert File.exists?(ctx.control_marker)
    end
  end

  describe "size_answers_are_exact" do
    # {a name, a term, the exact size of its canonical encoding written out by hand}
    @terms [
      {"a string", String.duplicate("x", 10), 12},
      {"a string with an escape", "a\n", 5},
      {"a list of numbers", [1, 2.5, -3], 10},
      {"a map", %{"b" => [true, nil], "a" => 1}, 23},
      {"a nested term", %{"k" => [[1.5, "z"], %{}], "j" => []}, 27}
    ]

    test "the written-out sizes are the sizes of the canonical encoding" do
      for {name, term, size} <- @terms, do: assert(byte_size(Json.encode(term)) == size, name)
    end

    test "an input of exactly value_bytes passes and one byte more is value_size",
         %{executable: exe, fake: fake, marker: marker} do
      for {name, term, size} <- @terms do
        assert {:ok, %{value: value}} = Helper.identity_function(exe, term, %{value_bytes: size}),
               name

        assert Json.encode(value) == Json.encode(term), name

        request = Helper.request(@valid, term, %{value_bytes: size - 1})
        assert LuaSandbox.run(fake, request) == {:refused, :value_size}, name
      end

      refute File.exists?(marker)
    end

    test "a recorded argument and a recorded result of exactly value_bytes pass, one byte more is value_size",
         %{executable: exe, fake: fake, marker: marker} do
      asking = "return function(x) bindings.a(x) return 1 end"

      for {name, term, size} <- @terms, size >= 4 do
        calls = replay([record(term, term)])
        assert {:ok, %{value: 1}} = Helper.run(exe, asking, term, %{value_bytes: size}, calls), name

        for calls <- [replay([record(term, nil)]), replay([record(nil, term)])] do
          request = Helper.request(@valid, nil, %{value_bytes: size - 1}, calls)
          assert LuaSandbox.run(fake, request) == {:refused, :value_size}, name
        end
      end

      refute File.exists?(marker)
    end

    test "a term over the size that is not plain data gives the refusal that the walk meets first",
         %{fake: fake, marker: marker} do
      big = String.duplicate("x", 100)
      not_plain = self()

      # {a name, a term, the refusal for value_bytes 10}
      cases = [
        {"the big string first", [big, not_plain], :value_size},
        {"the term that is not plain first", [not_plain, big], :invalid_request},
        {"big strings under a map, then a function", [%{"k" => big}, &is_list/1], :value_size},
        {"a function, then big strings under a map", [&is_list/1, %{"k" => big}], :invalid_request},
        {"the budget used up by numbers, then a pid", List.duplicate(1, 10) ++ [not_plain],
         :value_size},
        {"a pid, then numbers over the budget", [not_plain | List.duplicate(1, 10)],
         :invalid_request},
        {"an improper tail after the budget is used up", [big | :tail], :value_size},
        {"an improper tail first", [1 | :tail], :invalid_request}
      ]

      for {name, term, refusal} <- cases do
        request = Helper.request(@valid, term, %{value_bytes: 10})
        assert LuaSandbox.run(fake, request) == {:refused, refusal}, name
      end

      # a control: the same shapes that fit are what they were, not plain data is invalid_request
      for term <- [not_plain, [1 | :tail], [[1, not_plain]], %{1 => 2}] do
        request = Helper.request(@valid, term, %{value_bytes: 65_536})
        assert LuaSandbox.run(fake, request) == {:refused, :invalid_request}
      end

      refute File.exists?(marker)
    end
  end

  describe "held_string_limit" do
    @limits %{value_bytes: 4}

    defp name_of(length), do: "n" <> String.duplicate("x", length - 1)

    # one recorded call of `name`, asked by the source, and the source returns the length
    # of a literal equal to `literal`
    defp length_of_literal(exe, name, literal) do
      source =
        "return function() bindings.#{name}(nil) return #'#{literal}' end"

      calls = %{
        mode: "replay",
        names: [name],
        recorded: [%{name: name, arguments: nil, result: nil}]
      }

      Helper.run(exe, source, nil, @limits, calls)
    end

    test "(a) a literal equal to a string that the runtime holds is not measured: value 6",
         %{executable: exe} do
      assert {:ok, %{value: 6}} =
               Helper.run(exe, "return function() return #'string' end", nil, @limits)
    end

    test "(b) a literal equal to a short recorded name (5 to 40 bytes) gives its length",
         %{executable: exe} do
      for length <- [5, 17, 40] do
        name = name_of(length)
        assert {:ok, %{value: ^length}} = length_of_literal(exe, name, name), "#{length} bytes"
      end
    end

    test "(b) a literal equal to a recorded name of 41 to 64 bytes is value_size",
         %{executable: exe} do
      for length <- [41, 64] do
        name = name_of(length)
        assert length_of_literal(exe, name, name) == {:refused, :value_size}, "#{length} bytes"
      end
    end

    test "(c) a literal of the same length that the state does not hold is value_size",
         %{executable: exe} do
      # `strinh` has the 6 bytes of `string`; a recorded name of 5 bytes and a literal of
      # another content are the same case
      assert Helper.run(exe, "return function() return #'strinh' end", nil, @limits) ==
               {:refused, :value_size}

      name = name_of(17)
      other = name_of(16) <> "y"
      assert length_of_literal(exe, name, other) == {:refused, :value_size}
    end

    test "(d) a literal one byte longer than a short string is value_size, also when the state holds the same text",
         %{executable: exe} do
      # The recorded name of 41 bytes is put into the state, as a long string, before the
      # limits are armed; an equal literal of 41 bytes is still allocated and measured.
      # The pinned Lua (LUAI_MAXSHORTLEN is 40; luaS_newlstr interns only up to 40 bytes)
      # makes a fresh string object for each longer literal.
      name = name_of(41)
      assert length_of_literal(exe, name, name) == {:refused, :value_size}

      # not held at all: the same result
      assert Helper.run(exe, "return function() return #'#{name}' end", nil, @limits) ==
               {:refused, :value_size}
    end
  end
end
