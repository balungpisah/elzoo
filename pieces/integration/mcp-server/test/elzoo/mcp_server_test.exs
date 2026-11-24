# SPDX-License-Identifier: Apache-2.0
Code.require_file(Path.expand("../support/mcp_server_test_helper.exs", __DIR__))

defmodule Elzoo.McpServerTest do
  # Each test names its acceptance case. The server is the Piece's Plug in a host
  # router on a loopback socket; the client is the ready integration/mcp-client
  # in :loopback evidence mode, configured directly, or raw Req POSTs where that
  # client refuses locally before sending.
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Elzoo.{McpClient, McpServer, TokenVerify}
  alias Elzoo.McpClient.RuntimeBinding
  alias Elzoo.McpServerTest.{Host, Web}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @now 1_800_000_000
  @issuer "https://issuer.example"
  @audience "elzoo-mcp"
  @release "approval:mcp-test@v1"

  @people %{
    "alice" => %{tenant: "acme", own: ["summarize", "deploy", "echo"]},
    "bob" => %{tenant: "acme", own: ["translate"]},
    "carol" => %{tenant: "globex", own: ["invoice"]}
  }

  @strict %{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"],
    "additionalProperties" => false
  }

  @bots %{
    "acme" => [
      %{
        bot_id: "bot-summarize",
        name: "summarize",
        description: "Summarize a text",
        start_schema: @strict,
        schema_version: 1
      },
      %{
        bot_id: "bot-translate",
        name: "translate",
        description: "Translate a text",
        start_schema: @strict,
        schema_version: 2
      },
      %{
        bot_id: "bot-deploy",
        name: "deploy",
        description: "Deploy (asks a person)",
        start_schema: %{"type" => "object"},
        schema_version: 1
      },
      %{
        bot_id: "bot-echo",
        name: "echo",
        description: "Any object",
        start_schema: %{"type" => "object"},
        schema_version: 1
      }
    ],
    "globex" => [
      %{
        bot_id: "bot-invoice",
        name: "invoice",
        description: "Draft an invoice",
        start_schema: %{"type" => "object"},
        schema_version: 1
      }
    ]
  }

  setup_all do
    %{
      key: JOSE.JWK.generate_key({:okp, :Ed25519}),
      attacker: JOSE.JWK.generate_key({:okp, :Ed25519})
    }
  end

  setup ctx do
    {:ok, agent} = Agent.start_link(fn -> %{runs: 0, modes: %{}, own: nil} end)
    web = Web.start(self())
    on_exit(fn -> Web.stop(web) end)
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :clients)
    intents = start_supervised!({Task.Supervisor, name: nil}, id: :intents)
    ctx = Map.merge(ctx, %{agent: agent, web: web, sup: sup, intents: intents})
    {:ok, server} = McpServer.new(opts(ctx))
    Host.put({:ok, server})
    ctx
  end

  ## host configuration and Needs

  defp opts(ctx, overrides \\ []) do
    parent = self()
    agent = ctx.agent

    {_, public} = JOSE.JWK.to_public_map(ctx.key)

    verifier =
      TokenVerify.jwt_config(
        issuer: @issuer,
        audience: @audience,
        keys: [%{kid: "k1", alg: "EdDSA", jwk: public}],
        leeway_s: 0,
        subject: fn %{subject: id} ->
          send(parent, {:need, :subject, id})

          case @people[id] do
            nil ->
              {:error, :unknown_subject}

            %{tenant: tenant} ->
              {:ok,
               %{
                 principal: %{
                   kind: :human,
                   id: id,
                   tenant: tenant,
                   allowed_scopes: [],
                   allowed_spaces: []
                 },
                 current_epoch: 0
               }}
          end
        end
      )

    Keyword.merge(
      [
        verifier: {:jwt, verifier},
        clock: fn ->
          send(parent, {:need, :clock, nil})
          @now
        end,
        policy: policy(),
        authority: fn principal ->
          send(parent, {:need, :authority, principal.id})
          own = Agent.get(agent, & &1.own) || @people[principal.id].own
          {:ok, Enum.map(own, &%{target: "bot/bot-" <> &1, field: "run", value: true})}
        end,
        bots: fn tenant ->
          send(parent, {:need, :bots, tenant})
          {:ok, Map.get(@bots, tenant, [])}
        end,
        start: fn request ->
          send(parent, {:need, :start, request})

          case Agent.get(agent, &Map.get(&1.modes, {:start, request.bot_id})) do
            nil ->
              n = Agent.get_and_update(agent, &{&1.runs + 1, %{&1 | runs: &1.runs + 1}})
              {:ok, "run-#{n}-" <> request.bot_id}

            fun ->
              fun.(request)
          end
        end,
        result: fn %{run_id: run_id} = request ->
          send(parent, {:need, :result, request})
          [_, _, bot] = String.split(run_id, "-", parts: 3)
          mode = Agent.get(agent, &Map.get(&1.modes, bot, :complete))
          reply(mode, run_id)
        end,
        call_timeout_ms: 2_000,
        poll_interval_ms: 20
      ],
      overrides
    )
  end

  defp reply(:complete, run_id), do: {:ok, completion(run_id, %{"done" => true})}
  defp reply({:payload, payload}, run_id), do: {:ok, completion(run_id, payload)}
  defp reply(:pending, _), do: {:pending, :not_completed}
  defp reply({:terminal, outcome}, _), do: {:terminal, outcome}
  defp reply(:error, _), do: {:error, :history}
  defp reply(:raise, _), do: raise("result store down")
  defp reply(:exit, _), do: exit(:result_store_down)
  defp reply(:throw, _), do: throw(:result_store_down)

  # A completion whose canonical result text {"payload":"z..","run_id":ID} is
  # exactly `total` bytes: 12 + n + 12 + byte_size(ID) + 2.
  defp reply({:sized, total}, run_id),
    do: {:ok, completion(run_id, String.duplicate("z", total - 26 - byte_size(run_id)))}

  defp completion(run_id, payload) do
    %{
      run_id: run_id,
      attempt_id: "a1",
      operation_id: "o1",
      action_id: "finish",
      schema_id: "s",
      schema_version: 1,
      payload: payload,
      evidence_ref: "e1"
    }
  end

  defp mode(ctx, key, mode), do: Agent.update(ctx.agent, &put_in(&1.modes[key], mode))

  # Allow runs of summarize, translate, echo and invoice; ask for deploy.
  defp policy do
    allow = fn bot ->
      %{
        id: "allow-" <> bot,
        effect_class: "mcp.run",
        target: {:exact, "bot/bot-" <> bot},
        verdict: :allow
      }
    end

    %{
      id: "mcp-policy",
      version: 1,
      content_hash: :crypto.hash(:sha256, "mcp-policy-1"),
      effect_classes: ["mcp.run"],
      rules: [
        allow.("summarize"),
        allow.("translate"),
        allow.("echo"),
        allow.("invoice"),
        %{
          id: "ask-deploy",
          effect_class: "mcp.run",
          target: {:exact, "bot/bot-deploy"},
          verdict: :ask,
          requirement: %{name: "deploy-approval", version: 1, scope: :once}
        }
      ]
    }
  end

  ## tokens

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp token(ctx, sub, overrides \\ %{}, key \\ nil) do
    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "sub" => sub,
          "aud" => @audience,
          "exp" => @now + 600,
          "iat" => @now - 60
        },
        overrides
      )

    %JOSE.JWK{kty: {_, <<seed::binary-32, _::binary-32>>}} = key || ctx.key

    input =
      b64(Jason.encode!(%{"alg" => "EdDSA", "kid" => "k1"})) <> "." <> b64(Jason.encode!(claims))

    input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [seed, :ed25519]))
  end

  ## the ready client

  defp client(ctx, token, opts \\ []) do
    {:ok, config} =
      McpClient.configure(
        [
          binding: RuntimeBinding,
          runtime: %{
            server: "elzoo-bots",
            endpoint: ctx.web.url,
            network: :loopback,
            addresses: [{127, 0, 0, 1}]
          },
          tenant: "acme",
          credentials: fn -> {:ok, token} end,
          call_timeout_ms: 20_000
        ] ++ opts
      )

    {:ok, session} = McpClient.connect(config, ctx.sup)
    on_exit(fn -> McpClient.close(session) end)
    session
  end

  defp names(session) do
    {:ok, %{tools: tools}} = McpClient.list_tools(session)
    Enum.map(tools, & &1["name"])
  end

  defp call(ctx, session, tool, args) do
    {:ok, snapshot} = McpClient.list_tools(session)
    ref = "call-" <> Integer.to_string(System.unique_integer([:positive]))

    payload =
      Jason.encode!(%{"version" => 1, "tool" => tool, "arguments" => args, "release" => @release})

    declaration = %{
      "capability_id" => "integration/mcp-client",
      "operation" => "tools/call",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "m-" <> ref,
        "schema_id" => "elzoo/mcp-tool-call",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "caller", "port_id" => "tools"},
        "idempotency_key" => ref,
        "deadline_unix_ms" => 10_000,
        "payload" => payload
      }
    }

    {:ok, admission} = McpClient.admission(session.config, declaration, snapshot)
    {:ok, context} = McpClient.context(session, admission, self())
    McpClient.call_tool(session, admission, owner(ctx, session.config, admission, context))
  end

  # A real EffectIntent owner on the volatile Memory store, as the ready client's
  # tests build it.
  defp owner(ctx, config, admission, adapter_context) do
    memory =
      start_supervised!({Memory, fold: Intent.fold(config.binding), limits: Intent.limits()},
        id: make_ref()
      )

    host =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    {:ok, pid} =
      Intent.start_link(
        binding: config.binding,
        identity: admission.identity,
        arguments: admission.arguments,
        deadline: admission.deadline,
        clock: fn -> 100 end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: adapter_context,
        allow_volatile: true
      )

    pid
  end

  defp text({:completed, %{content: [%{"type" => "text", "text" => text}]} = r}),
    do: {r.is_error, Jason.decode!(text)}

  ## raw HTTP

  defp post(ctx, headers, body, opts \\ []) do
    Req.post!(ctx.web.url,
      headers:
        [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
          headers,
      body: body,
      retry: false,
      decode_body: false,
      receive_timeout: Keyword.get(opts, :receive_timeout, 20_000)
    )
  end

  defp rpc(id, method, params),
    do: Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})

  # initialize, notifications/initialized, then one request; the decoded response.
  defp raw(ctx, token, method, params, opts \\ []) do
    auth = [{"authorization", Keyword.get(opts, :auth, "Bearer ") <> token}]

    session =
      Keyword.get_lazy(opts, :session, fn ->
        init =
          post(
            ctx,
            auth,
            rpc(1, "initialize", %{
              protocolVersion: "2025-11-25",
              capabilities: %{},
              clientInfo: %{name: "raw", version: "1"}
            })
          )

        assert init.status == 200
        [sid] = Req.Response.get_header(init, "mcp-session-id")
        session_headers = [{"mcp-session-id", sid}, {"mcp-protocol-version", "2025-11-25"}]

        resp =
          post(
            ctx,
            auth ++ session_headers,
            Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"})
          )

        assert resp.status == 202
        sid
      end)

    resp =
      post(
        ctx,
        auth ++ [{"mcp-session-id", session}, {"mcp-protocol-version", "2025-11-25"}],
        rpc(System.unique_integer([:positive]), method, params),
        opts
      )

    {resp.status, Jason.decode!(resp.body), session}
  end

  defp drain(acc \\ []) do
    receive do
      {:need, _, _} = m -> drain([m | acc])
      {:wire, _, _, _} = m -> drain([m | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp starts(messages), do: for({:need, :start, r} <- messages, do: r)

  ## acceptance

  test "1: the ready client lists only the bots that the policy allows and calls one; the call returns the Run's payload and Run ID",
       ctx do
    session = client(ctx, token(ctx, "alice"))
    {:ok, %{tools: tools}} = McpClient.list_tools(session)
    assert Enum.map(tools, & &1["name"]) == ["echo", "summarize"]
    summarize = Enum.find(tools, &(&1["name"] == "summarize"))
    assert summarize["description"] == "Summarize a text"
    assert summarize["input_schema"] == @strict

    mode(ctx, "bot-summarize", {:payload, %{"summary" => "short"}})
    drain()
    result = call(ctx, session, "summarize", %{"text" => "a long text"})
    assert {false, %{"payload" => %{"summary" => "short"}, "run_id" => run_id}} = text(result)
    assert run_id =~ ~r/\Arun-\d+-bot-summarize\z/

    [start] = starts(drain())
    assert %{tenant: "acme", bot_id: "bot-summarize", arguments: %{"text" => "a long text"}} = start
    assert start.principal.id == "alice"
    assert start.call_id =~ ~r/\A[0-9a-f]{32}\z/
  end

  test "2: two principals of one tenant with different authority see different lists; an :ask bot is not listed; another tenant sees only its bots",
       ctx do
    assert names(client(ctx, token(ctx, "alice"))) == ["echo", "summarize"]
    assert names(client(ctx, token(ctx, "bob"))) == ["translate"]
    assert names(client(ctx, token(ctx, "carol"))) == ["invoice"]

    # deploy is in alice's authority, and the policy answers :ask for it.
    assert "deploy" in @people["alice"].own
    assert starts(drain()) == []
  end

  test "tools/list: a failed Need or decision gives no bot; a bot whose schema does not build is dropped alone",
       ctx do
    base = opts(ctx)

    cases = [
      authority: fn _ -> raise "authority down" end,
      authority: fn _ -> {:error, :unavailable} end,
      bots: fn _ -> exit(:bots_down) end,
      bots: fn _ ->
        {:ok,
         [
           %{
             bot_id: "b",
             name: "Bad Name",
             description: "d",
             start_schema: %{"type" => "object"},
             schema_version: 1
           }
         ]}
      end,
      bots: fn "acme" ->
        {:ok,
         Enum.map(
           1..65,
           &%{
             bot_id: "b#{&1}",
             name: "b#{&1}",
             description: "d",
             start_schema: %{"type" => "object"},
             schema_version: 1
           }
         )}
      end,
      policy: %{policy() | effect_classes: ["other"], rules: []}
    ]

    for {key, value} <- cases do
      {:ok, server} = McpServer.new(Keyword.put(base, key, value))
      Host.put({:ok, server})
      assert names(client(ctx, token(ctx, "alice"))) == [], "#{key}"
    end

    # A schema that does not build, or whose root type is not "object" (MCP's
    # inputSchema rule), drops that bot alone: summarize goes, echo stays.
    for schema <- [
          %{"type" => "object", "$ref" => "https://schemas.example/x.json"},
          %{},
          %{"type" => ["object"]},
          %{"type" => "string"}
        ] do
      bots = fn "acme" ->
        {:ok, [%{hd(@bots["acme"]) | start_schema: schema} | tl(@bots["acme"])]}
      end

      {:ok, server} = McpServer.new(Keyword.put(base, :bots, bots))
      Host.put({:ok, server})
      assert names(client(ctx, token(ctx, "alice"))) == ["echo"], inspect(schema)
    end
  end

  test "server/discover (modern era) advertises the tools capability", ctx do
    resp =
      post(
        ctx,
        [
          {"authorization", "Bearer " <> token(ctx, "alice")},
          {"mcp-protocol-version", "2026-07-28"},
          {"mcp-method", "server/discover"}
        ],
        rpc(1, "server/discover", %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "io.modelcontextprotocol/clientInfo" => %{"name" => "raw", "version" => "1"}
          }
        })
      )

    assert resp.status == 200, resp.body
    assert %{"result" => %{"capabilities" => %{"tools" => %{}}}} = Jason.decode!(resp.body)
  end

  test "tools/list: each bot-list rule at its edge; a list that breaks one gives no bot", ctx do
    bot = fn fields ->
      Map.merge(
        %{
          bot_id: "b1",
          name: "b1",
          description: "d",
          start_schema: %{"type" => "object"},
          schema_version: 1
        },
        fields
      )
    end

    # One server whose policy and authority allow every listed bot, so only the
    # bot-list rules decide.
    serve = fn bots ->
      own =
        for %{bot_id: id} when is_binary(id) <- bots,
            do: %{target: "bot/" <> id, field: "run", value: true}

      policy = %{
        policy()
        | rules: [%{id: "any", effect_class: "mcp.run", verdict: :allow}]
      }

      {:ok, server} =
        McpServer.new(
          opts(ctx,
            policy: policy,
            authority: fn _ -> {:ok, Enum.uniq(own)} end,
            bots: fn _ -> {:ok, bots} end
          )
        )

      Host.put({:ok, server})
      names(client(ctx, token(ctx, "alice")))
    end

    edge =
      bot.(%{
        bot_id: String.duplicate("i", 128),
        name: String.duplicate("n", 64),
        description: String.duplicate("é", 512),
        schema_version: 2_147_483_647
      })

    # 64 bots, the accepted edge of 0..64 (65 gives no bot, in the test above).
    many = for n <- 1..64, do: bot.(%{bot_id: "m#{n}", name: "m#{n}"})
    assert serve.(many) |> Enum.sort() == Enum.map(1..64, &"m#{&1}") |> Enum.sort()

    assert serve.([edge, bot.(%{bot_id: "b2", name: "a-_9"})]) == [
             "a-_9",
             String.duplicate("n", 64)
           ]

    refused = [
      [bot.(%{}), bot.(%{bot_id: "b2"})],
      [bot.(%{bot_id: ""})],
      [bot.(%{bot_id: String.duplicate("i", 129)})],
      [bot.(%{name: String.duplicate("n", 65)})],
      [bot.(%{name: ""})],
      [bot.(%{description: ""})],
      [bot.(%{description: String.duplicate("d", 1_025)})],
      [bot.(%{description: <<0xFF>>})],
      [bot.(%{schema_version: 0})],
      [bot.(%{schema_version: 2_147_483_648})],
      [bot.(%{start_schema: [1]})],
      [Map.put(bot.(%{}), :extra, 1)],
      [Map.delete(bot.(%{}), :description)],
      [bot.(%{}), :not_a_bot]
    ]

    for {bots, n} <- Enum.with_index(refused) do
      assert serve.([bot.(%{bot_id: "ok", name: "ok"}) | bots]) == [], "case #{n}"
    end
  end

  defp count(mfa) do
    {:call_count, n} = :erlang.trace_info(mfa, :call_count)
    n
  end

  test "3: no token, a malformed header, an expired token and a token of another key are HTTP 401 before MCP handling, with no Need called",
       ctx do
    init = {Elzoo.McpServer.Handler, :init, 1}
    http = {ExMCP.HttpPlug, :call, 2}
    :erlang.trace_pattern(init, true, [:call_count])
    :erlang.trace_pattern(http, true, [:call_count])
    on_exit(fn -> :erlang.trace_pattern({:_, :_, :_}, false, [:call_count]) end)

    valid = token(ctx, "alice")
    body = rpc(1, "tools/list", %{})

    refused = [
      [],
      [{"authorization", "Basic " <> Base.encode64("alice:pw")}],
      [{"authorization", "Bearer"}],
      [{"authorization", "Bearer "}],
      [{"authorization", "Bearer" <> valid}],
      [{"authorization", "Bearer " <> valid <> ", Bearer " <> valid}],
      [{"authorization", "Bearer " <> valid}, {"authorization", "Bearer " <> valid}],
      [{"authorization", "Bearer " <> String.duplicate("a", 8_193)}],
      [{"authorization", "Bearer " <> token(ctx, "alice", %{"exp" => @now})}],
      [{"authorization", "Bearer " <> token(ctx, "alice", %{}, ctx.attacker)}],
      [{"authorization", "Bearer " <> token(ctx, "mallory")}]
    ]

    for {headers, n} <- Enum.with_index(refused) do
      drain()
      resp = post(ctx, headers, body)
      # The handler double's counters first: no ExMCP.HttpPlug call and no
      # handler process for any refused request.
      assert {count(http), count(init)} == {0, 0}, "case #{n}"
      assert resp.status == 401, "case #{n}"
      assert Req.Response.get_header(resp, "www-authenticate") == ["Bearer"]
      assert resp.body == ~s({"error":"unauthorized"})
      needs = for({:need, name, _} <- drain(), do: name)
      # A header refused by its shape calls no Need; a well-formed token reaches
      # the trusted clock and the verifier, and only the unknown subject reaches
      # the subject Need (the expired and foreign tokens are refused before it).
      cond do
        n <= 7 -> assert needs == [], "case #{n}"
        n in 8..9 -> assert needs == [:clock], "case #{n}"
        n == 10 -> assert needs == [:clock, :subject]
      end
    end

    # The token bound: 8,192 bytes passes the header check (a malformed JWT for
    # the verifier), 8,193 does not reach the clock (above).
    drain()

    assert post(ctx, [{"authorization", "Bearer " <> String.duplicate("a", 8_192)}], body).status ==
             401

    assert for({:need, name, _} <- drain(), do: name) == [:clock]

    # A trusted clock that raises or answers a non-integer refuses a valid token.
    base = opts(ctx)

    for clock <- [fn -> raise "clock down" end, fn -> -1 end, fn -> "now" end] do
      {:ok, server} = McpServer.new(Keyword.put(base, :clock, clock))
      Host.put({:ok, server})
      assert post(ctx, [{"authorization", "Bearer " <> valid}], body).status == 401
    end

    {:ok, server} = McpServer.new(base)
    Host.put({:ok, server})
    assert for({:need, name, _} <- drain(), do: name) == []

    assert count(init) == 0
    assert count(http) == 0

    # No token and a body over the default body limit: 401, the body unread.
    assert post(ctx, [], String.duplicate(" ", 2_000_000)).status == 401

    # Controls: a lowercase scheme and several spaces pass the header check, and
    # a valid token reaches the handler.
    for prefix <- ["bearer ", "BEARER   "] do
      {200, %{"result" => %{"tools" => tools}}, _} =
        raw(ctx, String.trim_leading(valid), "tools/list", %{}, auth: prefix)

      assert length(tools) == 2
    end

    assert count(http) > 0
    assert count(init) > 0
  end

  test "3: an API-key verifier: a valid key reaches the handler with its principal; a wrong secret is 401 with no handler",
       ctx do
    digest_key = :binary.copy(<<7>>, 32)
    secret = :binary.copy(<<0xA5>>, 32)
    key = "ek_Key0001abc_" <> Base.url_encode64(secret, padding: false)
    wrong = "ek_Key0001abc_" <> Base.url_encode64(:binary.copy(<<0xA6>>, 32), padding: false)

    config =
      TokenVerify.api_key_config(
        prefix: "ek",
        digest_key: fn ->
          {:ok,
           %Elzoo.Secrets.Credential{
             value: digest_key,
             version: 1,
             expires_at_unix_ms: (@now + 3600) * 1000
           }}
        end,
        lookup: fn "Key0001abc" ->
          {:ok,
           %{
             digest: :crypto.mac(:hmac, :sha256, digest_key, secret),
             principal: %{
               kind: :service,
               id: "bob",
               tenant: "acme",
               auth_epoch: 0,
               allowed_scopes: [],
               allowed_spaces: []
             },
             current_epoch: 0,
             expires_at_unix_s: nil,
             revoked: false
           }}
        end
      )

    {:ok, server} = McpServer.new(opts(ctx, verifier: {:api_key, config}))
    Host.put({:ok, server})

    {200, %{"result" => %{"tools" => tools}}, _} = raw(ctx, key, "tools/list", %{})
    assert Enum.map(tools, & &1["name"]) == ["translate"]

    drain()
    resp = post(ctx, [{"authorization", "Bearer " <> wrong}], rpc(1, "tools/list", %{}))
    assert {resp.status, resp.body} == {401, ~s({"error":"unauthorized"})}
    assert for({:need, name, _} <- drain(), do: name) == [:clock]
  end

  test "Plug: an init triple that does not return {:ok, server}, or raises, is HTTP 503 with a fixed body and no Need",
       ctx do
    for value <- [{:error, :invalid}, :nope, {:ok, %{}}] do
      Host.put(value)

      resp =
        post(ctx, [{"authorization", "Bearer " <> token(ctx, "alice")}], rpc(1, "tools/list", %{}))

      assert {resp.status, resp.body} == {503, ~s({"error":"unavailable"})}
    end

    :persistent_term.erase(Host)

    resp =
      post(ctx, [{"authorization", "Bearer " <> token(ctx, "alice")}], rpc(1, "tools/list", %{}))

    assert {resp.status, resp.body} == {503, ~s({"error":"unavailable"})}
    assert drain() |> Enum.filter(&match?({:need, _, _}, &1)) == []
  end

  defp unknown_tool?({200, %{"error" => %{"code" => -32602, "message" => message}}, _}),
    do: message =~ "unknown tool"

  defp unknown_tool?(_), do: false

  test "4: a raw tools/call of a bot not listed for the principal is unknown tool with no start call",
       ctx do
    alice = token(ctx, "alice")
    bob = token(ctx, "bob")
    args = %{name: "summarize", arguments: %{"text" => "t"}}

    # summarize is listed to alice's session.
    {200, %{"result" => %{"tools" => listed}}, alice_session} = raw(ctx, alice, "tools/list", %{})
    assert "summarize" in Enum.map(listed, & &1["name"])
    drain()

    assert unknown_tool?(raw(ctx, bob, "tools/call", args))
    assert unknown_tool?(raw(ctx, bob, "tools/call", args, session: alice_session))
    assert unknown_tool?(raw(ctx, token(ctx, "carol"), "tools/call", args))
    assert unknown_tool?(raw(ctx, alice, "tools/call", %{name: "invoice", arguments: %{}}))
    assert unknown_tool?(raw(ctx, alice, "tools/call", %{name: "deploy", arguments: %{}}))
    assert unknown_tool?(raw(ctx, alice, "tools/call", %{name: "nope", arguments: %{}}))

    # A list read earlier grants nothing: alice loses the authority, then calls.
    Agent.update(ctx.agent, &%{&1 | own: ["echo"]})
    assert unknown_tool?(raw(ctx, alice, "tools/call", args, session: alice_session))
    assert starts(drain()) == []

    # Control: with the authority back, the same call starts one Run.
    Agent.update(ctx.agent, &%{&1 | own: nil})

    {200, %{"result" => %{"content" => [%{"text" => text}]}}, _} =
      raw(ctx, alice, "tools/call", args, session: alice_session)

    assert %{"payload" => %{"done" => true}} = Jason.decode!(text)
    assert length(starts(drain())) == 1
  end

  defp nest(0), do: 0
  defp nest(k), do: [nest(k - 1)]

  # {"text":"…"} of exactly `bytes` bytes of compact JSON: 9 + n + 2.
  defp sized(bytes), do: %{"text" => String.duplicate("a", bytes - 11)}

  defp tool_text(
         {200, %{"result" => %{"content" => [%{"type" => "text", "text" => text}]} = r}, _}
       ),
       do: {r["isError"] == true, text}

  test "5: an argument that fails its schema, one of 65,537 bytes and one of depth 33 give invalid_arguments with no start call",
       ctx do
    alice = token(ctx, "alice")

    call = fn name, args ->
      tool_text(raw(ctx, alice, "tools/call", %{name: name, arguments: args}))
    end

    assert Jason.encode!(sized(65_537)) |> byte_size() == 65_537

    refused = [
      {"summarize", %{"text" => 1}},
      {"summarize", %{}},
      {"summarize", %{"text" => "t", "extra" => true}},
      {"echo", sized(65_537)},
      {"echo", %{"a" => nest(32)}}
    ]

    for {name, args} <- refused do
      drain()
      assert call.(name, args) == {true, "invalid_arguments"}
      assert starts(drain()) == []
    end

    # Controls at the edges: 65,536 bytes and depth 32 start a Run each.
    for args <- [sized(65_536), %{"a" => nest(31)}] do
      drain()
      assert {false, _} = call.("echo", args)
      assert [%{arguments: ^args}] = starts(drain())
    end
  end

  test "6: a Run pending past call_timeout_ms returns the tool error with its Run ID and goes on; its result read then returns the completion",
       ctx do
    {:ok, server} = McpServer.new(opts(ctx, call_timeout_ms: 300))
    Host.put({:ok, server})
    mode(ctx, "bot-echo", :pending)
    session = client(ctx, token(ctx, "alice"))
    drain()

    started = System.monotonic_time(:millisecond)

    assert {true, %{"run_id" => run_id, "state" => "running"} = error} =
             text(call(ctx, session, "echo", %{}))

    assert map_size(error) == 2
    assert System.monotonic_time(:millisecond) - started >= 300
    reads = for {:need, :result, %{run_id: ^run_id}} <- drain(), do: :read
    assert length(reads) >= 2

    mode(ctx, "bot-echo", :complete)
    request = %{tenant: "acme", principal: nil, run_id: run_id}
    assert {:ok, %{run_id: ^run_id, payload: %{"done" => true}}} = opts(ctx)[:result].(request)
  end

  test "6: new/1 takes call_timeout_ms 1 and 60,000 and refuses 0 and 60,001; the other bounds and keys",
       ctx do
    base = opts(ctx)

    for {key, value} <- [
          call_timeout_ms: 1,
          call_timeout_ms: 60_000,
          poll_interval_ms: 10,
          poll_interval_ms: 5_000,
          body_limit: 1_024,
          body_limit: 1_048_576
        ] do
      assert {:ok, %McpServer{}} = McpServer.new(Keyword.put(base, key, value))
    end

    {:ok, defaults} = McpServer.new(base |> Keyword.delete(:poll_interval_ms))
    assert {defaults.poll_interval_ms, defaults.body_limit} == {250, 131_072}

    refused = [
      call_timeout_ms: 0,
      call_timeout_ms: 60_001,
      call_timeout_ms: 1.0,
      poll_interval_ms: 9,
      poll_interval_ms: 5_001,
      body_limit: 1_023,
      body_limit: 1_048_577,
      verifier: {:jwt, %{}},
      verifier: elem(base[:verifier], 1),
      clock: fn _ -> @now end,
      policy: nil,
      start: fn -> :ok end,
      result: nil,
      authority: fn -> :ok end,
      bots: :bots
    ]

    for {key, value} <- refused do
      assert McpServer.new(Keyword.put(base, key, value)) == {:error, :invalid}, "#{key}"
    end

    assert McpServer.new(Keyword.delete(base, :start)) == {:error, :invalid}
    assert McpServer.new(base ++ [extra: 1]) == {:error, :invalid}
    assert McpServer.new(base ++ [clock: base[:clock]]) == {:error, :invalid}
    assert McpServer.new(%{}) == {:error, :invalid}
    assert inspect(elem(McpServer.new(base), 1)) == "#Elzoo.McpServer<redacted>"
  end

  test "6: the ExMCP.HttpPlug handler timeout is call_timeout_ms plus 5,000, and the bound runs from before the start Need",
       ctx do
    # At call_timeout_ms 2,000 the handler timeout is 7,000 ms. A start Need of
    # 6,000 ms ends past the bound but within the handler timeout: one read,
    # then running. A constant timeout under 6,000, or a bound measured from
    # after the start Need (polling to 8,000), gives -32603 instead.
    {:ok, server} = McpServer.new(opts(ctx, call_timeout_ms: 2_000))
    Host.put({:ok, server})
    mode(ctx, "bot-echo", :pending)
    alice = token(ctx, "alice")

    mode(ctx, {:start, "bot-echo"}, fn _ -> Process.sleep(6_000) && {:ok, "run-9-bot-echo"} end)
    drain()

    assert {true, ~s({"run_id":"run-9-bot-echo","state":"running"})} =
             tool_text(raw(ctx, alice, "tools/call", %{name: "echo", arguments: %{}}))

    assert length(for {:need, :result, _} <- drain(), do: :read) == 1

    # 9,500 ms passes the 7,000 ms handler timeout and ex_mcp's 1,000 ms stop
    # timeout after it, away from the OTP proc_lib:stop/3 boundary named in the
    # README's limits. A handler timeout above 9,500 gives running instead.
    mode(ctx, {:start, "bot-echo"}, fn _ -> Process.sleep(9_500) && {:ok, "run-9-bot-echo"} end)
    {200, %{"error" => error}, _} = raw(ctx, alice, "tools/call", %{name: "echo", arguments: %{}})
    assert %{"code" => -32603, "data" => %{"type" => "handler_timeout"}} = error
  end

  test "7: a terminal Run, a result error and a completion over 65,536 bytes give their tool errors; no result or error holds the token on the wire",
       ctx do
    alice = token(ctx, "alice")
    session = client(ctx, alice)
    drain()

    for outcome <- [:failed, :cancelled, :out_of_budget, :out_of_time] do
      mode(ctx, "bot-echo", {:terminal, outcome})
      assert {true, %{"outcome" => o, "run_id" => _} = e} = text(call(ctx, session, "echo", %{}))
      assert {o, map_size(e)} == {Atom.to_string(outcome), 2}
    end

    for m <- [:error, :raise, :exit, :throw, {:terminal, :paused}] do
      mode(ctx, "bot-echo", m)
      assert {true, %{"run_id" => _, "state" => "unknown"}} = text(call(ctx, session, "echo", %{}))
    end

    mode(ctx, "bot-echo", {:sized, 65_536})

    assert {:completed, %{is_error: false, content: [%{"text" => at_bound}]}} =
             call(ctx, session, "echo", %{})

    assert byte_size(at_bound) == 65_536
    %{"run_id" => run_id} = Jason.decode!(at_bound)

    assert at_bound ==
             ~s({"payload":") <>
               String.duplicate("z", 65_536 - 26 - byte_size(run_id)) <>
               ~s(","run_id":") <> run_id <> ~s("})

    mode(ctx, "bot-echo", {:sized, 65_537})

    assert {true, %{"run_id" => _, "state" => "result_too_large"}} =
             text(call(ctx, session, "echo", %{}))

    for start <- [
          fn _ -> raise "engine down" end,
          fn _ -> throw(:x) end,
          fn _ -> exit(:engine_down) end,
          fn _ -> {:error, :busy} end,
          fn _ -> {:ok, ""} end,
          fn _ -> {:ok, String.duplicate("r", 129)} end,
          fn _ -> :ok end
        ] do
      mode(ctx, {:start, "bot-echo"}, start)

      assert {true, "start_failed"} ==
               (fn {:completed, %{is_error: e, content: [%{"text" => t}]}} -> {e, t} end).(
                 call(ctx, session, "echo", %{})
               )
    end

    wire = for {:wire, status, headers, body} <- drain(), do: {status, inspect(headers) <> body}
    assert length(wire) > 10
    assert Enum.all?(wire, fn {_, bytes} -> not String.contains?(bytes, alice) end)
    # The signature part alone is in no response either.
    [_, _, signature] = String.split(alice, ".")
    assert Enum.all?(wire, fn {_, bytes} -> not String.contains?(bytes, signature) end)
  end

  test "8: a request body over body_limit is HTTP 413; a body at the limit is handled", ctx do
    {:ok, server} = McpServer.new(opts(ctx, body_limit: 1_024))
    Host.put({:ok, server})
    auth = [{"authorization", "Bearer " <> token(ctx, "alice")}]

    body = fn bytes ->
      shell =
        rpc(1, "initialize", %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "", version: "1"}
        })

      rpc(1, "initialize", %{
        protocolVersion: "2025-11-25",
        capabilities: %{},
        clientInfo: %{name: String.duplicate("p", bytes - byte_size(shell)), version: "1"}
      })
    end

    assert byte_size(body.(1_024)) == 1_024
    assert post(ctx, auth, body.(1_024)).status == 200
    assert post(ctx, auth, body.(1_025)).status == 413
  end

  test "9: two calls with equal arguments start two Runs with two call_ids", ctx do
    session = client(ctx, token(ctx, "alice"))
    drain()

    assert {false, %{"run_id" => first}} =
             text(call(ctx, session, "summarize", %{"text" => "same"}))

    assert {false, %{"run_id" => second}} =
             text(call(ctx, session, "summarize", %{"text" => "same"}))

    assert first != second
    [a, b] = starts(drain())
    assert a.arguments == b.arguments
    assert a.call_id != b.call_id
  end

  test "the checked example" do
    {result, _} = Code.eval_file(Path.expand("../../examples/mcp_server.exs", __DIR__))
    assert result == :ok
  end
end
