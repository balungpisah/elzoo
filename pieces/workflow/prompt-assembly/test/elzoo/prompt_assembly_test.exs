# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PromptAssemblyTest do
  use ExUnit.Case, async: true
  alias Elzoo.AiText.Request
  alias Elzoo.{PromptAssembly, UntrustedContent}

  @window %{
    provider_id: "provider-a",
    model_id: "model-a",
    size: 1_000_000,
    unit: :tokens,
    estimator_id: "bytes",
    estimator_version: 1
  }

  # A plain function of the byte size: one token per byte, an upper bound.
  defp estimate(bytes) do
    send(self(), {:estimated, bytes})

    {:ok,
     %{
       size: byte_size(bytes),
       unit: :tokens,
       direction: :upper_bound,
       estimator_id: "bytes",
       estimator_version: 1
     }}
  end

  defp marked(content, opts \\ []) do
    %{
      "schema_id" => "elzoo.untrusted-content.marked",
      "schema_version" => 1,
      "sources" => Keyword.get(opts, :sources, ["mcp:files/read_file"]),
      "trust" => Keyword.get(opts, :trust, "untrusted"),
      "max_bytes" => Keyword.get(opts, :max_bytes, 4096),
      "content" => content
    }
  end

  defp input(fields) do
    Map.merge(
      %{
        model: "model-a",
        max_output_tokens: 256,
        role_instructions: ["Role A"],
        skill_instructions: ["Skill B"],
        memory: [],
        history: [],
        tools: [],
        window: @window,
        max_request_bytes: 65_536,
        max_image_refs: 256
      },
      Map.new(fields)
    )
  end

  defp window(size), do: %{@window | size: size}
  defp build(input), do: PromptAssembly.build(input, &estimate/1)

  defp user(id, text \\ nil), do: %{kind: :user, id: id, text: text || "text of #{id}"}
  defp record(id, keep), do: %{kind: :record, id: id, keep: keep, record: %{"note" => id}}
  defp memory(id), do: %{id: id, content: marked("memory #{id} " <> String.duplicate("m", 40))}

  defp assistant(id, calls),
    do: %{
      kind: :assistant,
      id: id,
      text: "text of #{id}",
      tool_calls: Enum.map(calls, &%{"id" => &1, "name" => "lookup", "arguments" => %{"q" => &1}})
    }

  defp result(id, call, media \\ nil),
    do: %{
      kind: :tool_result,
      id: id,
      tool_use_id: call,
      content: marked("result #{id}"),
      ref_media_type: media
    }

  defp content(id, media, opts \\ []),
    do: %{kind: :content, id: id, content: marked("#{id}.png", opts), ref_media_type: media}

  defp tool(name, description \\ "Look a thing up."),
    do: %{"name" => name, "description" => description, "input_schema" => %{"type" => "object"}}

  defp block(neutral) do
    {:ok, marked} = UntrustedContent.decode(neutral)
    {:ok, text} = UntrustedContent.render(marked)
    text
  end

  # Each built request is accepted by the decoder of ai-text with the configured bound.
  defp built!(result, bound \\ 65_536) do
    assert {:ok, %{request: request, canonical: canonical} = built} = result
    assert {:ok, _, ^canonical} = Request.decode(canonical, bound)
    assert Request.canonical(request) == canonical
    built
  end

  defp size_of(input), do: byte_size(built!(build(%{input | window: @window})).canonical)
  defp texts(%{request: request}), do: Enum.map(request["messages"], & &1["text"])

  test "drop_order" do
    history = [
      record("r1", :goal),
      user("u1"),
      assistant("a1", ["c1", "c2"]),
      result("t1", "c1"),
      result("t2", "c2"),
      user("u2"),
      record("r2", :decision),
      user("u3")
    ]

    full = input(memory: [memory("m1"), memory("m2"), memory("m3")], history: history)
    kept = [record("r1", :goal), record("r2", :decision), user("u3")]

    # The unit of the assistant entry with two calls and its two results goes as a whole.
    # The limit is one byte below the request without u1: removing the assistant
    # entry alone would fit, but its results go with it.
    limit = size_of(%{full | history: List.delete_at(history, 1)}) - 1

    first = built!(build(%{full | window: window(limit)}))

    assert first.dropped == [
             %{part: :history, id: "u1"},
             %{part: :history, id: "a1"},
             %{part: :history, id: "t1"},
             %{part: :history, id: "t2"}
           ]

    refute Enum.any?(first.request["messages"], &(&1["role"] in ["assistant", "tool_result"]))

    # Then the memory items go, from the last; the newest unit stays.
    last = size_of(%{full | memory: [memory("m1")], history: kept})
    second = built!(build(%{full | window: window(last)}))

    assert second.dropped == [
             %{part: :history, id: "u1"},
             %{part: :history, id: "a1"},
             %{part: :history, id: "t1"},
             %{part: :history, id: "t2"},
             %{part: :history, id: "u2"},
             %{part: :memory, id: "m3"},
             %{part: :memory, id: "m2"}
           ]

    assert second.estimate.size <= last

    for built <- [first, second] do
      [system | _] = built.request["messages"]
      assert system == %{"role" => "system", "text" => "Role A\n\nSkill B"}
      texts = texts(built)
      assert ~s({"keep":"goal","record":{"note":"r1"}}) in texts
      assert ~s({"keep":"decision","record":{"note":"r2"}}) in texts
      assert List.last(texts) == "text of u3"
    end

    # With nothing left to drop the result is over_limit.
    base = size_of(%{full | memory: [], history: kept})
    assert build(%{full | window: window(base - 1)}) == {:error, :over_limit}
  end

  test "orphan_tool_result" do
    cases = [
      [user("u1"), result("t1", "c1")],
      [result("t1", "c1")],
      [assistant("a1", ["c1"]), result("t1", "c9")],
      [assistant("a1", ["c1"]), user("u1"), result("t1", "c1")],
      [assistant("a1", ["c1"]), result("t1", "c1"), result("t2", "c1")]
    ]

    for history <- cases do
      assert build(input(history: history)) == {:error, :orphan_tool_result}
      refute_received {:estimated, _}
    end

    built!(build(input(history: [assistant("a1", ["c1", "c2"]), result("t1", "c1")])))
  end

  test "hard_bounds" do
    # 257 messages drop by the same order to 256.
    history = for i <- 1..256, do: user("u#{i}")
    built = built!(build(input(skill_instructions: [], history: history)))
    assert built.dropped == [%{part: :history, id: "u1"}]
    assert length(built.request["messages"]) == 256

    tools = for i <- 1..65, do: tool("tool_#{i}")
    assert build(input(tools: tools)) == {:error, :too_many_tools}
    built!(build(input(tools: Enum.take(tools, 64))))

    big = String.duplicate("d", 4097)
    assert build(input(tools: [tool("t", big)])) == {:error, :tool_description_too_large}
    built = built!(build(input(tools: [tool("t", String.duplicate("d", 4096))])))
    assert [%{"description" => <<_::binary-size(4096)>>}] = built.request["tools"]

    # Over the configured byte bound, also below 65,536: the same drop order.
    history = for i <- 1..10, do: user("u#{i}", String.duplicate("x", 300))
    built = built!(build(input(history: history, max_request_bytes: 2000)), 2000)
    assert built.dropped == for(i <- 1..5, do: %{part: :history, id: "u#{i}"})
    assert size_of(input(history: Enum.drop(history, 4))) > 2000

    history = for i <- 1..20, do: user("u#{i}", String.duplicate("x", 4000))
    built = built!(build(input(history: history)))
    assert built.dropped == for(i <- 1..4, do: %{part: :history, id: "u#{i}"})

    assert byte_size(
             Request.canonical(%{
               built.request
               | "messages" => [
                   %{"role" => "user", "text" => String.duplicate("x", 4000)}
                   | built.request["messages"]
                 ]
             })
           ) > 65_536

    history = for i <- 1..3, do: user("u#{i}", String.duplicate("x", 300))
    mem = [%{id: "m1", content: marked(String.duplicate("m", 600))}]
    built = built!(build(input(memory: mem, history: history, max_request_bytes: 1000)), 1000)

    assert built.dropped == [
             %{part: :history, id: "u1"},
             %{part: :history, id: "u2"},
             %{part: :memory, id: "m1"}
           ]

    # Parts that are never dropped and are alone over a bound.
    role = [String.duplicate("r", 1200)]
    assert build(input(role_instructions: role, max_request_bytes: 1000)) == {:error, :over_limit}
    tools = [tool("t", String.duplicate("d", 1200))]
    assert build(input(tools: tools, max_request_bytes: 1000)) == {:error, :over_limit}
    records = for i <- 1..256, do: record("r#{i}", :goal)
    assert build(input(history: records)) == {:error, :over_limit}
  end

  test "deterministic" do
    fixed =
      input(
        memory: [%{id: "m1", content: marked("remembered", sources: ["memory:m1"])}],
        history: [
          user("u1"),
          assistant("a1", ["c1"]),
          result("t1", "c1"),
          %{
            kind: :content,
            id: "d1",
            content: marked("doc", trust: "derived"),
            ref_media_type: nil
          },
          record("r1", :open_action)
        ],
        tools: [tool("lookup")]
      )

    assert {:ok, one} = build(fixed)
    assert {:ok, two} = build(fixed)
    assert one.canonical == two.canonical
    assert one.dropped == [] and one.image_refs_removed == []

    assert one.canonical ==
             ~S({"max_output_tokens":256,"messages":[{"role":"system","text":"Role A\n\nSkill B"},{"role":"user","text":"<<<untrusted-content c8354361fe5663bfb90c77966e012f49 trust=untrusted bytes=10 sources=memory:m1>>>\nremembered\n<<<end untrusted-content c8354361fe5663bfb90c77966e012f49>>>"},{"role":"user","text":"text of u1"},{"role":"assistant","text":"text of a1","tool_calls":[{"arguments":{"q":"c1"},"id":"c1","name":"lookup"}]},{"role":"tool_result","text":"<<<untrusted-content 888b4115f1e1526cff8dccd914e6a9ad trust=untrusted bytes=9 sources=mcp:files/read_file>>>\nresult t1\n<<<end untrusted-content 888b4115f1e1526cff8dccd914e6a9ad>>>","tool_use_id":"c1"},{"role":"user","text":"<<<untrusted-content 139d544b821b13ebea14f1b0fe185772 trust=derived bytes=3 sources=mcp:files/read_file>>>\ndoc\n<<<end untrusted-content 139d544b821b13ebea14f1b0fe185772>>>"},{"role":"user","text":"{\"keep\":\"open_action\",\"record\":{\"note\":\"r1\"}}"}],"model":"model-a","tools":[{"description":"Look a thing up.","input_schema":{"type":"object"},"name":"lookup"}],"version":1})

    # The same input with `image_input: false` gives the same bytes.
    assert {:ok, %{canonical: same}} = build(Map.put(fixed, :image_input, false))
    assert same == one.canonical

    assert one.estimate == %{
             size: byte_size(one.canonical),
             unit: :tokens,
             direction: :upper_bound,
             estimator_id: "bytes",
             estimator_version: 1
           }

    # The estimate sees only canonical bytes, also during drops.
    built!(build(%{fixed | window: window(size_of(fixed) - 1)}))
    calls = Stream.repeatedly(fn -> receive do: ({:estimated, b} -> b), after: (0 -> nil) end)

    for bytes <- Enum.take_while(calls, & &1) do
      assert {:ok, _, ^bytes} = Request.decode(bytes)
    end

    # An approximate value stays approximate; other estimator fields are refused.
    approx = fn bytes -> {:ok, %{elem(estimate(bytes), 1) | direction: :approximate}} end
    assert {:ok, %{estimate: %{direction: :approximate}}} = PromptAssembly.build(fixed, approx)
    other = fn bytes -> {:ok, %{elem(estimate(bytes), 1) | estimator_version: 2}} end
    assert PromptAssembly.build(fixed, other) == {:error, :estimate_unavailable}
    assert PromptAssembly.build(fixed, fn _ -> :error end) == {:error, :estimate_unavailable}
  end

  test "image_refs" do
    sources = [["s:1"], ["s:2", "s:x"], ["s:3"], ["s:4"]]

    refs =
      for {src, i} <- Enum.with_index(sources, 1) do
        content("i#{i}", "image/png",
          sources: src,
          trust: Enum.at(["untrusted", "derived"], rem(i, 2)),
          max_bytes: 6
        )
      end

    history =
      [content("p0", "text/plain") | Enum.take(refs, 2)] ++
        [assistant("a1", ["c1"]), result("t1", "c1", "image/jpeg")] ++ Enum.drop(refs, 2)

    # Five image references in time order: i1, i2, t1, i3, i4; p0 is no image.
    built = built!(build(input(history: history, max_image_refs: 2)))
    assert built.image_refs_removed == ["i1", "i2", "t1"]
    texts = texts(built)

    for %{id: id, content: c} <- history do
      expected =
        if id in built.image_refs_removed,
          do:
            block(%{
              c
              | "content" => "[image reference removed]",
                "max_bytes" => max(c["max_bytes"], 25)
            }),
          else: block(c)

      assert expected in texts
    end

    built = built!(build(input(history: history, max_image_refs: 0)))
    assert built.image_refs_removed == ["i1", "i2", "t1", "i3", "i4"]
    assert block(hd(history).content) in texts(built)

    for key <- [:image, :document, :parts] do
      assert build(input(history: [Map.put(user("u1"), key, "x")])) == {:error, :invalid_input}
      assert build(input(memory: [Map.put(memory("m1"), key, "x")])) == {:error, :invalid_input}
    end

    for built <- [built, built!(build(input(history: history)))],
        message <- built.request["messages"] do
      refute Enum.any?(["image", "document", "parts"], &Map.has_key?(message, &1))
    end
  end

  test "image_parts" do
    pictured = fn id, images -> Map.put(user(id), :images, images) end
    with_images = &input(Keyword.put(&1, :image_input, true))
    parts = fn built -> Enum.filter(built.request["messages"], &Map.has_key?(&1, "parts")) end
    a = %{artifact_id: "photo-a.1", version: 3, media_type: "image/jpeg"}
    b = %{artifact_id: "photo_b", version: 1, media_type: "image/png"}

    # The newest user entry with two images: one text part, then the image parts in order.
    built = built!(build(with_images.(history: [pictured.("u1", [a, b])])))

    assert List.last(built.request["messages"]) == %{
             "role" => "user",
             "parts" => [
               %{"type" => "text", "text" => "text of u1"},
               %{
                 "type" => "image",
                 "artifact" => %{"id" => "photo-a.1", "version" => 3},
                 "media_type" => "image/jpeg"
               },
               %{
                 "type" => "image",
                 "artifact" => %{"id" => "photo_b", "version" => 1},
                 "media_type" => "image/png"
               }
             ]
           }

    assert {:ok, %{messages: decoded}, _} = Request.decode(built.canonical, 65_536)

    assert List.last(decoded).parts == [
             %{type: :text, text: "text of u1"},
             %{type: :image, artifact_id: "photo-a.1", version: 3, media_type: "image/jpeg"},
             %{type: :image, artifact_id: "photo_b", version: 1, media_type: "image/png"}
           ]

    # The estimate is given the request with its image parts as references.
    canonical = built.canonical
    assert_received {:estimated, ^canonical}

    # An older user entry's images are left out, with no reference kept.
    old = %{a | artifact_id: "older-photo"}
    history = [pictured.("u1", [old]), assistant("a1", []), pictured.("u2", [b])]
    built = built!(build(with_images.(history: history)))
    assert Enum.at(built.request["messages"], 1) == %{"role" => "user", "text" => "text of u1"}
    assert [%{"parts" => [_, %{"artifact" => %{"id" => "photo_b"}}]}] = parts.(built)
    refute built.canonical =~ "older-photo"

    # A newest user entry with `images: []` is today's text form; no older images take its place.
    built = built!(build(with_images.(history: [pictured.("u1", [old]), pictured.("u2", [])])))
    assert parts.(built) == []
    assert Enum.take(texts(built), -2) == ["text of u1", "text of u2"]

    # Refusals before any drop: a window of 1 would otherwise end in over_limit.
    ok_history = fn images -> [pictured.("u1", images), user("u2")] end

    assert build(with_images.(history: ok_history.([a]), window: window(1))) ==
             {:error, :over_limit}

    nine = for i <- 1..9, do: %{b | artifact_id: "p#{i}"}

    refused = [
      input(history: ok_history.([a])),
      input(history: ok_history.([a]), image_input: false),
      with_images.(history: ok_history.(nine)),
      with_images.(history: ok_history.([Map.put(a, :size, 10)])),
      with_images.(history: ok_history.([Map.delete(a, :media_type)])),
      input(history: ok_history.([a]), image_input: "true")
    ]

    bad_images =
      for(
        id <- [String.duplicate("x", 65), "a/b", ".", "..", "", :atom],
        do: %{a | artifact_id: id}
      ) ++
        for(v <- [0, 2_147_483_648, 1.0], do: %{a | version: v}) ++
        [%{a | media_type: "image/svg+xml"}]

    Stream.repeatedly(fn -> receive do: ({:estimated, _} -> true), after: (0 -> nil) end)
    |> Enum.take_while(& &1)

    for input <- refused ++ Enum.map(bad_images, &with_images.(history: ok_history.([&1]))) do
      assert build(%{input | window: window(1)}) == {:error, :invalid_input}
      refute_received {:estimated, _}
    end

    # Accepted: eight images, each media type of the set, both edges of the ID and version.
    built = built!(build(with_images.(history: [pictured.("u1", Enum.take(nine, 8))])))
    assert [%{"parts" => [_ | images]}] = parts.(built)
    assert length(images) == 8

    edges =
      [%{a | artifact_id: String.duplicate("x", 64), version: 2_147_483_647}, %{a | version: 1}] ++
        for m <- ~w(image/png image/jpeg image/webp image/gif), do: %{a | media_type: m}

    for image <- edges do
      built = built!(build(with_images.(history: [pictured.("u1", [image])])))
      assert [%{"parts" => [_, %{"media_type" => m}]}] = parts.(built)
      assert m == image.media_type
    end

    # A tool's or a notice's image reference stays a marked block, and
    # `max_image_refs` still bounds those blocks; the eight image parts are not counted.
    eight = Enum.take(nine, 8)

    history = [
      content("i1", "image/png"),
      assistant("a1", ["c1"]),
      result("t1", "c1", "image/jpeg"),
      content("i2", "image/webp"),
      pictured.("u1", eight)
    ]

    removed = fn entry ->
      block(%{entry.content | "content" => "[image reference removed]", "max_bytes" => 4096})
    end

    [i1, _, t1, i2, _] = history

    for {max, gone} <- [{2, [i1]}, {1, [i1, t1]}] do
      built = built!(build(with_images.(history: history, max_image_refs: max)))
      assert built.image_refs_removed == Enum.map(gone, & &1.id)
      messages = built.request["messages"]
      shown = fn entry -> if entry in gone, do: removed.(entry), else: block(entry.content) end

      assert %{"role" => "user", "text" => shown.(i1)} in messages
      assert %{"role" => "user", "text" => shown.(i2)} in messages

      assert %{"role" => "tool_result", "tool_use_id" => "c1", "text" => shown.(t1)} in messages

      assert [%{"parts" => [_ | images]}] = parts.(built)
      assert Enum.map(images, & &1["artifact"]["id"]) == Enum.map(eight, & &1.artifact_id)
    end

    # After a tool turn, a drop that removes the newest user entry takes its images with it.
    history = [pictured.("u1", [a, b]), assistant("a1", ["c1"]), result("t1", "c1")]
    limit = size_of(with_images.(history: tl(history)))
    built = built!(build(with_images.(history: history, window: window(limit))))
    assert built.dropped == [%{part: :history, id: "u1"}]
    assert parts.(built) == []
    refute built.canonical =~ "photo"

    built = built!(build(with_images.(history: history)))
    assert built.dropped == []
    assert [%{"parts" => [%{"text" => "text of u1"}, _, _]}] = parts.(built)
  end

  test "refusals before any drop" do
    assert build(input(memory: [%{id: "m1", content: "plain text"}])) == {:error, :unmarked}

    assert build(
             input(
               history: [
                 user("x"),
                 memory("x") |> Map.merge(%{kind: :content, ref_media_type: nil})
               ]
             )
           ) ==
             {:error, :invalid_input}

    assert build(input(role_instructions: [])) == {:error, :invalid_input}
    assert build(input(window: %{@window | unit: :bytes})) == {:error, :invalid_input}
    assert build(input(max_request_bytes: 65_537)) == {:error, :invalid_input}
    assert build(input(max_image_refs: 257)) == {:error, :invalid_input}
    assert PromptAssembly.build(input([]), fn -> :ok end) == {:error, :invalid_input}
    assert build(input(model: <<0xFF>>)) == {:error, :invalid_input}

    # A struct is not JSON data: in a record, in tool-call arguments, in a tool.
    date = ~U[2026-01-01 00:00:00Z]
    call = %{"id" => "c1", "name" => "lookup", "arguments" => %{"at" => date}}

    for fields <- [
          [history: [%{record("r1", :goal) | record: %{"at" => date}}]],
          [history: [%{record("r1", :goal) | record: date}]],
          [history: [%{assistant("a1", []) | tool_calls: [call]}]],
          [tools: [Map.put(tool("lookup"), "input_schema", %{"at" => date})]]
        ] do
      assert build(input(fields)) == {:error, :invalid_input}
    end

    assert build(input(model: "")) == {:error, {:request, :invalid_request}}
    refute_received {:estimated, _}
  end
end
