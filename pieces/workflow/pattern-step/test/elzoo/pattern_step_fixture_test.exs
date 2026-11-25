# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PatternStepFixtureTest do
  use ExUnit.Case, async: true
  alias Elzoo.PatternStep

  # Later versions add files; the frozen bytes and their hashes stay unchanged.
  for {version, sha256} <- [
        {1, "7648cb832b81f1f5b5c4fa5eb1e5fb1e241794dbfcd478b69ebf9607c2108698"},
        {2, "24083a91c54c001d17d86349c9b9b56abfa60d2f39e214baff62e2302378ec58"}
      ] do
    test "frozen v#{version} neutral maps round-trip unchanged" do
      version = unquote(version)
      bytes = File.read!(Path.join(__DIR__, "../fixtures/pattern-step/v#{version}.json"))
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == unquote(sha256)

      for map <- JSON.decode!(bytes) do
        assert {:ok, checked} = PatternStep.decode(map, version)
        assert PatternStep.encode(checked) === map
      end
    end
  end
end
