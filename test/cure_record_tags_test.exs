defmodule Elzoo.CureRecordTagsTest do
  use ExUnit.Case, async: true

  test "all catalogue Cure record names are unique across Piece source copies" do
    records =
      Path.wildcard("pieces/**/*.cure")
      |> Enum.flat_map(fn path ->
        Regex.scan(~r/^\s*rec\s+(\w+)/m, File.read!(path), capture: :all_but_first)
        |> Enum.map(fn [name] -> {name, path} end)
      end)

    refute records == []

    duplicates =
      Enum.group_by(records, &elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_name, paths} -> length(paths) > 1 end)

    assert duplicates == []
  end
end
