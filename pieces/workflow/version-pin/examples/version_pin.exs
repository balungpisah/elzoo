# SPDX-License-Identifier: Apache-2.0
alias Elzoo.VersionPin

old = "recipe-package-v1:sha256:" <> String.duplicate("a", 64)
new = "recipe-package-v1:sha256:" <> String.duplicate("b", 64)

# The host builds the source list at Run start from the pinned recipe and the tenant settings.
{:ok, pin} =
  VersionPin.new(old, [
    %{
      "id" => "guide",
      "kind" => "pinned_skill",
      "callable" => "nested",
      "tools" => [
        %{
          "trust" => "untrusted",
          "name" => "search",
          "description" => "Search docs",
          "input_schema" => %{"type" => "object"},
          "annotations" => nil
        }
      ]
    }
  ])

[%{"id" => "guide", "kind" => "pinned_skill", "callable" => "nested"}] = VersionPin.sources(pin)

# The host asks before it takes a listing; no input adds a source.
{:Transition, pin, {:some, known}} = VersionPin.step(pin, {:listing, "guide"})
{:Transition, pin, {:some, closed}} = VersionPin.step(pin, {:add_source, %{"id" => "other"}})

# A published version does not reach a running Run; an explicit change does.
{:Transition, pin, {:some, unchanged}} = VersionPin.step(pin, {:published, new})

^old = VersionPin.version(pin)
{:Transition, pin, {:some, changed}} = VersionPin.step(pin, {:change_version, new})
^new = VersionPin.version(pin)

[known, closed, unchanged, changed]
