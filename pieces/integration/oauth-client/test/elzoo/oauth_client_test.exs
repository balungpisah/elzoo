# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/oauth_client_test_helper.exs", __DIR__)

defmodule Elzoo.OauthClientTest do
  # The cases share one database server and hold row locks across connections: not async.
  use ExUnit.Case, async: false
  alias Elzoo.EgressPolicy
  alias Elzoo.Encryption
  alias Elzoo.OauthClient, as: OC
  alias Elzoo.OauthClientTest.{AppRepo, Harness, OwnerRepo, RepeatableRepo, Server, ShortRepo}
  alias Elzoo.Secrets.Credential
  alias Elzoo.TenantIsolation, as: TI

  @moduletag :capture_log
  @secret "client-secret-QpX7"
  @secret_ref %{ref: "vault/oauth-client-ref", scope: "oauth-scope-ref"}
  @key :binary.copy(<<7>>, 32)
  @far 9_000_000_000_000
  @t0 1_000_000_000
  @hour 3_600_000
  @denied :insufficient_privilege
  @errors [
    :invalid,
    :in_transaction,
    :isolation,
    :unknown_provider,
    :unknown_connection,
    :conflict,
    :scope,
    :invalid_state,
    :not_active,
    :reauthorization_required,
    :revoked,
    :egress,
    :secret_unavailable,
    :seal,
    :exchange_refused,
    :exchange_unknown,
    :malformed_response,
    :unavailable
  ]

  setup_all do
    if Enum.any?([OwnerRepo, AppRepo, RepeatableRepo], &Process.whereis/1),
      do: raise("the oauth client test Repos are already running")

    role = Harness.start_repos!()
    on_exit(fn -> Enum.each([OwnerRepo, AppRepo, RepeatableRepo], &Harness.stop!/1) end)
    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(role)
    on_exit(fn -> Harness.drop!(p) end)
    {:ok, clock} = Agent.start_link(fn -> @t0 end)
    ctx = %{p: p, server: Server.start(), clock: clock, me: self(), role: role}
    {:ok, Map.put(ctx, :b, binding!(ctx))}
  end

  # ------------------------------------------------------------ fixtures

  defp provider(id, overrides \\ %{}) do
    Map.merge(
      %{
        provider_id: id,
        authorization_endpoint: "https://auth.example.com/authorize?audience=tools",
        token_endpoint: "https://auth.example.com/token",
        revocation_endpoint: "https://auth.example.com/revoke",
        redirect_uri: "https://app.example.org/oauth/callback",
        client_id: "client-1",
        client_secret_ref: @secret_ref,
        client_auth: :client_secret_basic,
        scopes_allowed: ["read", "write", "tools:call"],
        refresh_rotation: false,
        default_lifetime_s: nil
      },
      overrides
    )
  end

  defp providers do
    [
      provider("acme"),
      provider("post", %{client_auth: :client_secret_post}),
      provider("public", %{client_auth: :none, client_secret_ref: nil}),
      provider("rotating", %{refresh_rotation: true}),
      provider("norevoke", %{revocation_endpoint: nil}),
      provider("lifetime", %{default_lifetime_s: 120}),
      provider("private", %{
        token_endpoint: "https://private.example.com/token",
        revocation_endpoint: "https://private.example.com/revoke"
      }),
      provider("down", %{token_endpoint: "https://down.example.com/token"})
    ]
  end

  defp policy,
    do:
      EgressPolicy.policy(
        hosts: ["auth.example.com", "private.example.com", "down.example.com"],
        ports: [443]
      )

  defp opts(ctx) do
    test = ctx.me
    plug = Server.plug(ctx.server, test)
    clock = ctx.clock

    [
      repo: AppRepo,
      prefix: ctx.p,
      providers: providers(),
      policy: policy(),
      resolver: &resolve/1,
      transport: fn target ->
        send(test, {:transport, target})
        {:ok, [plug: plug]}
      end,
      secrets: fn request -> %{grant: request, resolver: &secret/2} end,
      sealing: %{key_id: "k1", key: fn -> {:ok, key()} end, keys: &keys/2},
      clock: fn -> Agent.get(clock, & &1) end
    ]
  end

  defp binding!(ctx, overrides \\ []) do
    {:ok, b} = OC.new(Keyword.merge(opts(ctx), overrides))
    b
  end

  # The resolver double: a public address for the allowlisted name, a private one, a failure.
  defp resolve("auth.example.com"), do: {:ok, [{93, 184, 216, 34}]}
  defp resolve("private.example.com"), do: {:ok, [{10, 0, 0, 7}]}
  defp resolve(_host), do: {:error, :unavailable}

  defp secret(ref, scope),
    do: {:ok, %{ref: ref, scope: scope, value: @secret, version: 1, expires_at_unix_ms: @far}}

  defp key, do: %Credential{value: @key, version: 1, expires_at_unix_ms: @far}
  defp keys("k1", 1), do: {:ok, key()}
  defp keys(_key_id, _version), do: {:error, :not_found}

  defp set_clock(ctx, t), do: Agent.update(ctx.clock, fn _ -> t end)

  # The test server's tokens are RFC 6750 b64tokens of more than 24 bytes.
  defp tok(prefix), do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp body(overrides \\ []) do
    base = %{
      "access_token" => tok("at-"),
      "token_type" => "Bearer",
      "expires_in" => 3_600,
      "refresh_token" => tok("rt-")
    }

    Enum.reduce(overrides, base, fn
      {k, :drop}, acc -> Map.delete(acc, to_string(k))
      {k, v}, acc -> Map.put(acc, to_string(k), v)
    end)
  end

  # A valid token response of exactly n bytes (JSON allows trailing whitespace).
  defp padded(n) do
    json = Jason.encode!(body())
    json <> String.duplicate(" ", n - byte_size(json))
  end

  defp respond(ctx, reply), do: Server.respond(ctx.server, fn _req, _n -> reply end)

  defp begin!(b, id, opts \\ []) do
    assert {:ok, %{authorization_url: url} = result} =
             OC.begin_authorization(b, Keyword.get(opts, :tenant, "T1"), %{
               connection_id: id,
               provider_id: Keyword.get(opts, :provider, "acme"),
               scopes: Keyword.get(opts, :scopes, ["read", "tools:call"])
             })

    assert Map.keys(result) == [:authorization_url]
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.put("url", url)
  end

  defp complete(b, state, tenant \\ "T1"),
    do: OC.complete_authorization(b, tenant, %{state: state, code: "code-1"})

  # The code exchange of the test server: the verifier must match the URL's S256 challenge and
  # the client must authenticate as its provider declares; anything else is invalid_grant.
  defp code_server(ctx, query, provider_id, reply) do
    p = Enum.find(providers(), &(&1.provider_id == provider_id))

    Server.respond(ctx.server, fn req, _n ->
      f = req.form

      if req.method == "POST" and req.path == "/token" and
           f["grant_type"] == "authorization_code" and f["code"] == "code-1" and
           f["redirect_uri"] == p.redirect_uri and pkce?(f["code_verifier"], query) and
           client?(req, p),
         do: reply,
         else: {400, %{"error" => "invalid_grant"}}
    end)
  end

  defp pkce?(verifier, query) do
    is_binary(verifier) and verifier =~ ~r/\A[A-Za-z0-9_-]{43}\z/ and
      query["code_challenge_method"] == "S256" and
      Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) ==
        query["code_challenge"]
  end

  defp client?(req, %{client_auth: :client_secret_basic}) do
    req.headers["authorization"] == "Basic " <> Base.encode64("client-1:" <> @secret) and
      not Map.has_key?(req.form, "client_secret") and not Map.has_key?(req.form, "client_id")
  end

  defp client?(req, %{client_auth: :client_secret_post}) do
    req.form["client_id"] == "client-1" and req.form["client_secret"] == @secret and
      not Map.has_key?(req.headers, "authorization")
  end

  defp client?(req, %{client_auth: :none}) do
    req.form["client_id"] == "client-1" and not Map.has_key?(req.form, "client_secret") and
      not Map.has_key?(req.headers, "authorization")
  end

  # begin, the consent, complete: the connection is active with the returned tokens.
  defp authorize!(ctx, id, opts \\ []) do
    b = Keyword.get(opts, :b, ctx.b)
    provider = Keyword.get(opts, :provider, "acme")
    tenant = Keyword.get(opts, :tenant, "T1")
    query = begin!(b, id, provider: provider, tenant: tenant)
    tokens = Keyword.get_lazy(opts, :body, fn -> body() end)
    code_server(ctx, query, provider, {200, tokens})
    assert {:ok, %{state: :active} = c} = complete(b, query["state"], tenant)
    %{query: query, body: tokens, connection: c}
  end

  # Every access_token/3 result in this file passes here: {:ok, binary} or {:error, listed atom}.
  defp token(b, id, tenant \\ "T1") do
    result = OC.access_token(b, tenant, %{connection_id: id})

    assert match?({:ok, t} when is_binary(t), result) or
             match?({:error, r} when r in @errors, result)

    result
  end

  defp get(b, id, tenant \\ "T1"), do: OC.get(b, tenant, %{connection_id: id})
  defp revoke(b, id, tenant \\ "T1"), do: OC.revoke(b, tenant, %{connection_id: id})

  defp connect(b, id, provider, scopes \\ ["read", "write"], tenant \\ "T1"),
    do: OC.connect_client(b, tenant, %{connection_id: id, provider_id: provider, scopes: scopes})

  defp since(ctx, n), do: Enum.drop(Server.requests(ctx.server), n)

  defp flush_transport do
    receive do
      {:transport, _} -> flush_transport()
    after
      0 -> :ok
    end
  end

  # ------------------------------------------------------------ 1

  test "1 the code flow with PKCE under each client authentication", ctx do
    for provider <- ["acme", "post", "public"] do
      id = "c-" <> provider
      %{query: q, body: tokens, connection: c} = authorize!(ctx, id, provider: provider)

      assert String.starts_with?(q["url"], "https://auth.example.com/authorize?audience=tools&")
      assert q["response_type"] == "code" and q["client_id"] == "client-1"
      assert q["redirect_uri"] == "https://app.example.org/oauth/callback"
      assert q["scope"] == "read tools:call" and q["code_challenge_method"] == "S256"
      assert byte_size(q["state"]) == 43 and byte_size(q["code_challenge"]) == 43

      assert c == %{
               connection_id: id,
               provider_id: provider,
               grant: :authorization_code,
               scopes: ["read", "tools:call"],
               state: :active,
               expires_at_ms: @t0 + @hour,
               revision: 2
             }

      n = Server.count(ctx.server)
      assert token(ctx.b, id) == {:ok, tokens["access_token"]}
      assert Server.count(ctx.server) == n
    end

    assert Server.count(ctx.server) == 3

    assert Enum.all?(
             Server.requests(ctx.server),
             &(&1.host == "auth.example.com" and
                 &1.headers["content-type"] == "application/x-www-form-urlencoded")
           )

    assert_received {:transport,
                     %{host: "auth.example.com", port: 443, addresses: [{93, 184, 216, 34}]}}
  end

  # ------------------------------------------------------------ 2

  test "2 a state is used once, by its own tenant, before it expires", ctx do
    %{query: q1} = authorize!(ctx, "s1")
    n = Server.count(ctx.server)
    # replayed after success
    assert complete(ctx.b, q1["state"]) == {:error, :invalid_state}

    # replayed after a refused exchange
    q2 = begin!(ctx.b, "s2")
    respond(ctx, {400, %{"error" => "invalid_request"}})
    assert complete(ctx.b, q2["state"]) == {:error, :exchange_refused}
    assert complete(ctx.b, q2["state"]) == {:error, :invalid_state}

    # of another tenant, expired at 600,000 ms, unknown
    q3 = begin!(ctx.b, "s3", tenant: "T2")
    assert complete(ctx.b, q3["state"]) == {:error, :invalid_state}
    q4 = begin!(ctx.b, "s4")
    q5 = begin!(ctx.b, "s5")
    set_clock(ctx, @t0 + 600_000)
    assert complete(ctx.b, q4["state"]) == {:error, :invalid_state}
    unknown = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    assert complete(ctx.b, unknown) == {:error, :invalid_state}
    assert Server.count(ctx.server) == n + 1

    # accepted at 599,999 ms; the T2 state is still unused for T2
    set_clock(ctx, @t0 + 599_999)
    code_server(ctx, q5, "acme", {200, body()})
    assert {:ok, %{state: :active}} = complete(ctx.b, q5["state"])
    code_server(ctx, q3, "acme", {200, body()})
    assert {:ok, %{state: :active}} = complete(ctx.b, q3["state"], "T2")
    assert Server.count(ctx.server) == n + 3
  end

  # ------------------------------------------------------------ 3

  test "3 refused, malformed, redirected and failed exchanges leave the connection as it was",
       ctx do
    malformed = {:error, :malformed_response}
    unknown = {:error, :exchange_unknown}

    cases = [
      {{400, %{"error" => "invalid_request"}}, {:error, :exchange_refused}},
      {{200, body(access_token: String.duplicate("a", 4_096))}, :ok},
      {{200, body(access_token: String.duplicate("a", 4_097))}, malformed},
      {{200, body(access_token: "")}, malformed},
      {{200, body(access_token: :drop)}, malformed},
      {{200, padded(65_536)}, :ok},
      {{200, padded(65_537)}, malformed},
      {{200, body(token_type: "Bearer")}, :ok},
      {{200, body(token_type: "bEaReR")}, :ok},
      {{200, body(token_type: "mac")}, malformed},
      {{200, body(token_type: :drop)}, malformed},
      {{200, body(expires_in: 1)}, :ok},
      {{200, body(expires_in: 31_536_000)}, :ok},
      {{200, body(expires_in: 0)}, malformed},
      {{200, body(expires_in: 31_536_001)}, malformed},
      {{200, body(expires_in: "3600")}, malformed},
      {{200, body(refresh_token: String.duplicate("r", 4_096))}, :ok},
      {{200, body(refresh_token: String.duplicate("r", 4_097))}, malformed},
      {{200, body(refresh_token: "")}, malformed},
      {{200, body(scope: "read")}, :ok},
      {{200, body(scope: 7)}, malformed},
      {{200, "[]"}, malformed},
      {{200, "not json"}, malformed},
      {{302, %{}, [{"location", "https://auth.example.com/elsewhere"}]}, unknown},
      {{503, %{"error" => "temporarily_unavailable"}}, unknown},
      {{:transport_error, :closed}, unknown}
    ]

    for {{reply, expected}, i} <- Enum.with_index(cases) do
      id = "x#{i}"
      q = begin!(ctx.b, id)
      respond(ctx, reply)

      case expected do
        :ok ->
          assert {:ok, %{state: :active, revision: 2}} = complete(ctx.b, q["state"]), "#{i}"

        error ->
          assert complete(ctx.b, q["state"]) == error, "#{i}"
          assert {:ok, %{state: :pending, revision: 1, expires_at_ms: nil}} = get(ctx.b, id)
      end
    end

    # One request per case; the redirect was not followed.
    assert Server.count(ctx.server) == length(cases)
    assert Enum.all?(Server.requests(ctx.server), &(&1.path == "/token"))
  end

  test "3 an exchange stopped at exchange_timeout_ms is unknown", ctx do
    b = binding!(ctx, exchange_timeout_ms: 300)
    q = begin!(b, "slow")
    respond(ctx, :never)
    {us, result} = :timer.tc(fn -> complete(b, q["state"]) end)
    assert result == {:error, :exchange_unknown}
    assert us >= 300_000 and us < 3_000_000
    assert_received {:holding, _}
    assert {:ok, %{state: :pending, revision: 1}} = get(b, "slow")
    assert complete(b, q["state"]) == {:error, :invalid_state}
  end

  # ------------------------------------------------------------ 4

  test "4 freshness at the skew edge and at half a short lifetime", ctx do
    %{body: first} = authorize!(ctx, "k")
    expires = @t0 + @hour
    second = body(expires_in: 40, refresh_token: :drop)
    respond(ctx, {200, second})
    n = Server.count(ctx.server)

    # valid until now + skew_ms: no exchange; until now + skew_ms - 1: refreshed
    set_clock(ctx, expires - 60_000)
    assert token(ctx.b, "k") == {:ok, first["access_token"]}
    assert Server.count(ctx.server) == n
    t1 = expires - 59_999
    set_clock(ctx, t1)
    assert token(ctx.b, "k") == {:ok, second["access_token"]}

    assert [%{path: "/token", form: form}] = since(ctx, n)
    assert form == %{"grant_type" => "refresh_token", "refresh_token" => first["refresh_token"]}
    assert {:ok, %{expires_at_ms: e, revision: 3}} = get(ctx.b, "k")
    assert e == t1 + 40_000

    # expires_in 40 below skew_ms 60,000: fresh with 20,000 ms left, refreshed with 19,999
    third = body()
    respond(ctx, {200, third})
    set_clock(ctx, t1 + 20_000)
    assert token(ctx.b, "k") == {:ok, second["access_token"]}
    assert Server.count(ctx.server) == n + 1
    set_clock(ctx, t1 + 20_001)
    assert token(ctx.b, "k") == {:ok, third["access_token"]}

    # the refresh without refresh_token kept the old one
    assert [_, %{form: %{"refresh_token" => kept}}] = since(ctx, n)
    assert kept == first["refresh_token"]
  end

  test "4 without expires_in: default_lifetime_s, or with it nil an exchange at each call", ctx do
    assert connect(ctx.b, "life", "lifetime") == {:ok, :applied}
    one = body(expires_in: :drop)
    respond(ctx, {200, one})
    assert token(ctx.b, "life") == {:ok, one["access_token"]}
    assert {:ok, %{expires_at_ms: e}} = get(ctx.b, "life")
    assert e == @t0 + 120_000
    set_clock(ctx, @t0 + 60_000)
    assert token(ctx.b, "life") == {:ok, one["access_token"]}
    assert Server.count(ctx.server) == 1

    assert connect(ctx.b, "none", "acme") == {:ok, :applied}
    respond(ctx, {200, two = body(expires_in: :drop)})
    assert token(ctx.b, "none") == {:ok, two["access_token"]}
    assert {:ok, %{expires_at_ms: e}} = get(ctx.b, "none")
    assert e == @t0 + 60_000
    respond(ctx, {200, three = body(expires_in: :drop)})
    assert token(ctx.b, "none") == {:ok, three["access_token"]}
    assert Server.count(ctx.server) == 3
  end

  # ------------------------------------------------------------ 5

  @tag :refresh_deadline
  test "5 two concurrent callers make one refresh, also below skew_ms", ctx do
    deadline =
      binding!(ctx,
        refresh_deadline: %{lock_wait_ms: 5_000, overhead_ms: 500, persistence_reserve_ms: 400}
      )

    for {id, reply, b} <- [
          {"one", body(), ctx.b},
          {"short", body(expires_in: 40), ctx.b},
          {"deadline", body(), deadline}
        ] do
      set_clock(ctx, @t0)
      authorize!(ctx, id)
      set_clock(ctx, @t0 + @hour)
      n = Server.count(ctx.server)
      # The plug holds the first refresh only; any later request is answered at once.
      Server.respond(ctx.server, fn _req, k ->
        if k == n + 1, do: {:hold, {200, reply}}, else: {200, reply}
      end)

      callers = for _ <- 1..2, do: Task.async(fn -> token(b, id) end)
      assert_receive {:holding, holder}, 5_000
      # The second caller is seen waiting on the connection row lock, or (without the lock)
      # reaches the server itself.
      barrier!(ctx, n)
      send(holder, :go)
      token = reply["access_token"]
      assert Task.await_many(callers, 10_000) == [{:ok, token}, {:ok, token}]
      assert Server.count(ctx.server) == n + 1
    end
  end

  @tag :refresh_deadline
  test "slow rotation under short and suitable Repo timeouts", ctx do
    start_supervised!(
      {ShortRepo,
       url: Harness.url!(),
       log: false,
       pool_size: 2,
       timeout: 200,
       after_connect: {Harness, :connect, [ctx.role, nil]}}
    )

    declaration = %{lock_wait_ms: 500, overhead_ms: 1_000, persistence_reserve_ms: 300}

    for {id, repo, opts} <- [
          {"explicit", ShortRepo, [refresh_deadline: declaration]},
          {"too-short", ShortRepo, []},
          {"suitable", AppRepo, []}
        ] do
      b = binding!(ctx, [repo: repo, exchange_timeout_ms: 2_000] ++ opts)
      set_clock(ctx, @t0)
      old = authorize!(ctx, id, provider: "rotating")
      set_clock(ctx, @t0 + @hour)
      n = Server.count(ctx.server)
      rotated = body()

      Server.respond(ctx.server, fn req, k ->
        if req.form["refresh_token"] == old.body["refresh_token"] and k == n + 1 do
          {:hold, {200, rotated}}
        else
          {400, %{"error" => "invalid_grant"}}
        end
      end)

      caller = Task.async(fn -> token(b, id) end)
      assert_receive {:holding, holder}, 2_000
      Process.sleep(500)
      send(holder, :go)
      result = Task.await(caller)
      assert Server.count(ctx.server) == n + 1

      if id == "too-short" do
        assert result == {:error, :unavailable}
        assert get(ctx.b, id) == {:ok, old.connection}
        assert token(ctx.b, id) == {:error, :reauthorization_required}
        assert [%{form: %{"refresh_token" => spent}}] = since(ctx, n + 1)
        assert spent == old.body["refresh_token"]
      else
        assert result == {:ok, rotated["access_token"]}
        assert {:ok, %{revision: rev}} = get(ctx.b, id)
        assert rev == old.connection.revision + 1
        assert token(ctx.b, id) == result
        assert Server.count(ctx.server) == n + 1
        set_clock(ctx, @t0 + 2 * @hour)
        next = body()
        respond(ctx, {200, next})
        assert token(ctx.b, id) == {:ok, next["access_token"]}
        assert [%{form: %{"refresh_token" => saved}}] = since(ctx, n + 1)
        assert saved == rotated["refresh_token"]
      end
    end
  end

  @tag :refresh_deadline
  test "lock wait and transport preparation spend the same pre-dispatch budget", ctx do
    for {id, reserve} <- [{"not-enough", 1_600}, {"enough", 600}] do
      set_clock(ctx, @t0)
      old = authorize!(ctx, id, provider: "rotating")
      set_clock(ctx, @t0 + @hour)
      before = Harness.truth(ctx.p)
      n = Server.count(ctx.server)
      rotated = body()
      respond(ctx, {200, rotated})
      transport = ctx.b.transport

      b =
        binding!(ctx,
          exchange_timeout_ms: 1_000,
          refresh_deadline: %{
            lock_wait_ms: 400,
            overhead_ms: 1_800,
            persistence_reserve_ms: reserve
          },
          transport: fn target ->
            send(ctx.me, {:preparing, self()})
            receive do: (:prepared -> transport.(target))
          end
        )

      # Observe the caller waiting on the row before starting the lock delay.
      {:ok, caller} =
        TI.transact(AppRepo, %{tenant: "T1"}, fn ->
          Harness.q!(
            AppRepo,
            "SELECT 1 FROM #{Harness.table(ctx.p, :connections)} WHERE connection_id = $1 FOR UPDATE",
            [id]
          )

          task = Task.async(fn -> token(b, id) end)
          Harness.await_waiting!(1)
          Process.sleep(400)
          {:ok, task}
        end)

      assert_receive {:preparing, worker}, 1_000
      Process.sleep(400)
      send(worker, :prepared)
      result = Task.await(caller)

      if id == "not-enough" do
        # 800 ms exceeds the 600 ms dispatch window, but the exchange alone fits.
        assert since(ctx, n) == []
        assert result == {:error, :unavailable}
        assert Harness.truth(ctx.p) == before
        set_clock(ctx, @t0)
        assert token(ctx.b, id) == {:ok, old.body["access_token"]}
      else
        assert result == {:ok, rotated["access_token"]}
        assert length(since(ctx, n)) == 1
      end
    end
  end

  @tag :refresh_deadline
  test "a stopped exchange task only spends a rotating token after admission", ctx do
    id = "starved"
    old = authorize!(ctx, id, provider: "rotating")
    set_clock(ctx, @t0 + @hour)
    n = Server.count(ctx.server)

    opts = [
      exchange_timeout_ms: 120,
      refresh_deadline: %{lock_wait_ms: 150, overhead_ms: 1_000, persistence_reserve_ms: 1_000}
    ]

    # One normal scheduler: the high-priority caller can finish preparing and time out,
    # but the normal-priority exchange task cannot run until the spinner yields.
    starve = fn target ->
      reply = ctx.b.transport.(target)
      Process.flag(:priority, :high)

      :erlang.spawn_opt(fn -> spin_until(System.monotonic_time(:millisecond) + 350) end, [
        :link,
        priority: :high
      ])

      reply
    end

    b = binding!(ctx, [transport: starve] ++ opts)

    caller =
      Task.async(fn ->
        :erlang.system_flag(:multi_scheduling, :block_normal)

        try do
          token(b, id)
        after
          :erlang.system_flag(:multi_scheduling, :unblock_normal)
        end
      end)

    assert Task.await(caller) == {:error, :unavailable}
    assert since(ctx, n) == []
    assert get(ctx.b, id) == {:ok, old.connection}

    respond(ctx, :never)
    assert token(binding!(ctx, opts), id) == {:error, :reauthorization_required}
    assert length(since(ctx, n)) == 1
    assert {:ok, %{state: :reauthorization_required, revision: rev}} = get(ctx.b, id)
    assert rev == old.connection.revision + 1
  end

  defp spin_until(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: spin_until(deadline)
  end

  test "opt-in client credentials refuse a checkout, dispatch once, then read fresh", ctx do
    b =
      binding!(ctx,
        refresh_deadline: %{lock_wait_ms: 1_000, overhead_ms: 200, persistence_reserve_ms: 200}
      )

    assert {:ok, :applied} = AppRepo.checkout(fn -> connect(b, "cc", "acme") end)
    assert {:error, :unavailable} = AppRepo.checkout(fn -> token(b, "cc") end)
    assert {:ok, {:error, :in_transaction}} = AppRepo.transaction(fn -> token(b, "cc") end)
    assert Server.count(ctx.server) == 0
    reply = body()
    respond(ctx, {200, reply})
    assert token(b, "cc") == {:ok, reply["access_token"]}
    assert token(b, "cc") == {:ok, reply["access_token"]}
    assert [%{form: %{"grant_type" => "client_credentials"}}] = Server.requests(ctx.server)
  end

  defp barrier!(ctx, n, tries \\ 500) do
    cond do
      Harness.waiting() == 1 or Server.count(ctx.server) > n + 1 ->
        :ok

      tries == 0 ->
        flunk("the second caller neither waited nor reached the server")

      true ->
        Process.sleep(10)
        barrier!(ctx, n, tries - 1)
    end
  end

  # ------------------------------------------------------------ 6

  test "6 a refresh refused invalid_grant requires reauthorization", ctx do
    authorize!(ctx, "g")
    set_clock(ctx, @t0 + @hour)
    respond(ctx, {400, %{"error" => "invalid_grant"}})
    assert token(ctx.b, "g") == {:error, :reauthorization_required}
    assert {:ok, %{state: :reauthorization_required, expires_at_ms: nil}} = get(ctx.b, "g")
    n = Server.count(ctx.server)
    assert token(ctx.b, "g") == {:error, :reauthorization_required}
    assert Server.count(ctx.server) == n

    # a new consent takes the same connection
    %{body: again} = authorize!(ctx, "g")
    assert token(ctx.b, "g") == {:ok, again["access_token"]}
  end

  test "6 a timed-out refresh: rotation spends the refresh token, no rotation keeps it", ctx do
    b = binding!(ctx, exchange_timeout_ms: 250)
    %{body: rot} = authorize!(ctx, "rot", provider: "rotating", b: b)
    %{body: keep} = authorize!(ctx, "keep", b: b)
    set_clock(ctx, @t0 + @hour)
    respond(ctx, :never)

    assert token(b, "rot") == {:error, :reauthorization_required}
    n = Server.count(ctx.server)
    assert token(b, "rot") == {:error, :reauthorization_required}
    assert Server.count(ctx.server) == n

    assert Enum.count(
             Server.requests(ctx.server),
             &(&1.form["refresh_token"] == rot["refresh_token"])
           ) ==
             1

    assert token(b, "keep") == {:error, :exchange_unknown}
    assert {:ok, %{state: :active, revision: 2}} = get(b, "keep")
    fresh = body()
    respond(ctx, {200, fresh})
    assert token(b, "keep") == {:ok, fresh["access_token"]}

    assert Enum.count(
             Server.requests(ctx.server),
             &(&1.form["refresh_token"] == keep["refresh_token"])
           ) ==
             2
  end

  test "6 the other outcomes: pending, no refresh token, another refusal, a malformed refresh",
       ctx do
    begin!(ctx.b, "pend")
    assert token(ctx.b, "pend") == {:error, :not_active}

    # an authorization code connection without a stored refresh token
    authorize!(ctx, "nort", body: body(refresh_token: :drop))
    set_clock(ctx, @t0 + @hour)
    n = Server.count(ctx.server)
    assert token(ctx.b, "nort") == {:error, :reauthorization_required}
    assert {:ok, %{state: :reauthorization_required}} = get(ctx.b, "nort")
    assert Server.count(ctx.server) == n

    set_clock(ctx, @t0)
    %{body: keep} = authorize!(ctx, "keep")
    %{body: rot} = authorize!(ctx, "rot", provider: "rotating")
    set_clock(ctx, @t0 + @hour)
    {:ok, before} = get(ctx.b, "keep")

    # a refusal other than invalid_grant changes nothing
    respond(ctx, {401, %{"error" => "invalid_client"}})
    assert token(ctx.b, "keep") == {:error, :exchange_refused}
    assert get(ctx.b, "keep") == {:ok, before}

    # a malformed refresh: nothing changes without rotation, the token is spent with it
    respond(ctx, {200, body(token_type: "mac")})
    assert token(ctx.b, "keep") == {:error, :malformed_response}
    assert get(ctx.b, "keep") == {:ok, before}
    assert token(ctx.b, "rot") == {:error, :reauthorization_required}
    m = Server.count(ctx.server)
    assert token(ctx.b, "rot") == {:error, :reauthorization_required}
    assert Server.count(ctx.server) == m

    fresh = body()
    respond(ctx, {200, fresh})
    assert token(ctx.b, "keep") == {:ok, fresh["access_token"]}
    sent = Enum.map(Server.requests(ctx.server), & &1.form["refresh_token"])
    assert Enum.count(sent, &(&1 == keep["refresh_token"])) == 3
    assert Enum.count(sent, &(&1 == rot["refresh_token"])) == 1
  end

  # ------------------------------------------------------------ 7

  test "7 client credentials: a token on first use, a new one after expiry, unknown changes nothing",
       ctx do
    assert connect(ctx.b, "svc", "post") == {:ok, :applied}
    assert connect(ctx.b, "svc", "post") == {:ok, :duplicate}
    assert connect(ctx.b, "svc", "post", ["write", "read"]) == {:error, :conflict}
    assert connect(ctx.b, "svc", "acme") == {:error, :conflict}

    assert OC.begin_authorization(ctx.b, "T1", %{
             connection_id: "svc",
             provider_id: "post",
             scopes: ["read"]
           }) == {:error, :conflict}

    assert get(ctx.b, "svc") ==
             {:ok,
              %{
                connection_id: "svc",
                provider_id: "post",
                grant: :client_credentials,
                scopes: ["read", "write"],
                state: :active,
                expires_at_ms: nil,
                revision: 1
              }}

    one = body(refresh_token: :drop)
    respond(ctx, {200, one})
    assert token(ctx.b, "svc") == {:ok, one["access_token"]}
    assert token(ctx.b, "svc") == {:ok, one["access_token"]}

    assert [%{path: "/token", form: form}] = Server.requests(ctx.server)

    assert form == %{
             "grant_type" => "client_credentials",
             "scope" => "read write",
             "client_id" => "client-1",
             "client_secret" => @secret
           }

    set_clock(ctx, @t0 + @hour)
    two = body(refresh_token: :drop)
    respond(ctx, {200, two})
    assert token(ctx.b, "svc") == {:ok, two["access_token"]}
    assert Server.count(ctx.server) == 2

    set_clock(ctx, @t0 + 2 * @hour)
    {:ok, before} = get(ctx.b, "svc")
    respond(ctx, {500, %{}})
    assert token(ctx.b, "svc") == {:error, :exchange_unknown}
    assert get(ctx.b, "svc") == {:ok, before}
    respond(ctx, {400, %{"error" => "invalid_client"}})
    assert token(ctx.b, "svc") == {:error, :exchange_refused}
    assert get(ctx.b, "svc") == {:ok, before}
    respond(ctx, {200, three = body()})
    assert token(ctx.b, "svc") == {:ok, three["access_token"]}
    assert Server.count(ctx.server) == 5

    # a revoked client credentials connection is not taken again
    respond(ctx, {200, ""})
    assert revoke(ctx.b, "svc") == {:ok, :applied}
    assert connect(ctx.b, "svc", "post") == {:error, :revoked}
    assert connect(ctx.b, "svc", "acme") == {:error, :conflict}
  end

  # ------------------------------------------------------------ 8

  test "8 revocation with an endpoint, without one, refused and repeated", ctx do
    %{body: tokens} = authorize!(ctx, "r1")
    respond(ctx, {200, ""})
    n = Server.count(ctx.server)
    assert revoke(ctx.b, "r1") == {:ok, :applied}
    assert [call] = since(ctx, n)
    assert call.path == "/revoke"
    assert call.form == %{"token" => tokens["refresh_token"], "token_type_hint" => "refresh_token"}
    assert call.headers["authorization"] == "Basic " <> Base.encode64("client-1:" <> @secret)
    assert {:ok, %{state: :revoked, expires_at_ms: nil, revision: 3}} = get(ctx.b, "r1")
    assert revoke(ctx.b, "r1") == {:ok, :duplicate}
    assert Server.count(ctx.server) == n + 1
    assert token(ctx.b, "r1") == {:error, :revoked}

    assert OC.begin_authorization(ctx.b, "T1", %{
             connection_id: "r1",
             provider_id: "acme",
             scopes: ["read"]
           }) == {:error, :revoked}

    # without an endpoint: no call
    authorize!(ctx, "r2", provider: "norevoke")
    m = Server.count(ctx.server)
    assert revoke(ctx.b, "r2") == {:ok, :applied}
    assert Server.count(ctx.server) == m
    assert token(ctx.b, "r2") == {:error, :revoked}

    # a refused call: still revoked
    authorize!(ctx, "r3")
    respond(ctx, {400, %{"error" => "unsupported_token_type"}})
    assert revoke(ctx.b, "r3") == {:ok, :applied}
    assert Server.count(ctx.server) == m + 2
    assert {:ok, %{state: :revoked}} = get(ctx.b, "r3")
    assert token(ctx.b, "r3") == {:error, :revoked}

    # only an access token: it is the one revoked; a pending connection has none to send
    assert connect(ctx.b, "r4", "acme") == {:ok, :applied}
    respond(ctx, {200, cc = body(refresh_token: :drop)})
    assert {:ok, _} = token(ctx.b, "r4")
    respond(ctx, {200, ""})
    assert revoke(ctx.b, "r4") == {:ok, :applied}

    assert List.last(Server.requests(ctx.server)).form == %{
             "token" => cc["access_token"],
             "token_type_hint" => "access_token"
           }

    begin!(ctx.b, "r5")
    k = Server.count(ctx.server)
    assert revoke(ctx.b, "r5") == {:ok, :applied}
    assert Server.count(ctx.server) == k
  end

  # ------------------------------------------------------------ 9

  test "9 egress: a private address and a resolver failure send nothing; http is refused at new/1",
       ctx do
    flush_transport()

    for provider <- ["private", "down"] do
      id = "e-" <> provider
      assert connect(ctx.b, id, provider) == {:ok, :applied}
      assert token(ctx.b, id) == {:error, :egress}
      assert {:ok, %{state: :active, revision: 1}} = get(ctx.b, id)
    end

    # a code exchange refused before any byte commits nothing: the state stays usable
    q = begin!(ctx.b, "e-code", provider: "private")
    assert complete(ctx.b, q["state"]) == {:error, :egress}
    assert complete(ctx.b, q["state"]) == {:error, :egress}
    assert Server.count(ctx.server) == 0
    refute_received {:transport, _}

    for key <- [:authorization_endpoint, :token_endpoint, :revocation_endpoint] do
      http = provider("acme", %{key => "http://auth.example.com/x"})
      assert OC.new(Keyword.put(opts(ctx), :providers, [http])) == {:error, :invalid}
    end
  end

  # ------------------------------------------------------------ 10

  test "10 a refresh held past exchange_timeout_ms releases the row lock at the bound", ctx do
    b = binding!(ctx, exchange_timeout_ms: 300)
    %{body: first} = authorize!(ctx, "bound", b: b)
    set_clock(ctx, @t0 + @hour)
    fresh = body()
    Server.respond(ctx.server, fn _req, n -> if n == 2, do: :never, else: {200, fresh} end)

    held = Task.async(fn -> :timer.tc(fn -> token(b, "bound") end) end)
    assert_receive {:holding, _}, 5_000
    waiting = Task.async(fn -> token(b, "bound") end)
    Harness.await_waiting!(1)
    {us, result} = Task.await(held, 5_000)
    assert result == {:error, :exchange_unknown}
    assert us >= 300_000 and us < 3_000_000
    assert Task.await(waiting, 5_000) == {:ok, fresh["access_token"]}

    assert [%{form: %{"refresh_token" => r1}}, %{form: %{"refresh_token" => r2}}] =
             since(ctx, 1)

    assert r1 == first["refresh_token"] and r2 == first["refresh_token"]
  end

  test "10 a 502 on a refresh under rotation is unknown and spends the refresh token", ctx do
    authorize!(ctx, "r502", provider: "rotating")
    set_clock(ctx, @t0 + @hour)
    respond(ctx, {502, "bad gateway"})
    assert token(ctx.b, "r502") == {:error, :reauthorization_required}
    n = Server.count(ctx.server)
    assert token(ctx.b, "r502") == {:error, :reauthorization_required}
    assert Server.count(ctx.server) == n
  end

  # ------------------------------------------------------------ 11

  test "11 a refused client secret or sealing key sends nothing and writes nothing", ctx do
    authorize!(ctx, "a")
    assert connect(ctx.b, "s", "acme") == {:ok, :applied}
    set_clock(ctx, @t0 + @hour)
    q = begin!(ctx.b, "c")
    respond(ctx, {200, body()})

    denied = binding!(ctx, secrets: fn _r -> %{grant: :deny, resolver: &secret/2} end)
    raising = binding!(ctx, secrets: fn _r -> raise "secrets down" end)
    no_key = fn key -> binding!(ctx, sealing: %{key_id: "k1", key: key, keys: &keys/2}) end
    refused = no_key.(fn -> {:error, :unavailable} end)

    short =
      no_key.(fn ->
        {:ok, %Credential{value: :binary.copy(<<1>>, 31), version: 1, expires_at_unix_ms: @far}}
      end)

    before = Harness.truth(ctx.p)
    n = Server.count(ctx.server)
    flush_transport()

    for b <- [denied, raising] do
      assert token(b, "s") == {:error, :secret_unavailable}
      assert token(b, "a") == {:error, :secret_unavailable}
      assert complete(b, q["state"]) == {:error, :secret_unavailable}
    end

    for b <- [refused, short] do
      assert token(b, "s") == {:error, :seal}
      assert token(b, "a") == {:error, :seal}
      assert complete(b, q["state"]) == {:error, :seal}

      assert OC.begin_authorization(b, "T1", %{
               connection_id: "new",
               provider_id: "acme",
               scopes: ["read"]
             }) == {:error, :seal}
    end

    assert Harness.truth(ctx.p) == before
    assert Server.count(ctx.server) == n
    refute_received {:transport, _}
  end

  # ------------------------------------------------------------ 12

  test "12 no token, verifier or state in plain bytes, in inspect or in get", ctx do
    q = begin!(ctx.b, "p")
    first = body()
    code_server(ctx, q, "acme", {200, first})
    assert {:ok, completed} = complete(ctx.b, q["state"])
    verifier = List.last(Server.requests(ctx.server)).form["code_verifier"]
    set_clock(ctx, @t0 + @hour)
    second = body()
    respond(ctx, {200, second})
    assert token(ctx.b, "p") == {:ok, second["access_token"]}
    pending = begin!(ctx.b, "p")
    assert connect(ctx.b, "pc", "post") == {:ok, :applied}
    third = body()
    respond(ctx, {200, third})
    assert {:ok, _} = token(ctx.b, "pc")

    secrets =
      [first, second, third]
      |> Enum.flat_map(&[&1["access_token"], &1["refresh_token"]])
      |> Kernel.++([verifier, q["state"], pending["state"], @secret, @key])

    {:error, {:rows, rows}} =
      TI.transact(AppRepo, %{tenant: "T1"}, fn ->
        {:error,
         {:rows,
          [
            Harness.q!(AppRepo, "SELECT * FROM #{Harness.table(ctx.p, :connections)}"),
            Harness.q!(AppRepo, "SELECT * FROM #{Harness.table(ctx.p, :attempts)}")
          ]}}
      end)

    assert [[_, _], [_, _]] = rows
    bytes = :erlang.term_to_binary(rows)
    for s <- secrets, do: assert(:binary.match(bytes, s) == :nomatch)

    # the stored access token opens only with the README AAD
    [[envelope]] =
      TI.transact(AppRepo, %{tenant: "T1"}, fn ->
        {:error,
         Harness.q!(
           AppRepo,
           "SELECT access_token FROM #{Harness.table(ctx.p, :connections)} WHERE connection_id = 'p'"
         )}
      end)
      |> elem(1)

    aad =
      IO.iodata_to_binary([
        "elzoo-oauth-client/1",
        <<2::32>>,
        "T1",
        <<1::32>>,
        "p",
        <<12::32>>,
        "access_token"
      ])

    assert Encryption.open(envelope, aad, &keys/2) == {:ok, second["access_token"]}
    assert Encryption.open(envelope, aad <> "x", &keys/2) == {:error, :invalid}

    # inspect of the binding, every result and every error
    assert inspect(ctx.b) == "#Elzoo.OauthClient<redacted>"
    {:ok, got} = get(ctx.b, "p")

    assert Enum.sort(Map.keys(got)) ==
             Enum.sort([
               :connection_id,
               :provider_id,
               :grant,
               :scopes,
               :state,
               :expires_at_ms,
               :revision
             ])

    results = [
      completed,
      got,
      connect(ctx.b, "pc", "post"),
      complete(ctx.b, q["state"]),
      token(ctx.b, "missing"),
      revoke(ctx.b, "pc"),
      revoke(ctx.b, "pc"),
      token(ctx.b, "pc"),
      get(ctx.b, "pc"),
      OC.new([]),
      OC.verify(ctx.b)
    ]

    for r <- results,
        s <- secrets ++ [verifier, @secret_ref.ref, @secret_ref.scope],
        do: refute(inspect(r) =~ s)
  end

  # ------------------------------------------------------------ 13

  test "13 row security as the application role with only the README grants", ctx do
    Harness.role_guard!(ctx.role)
    assert OC.verify(ctx.b) == :ok

    authorize!(ctx, "shared", tenant: "T2")
    assert connect(ctx.b, "shared-cc", "acme", ["read"], "T2") == {:ok, :applied}
    q2 = begin!(ctx.b, "shared", tenant: "T2")

    t2 = fn ->
      Harness.truth(ctx.p) |> Map.new(fn {k, rows} -> {k, Enum.filter(rows, &(hd(&1) == "T2"))} end)
    end

    before = t2.()

    for f <- [&token(&1, "shared"), &revoke(&1, "shared"), &get(&1, "shared")],
        do: assert(f.(ctx.b) == {:error, :unknown_connection})

    assert complete(ctx.b, q2["state"]) == {:error, :invalid_state}
    begin!(ctx.b, "shared")
    assert connect(ctx.b, "shared-cc", "post", ["write"]) == {:ok, :applied}
    assert {:ok, %{state: :pending, provider_id: "acme"}} = get(ctx.b, "shared")
    assert {:ok, %{grant: :client_credentials, provider_id: "post"}} = get(ctx.b, "shared-cc")
    assert t2.() == before

    probe = fn sql ->
      {:error, {:probe, result}} =
        TI.transact(AppRepo, %{tenant: "T1"}, fn -> {:error, {:probe, Harness.q(AppRepo, sql)}} end)

      result
    end

    for sql <- [
          "INSERT INTO #{Harness.table(ctx.p, :connections)} (tenant, connection_id, provider_id, grant_type, scopes, state, revision) VALUES ('T2', 'direct', 'acme', 'client_credentials', '{read}', 'active', 1)",
          "INSERT INTO #{Harness.table(ctx.p, :attempts)} (tenant, state_digest, connection_id, scopes, verifier, expires_at_ms) VALUES ('T2', decode(repeat('00', 32), 'hex'), 'direct', '{read}', decode('00', 'hex'), 1)",
          "DELETE FROM #{Harness.table(ctx.p, :connections)}",
          "DELETE FROM #{Harness.table(ctx.p, :attempts)}"
        ],
        do: assert({:error, %Postgrex.Error{postgres: %{code: @denied}}} = probe.(sql))

    missing = binding!(ctx, prefix: "elz361_missing")
    assert {:error, {"elzoo_oauth_connections", reason}} = OC.verify(missing)
    assert is_atom(reason)
  end

  # ------------------------------------------------------------ 14

  defp calls(b, state) do
    [
      OC.begin_authorization(b, "T1", %{connection_id: "i2", provider_id: "acme", scopes: ["read"]}),
      complete(b, state),
      connect(b, "ic2", "acme"),
      token(b, "ic"),
      revoke(b, "ic"),
      get(b, "ic")
    ]
  end

  test "14 a caller transaction, a repeatable read Repo and a missing schema", ctx do
    q = begin!(ctx.b, "i")
    assert connect(ctx.b, "ic", "acme") == {:ok, :applied}
    me = self()
    handler = "elz361-#{System.unique_integer()}"

    {:ok, results} =
      AppRepo.transaction(fn ->
        :telemetry.attach(
          handler,
          [:elzoo, :oauth_client_test, :app_repo, :query],
          fn _, _, meta, _ -> send(me, {:query, meta.query}) end,
          nil
        )

        results = calls(ctx.b, q["state"])
        :telemetry.detach(handler)
        results
      end)

    assert results == List.duplicate({:error, :in_transaction}, 6)
    refute_received {:query, _}

    before = Harness.truth(ctx.p)
    rr = binding!(ctx, repo: RepeatableRepo)
    assert calls(rr, q["state"]) == List.duplicate({:error, :isolation}, 6)
    missing = binding!(ctx, prefix: "elz361_missing")
    assert calls(missing, q["state"]) == List.duplicate({:error, :unavailable}, 6)
    assert Harness.truth(ctx.p) == before
    assert Server.count(ctx.server) == 0
  end

  # ------------------------------------------------------------ 15

  test "15 the credential Need: {:ok, b64token} or {:error, atom}", ctx do
    authorize!(ctx, "need")
    need = fn -> OC.access_token(ctx.b, "T1", %{connection_id: "need"}) end
    assert {:ok, t} = need.()
    assert t =~ ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/ and byte_size(t) in 24..4_096
    assert revoke(ctx.b, "need") == {:ok, :applied}
    assert need.() == {:error, :revoked}
    assert OC.access_token(ctx.b, "T1", %{connection_id: "absent"}) == {:error, :unknown_connection}
  end

  # ------------------------------------------------------------ bounds

  describe "bounds" do
    test "new/1 takes the inner edges, refuses the outer ones and calls no Need", ctx do
      me = self()
      need = fn name -> fn _ -> send(me, {:need, name}) end end

      quiet =
        Keyword.merge(opts(ctx),
          resolver: need.(:resolver),
          transport: need.(:transport),
          secrets: need.(:secrets),
          clock: fn -> send(me, {:need, :clock}) end,
          sealing: %{
            key_id: String.duplicate("k", 128),
            key: fn -> send(me, {:need, :key}) end,
            keys: fn _, _ -> send(me, {:need, :keys}) end
          }
        )

      many = for i <- 1..64, do: provider("p#{i}")
      scopes = for i <- 1..64, do: "s#{i}"
      wide = String.duplicate("x", 128)
      max_budget = %{lock_wait_ms: 1, overhead_ms: 589_999, persistence_reserve_ms: 589_999}

      inner = [
        [refresh_deadline: max_budget],
        [providers: many],
        [providers: [provider(String.duplicate("a.b-_9", 10) <> "abcd")]],
        [providers: [provider("acme", %{scopes_allowed: scopes})]],
        [providers: [provider("acme", %{scopes_allowed: [wide, "!#[]~"]})]],
        [providers: [provider("acme", %{client_id: String.duplicate("c", 256)})]],
        [
          providers: [
            provider("acme", %{
              redirect_uri: "https://app.example.org/" <> String.duplicate("r", 2_024)
            })
          ]
        ],
        [providers: [provider("acme", %{default_lifetime_s: 1})]],
        [providers: [provider("acme", %{default_lifetime_s: 31_536_000})]],
        [providers: [provider("acme", %{revocation_endpoint: nil})]],
        [exchange_timeout_ms: 1, skew_ms: 0],
        [exchange_timeout_ms: 30_000, skew_ms: 3_600_000]
      ]

      for overrides <- inner,
          do: assert({:ok, %OC{}} = OC.new(Keyword.merge(quiet, overrides)), inspect(overrides))

      p = &[providers: [provider("acme", &1)]]

      outer = [
        [refresh_deadline: nil],
        [refresh_deadline: Map.to_list(max_budget)],
        [refresh_deadline: Map.put(max_budget, :extra, 1)],
        [refresh_deadline: Map.delete(max_budget, :persistence_reserve_ms)],
        [refresh_deadline: %{max_budget | lock_wait_ms: 2}],
        [refresh_deadline: %{max_budget | lock_wait_ms: 0}],
        [refresh_deadline: %{max_budget | overhead_ms: 0}],
        [refresh_deadline: %{max_budget | persistence_reserve_ms: 0}],
        [refresh_deadline: %{max_budget | persistence_reserve_ms: 590_000}],
        [refresh_deadline: %{max_budget | lock_wait_ms: 1.0}],
        [refresh_deadline: %{max_budget | overhead_ms: 589_999.0}],
        [refresh_deadline: %{max_budget | persistence_reserve_ms: 1.5}],
        [providers: []],
        [providers: many ++ [provider("p65")]],
        [providers: [provider("acme"), provider("acme")]],
        p.(%{provider_id: ""}),
        p.(%{provider_id: String.duplicate("a", 65)}),
        p.(%{provider_id: "Acme"}),
        p.(%{authorization_endpoint: "https://evil.example.com/a"}),
        p.(%{token_endpoint: "https://auth.example.com:8443/token"}),
        p.(%{token_endpoint: nil}),
        p.(%{redirect_uri: "http://app.example.org/cb"}),
        p.(%{redirect_uri: "https://app.example.org/cb#frag"}),
        p.(%{redirect_uri: "https://app.example.org/" <> String.duplicate("r", 2_025)}),
        p.(%{client_id: ""}),
        p.(%{client_id: String.duplicate("c", 257)}),
        p.(%{client_auth: :none}),
        p.(%{client_secret_ref: nil}),
        p.(%{client_auth: :private_key_jwt}),
        p.(%{client_secret_ref: %{ref: "", scope: "s"}}),
        p.(%{scopes_allowed: []}),
        p.(%{scopes_allowed: scopes ++ ["s65"]}),
        p.(%{scopes_allowed: ["read", "read"]}),
        p.(%{scopes_allowed: ["a b"]}),
        p.(%{scopes_allowed: [~s(a"b)]}),
        p.(%{scopes_allowed: [wide <> "x"]}),
        p.(%{refresh_rotation: nil}),
        p.(%{default_lifetime_s: 0}),
        p.(%{default_lifetime_s: 31_536_001}),
        p.(%{extra: 1}),
        [providers: [Map.delete(provider("acme"), :default_lifetime_s)]],
        [exchange_timeout_ms: 0],
        [exchange_timeout_ms: 30_001],
        [skew_ms: -1],
        [skew_ms: 3_600_001],
        [
          sealing: %{
            key_id: String.duplicate("k", 129),
            key: fn -> :ok end,
            keys: fn _, _ -> :ok end
          }
        ],
        [sealing: %{key_id: "k1", key: fn -> :ok end}],
        [policy: %{hosts: [], ports: []}],
        [resolver: fn _, _ -> :ok end],
        [prefix: "Bad"],
        [repo: nil],
        [unknown: 1]
      ]

      for overrides <- outer,
          do:
            assert(
              OC.new(Keyword.merge(quiet, overrides)) == {:error, :invalid},
              inspect(overrides)
            )

      assert OC.new(Keyword.delete(quiet, :clock)) == {:error, :invalid}
      assert OC.new(quiet ++ [skew_ms: 1, skew_ms: 2]) == {:error, :invalid}
      refute_received {:need, _}
    end

    test "requests: shapes, providers and scopes are checked before any query", ctx do
      c128 = String.duplicate("c", 128)
      assert connect(ctx.b, c128, "acme") == {:ok, :applied}
      assert {:ok, %{connection_id: ^c128}} = get(ctx.b, c128)
      assert connect(ctx.b, c128 <> "c", "acme") == {:error, :invalid}
      assert connect(ctx.b, "x", "acme", ["read"], String.duplicate("t", 129)) == {:error, :invalid}
      assert connect(ctx.b, "x", "acme", []) == {:error, :invalid}
      assert connect(ctx.b, "x", "acme", ["read", "read"]) == {:error, :invalid}
      assert connect(ctx.b, "x", "acme", ["admin"]) == {:error, :scope}
      assert connect(ctx.b, "x", "nobody") == {:error, :unknown_provider}
      assert connect(ctx.b, "x", "No body") == {:error, :invalid}
      assert get(ctx.b, "x\n") == {:error, :invalid}
      assert OC.get(ctx.b, "T1", %{connection_id: "x", extra: 1}) == {:error, :invalid}
      assert OC.get(:not_a_binding, "T1", %{connection_id: "x"}) == {:error, :invalid}
      assert OC.verify(:not_a_binding) == {:error, :invalid}
      assert complete(ctx.b, String.duplicate("s", 2_049)) == {:error, :invalid}
      assert complete(ctx.b, String.duplicate("s", 2_048)) == {:error, :invalid_state}
      assert complete(ctx.b, "") == {:error, :invalid}

      assert OC.begin_authorization(ctx.b, "T1", %{connection_id: "x", provider_id: "acme"}) ==
               {:error, :invalid}

      assert Server.count(ctx.server) == 0
    end

    test "the migration refuses a bad prefix before any DDL" do
      for bad <- ["Bad", "", "a-b", String.duplicate("a", 64), :atom],
          do:
            assert_raise(ArgumentError, "invalid oauth client prefix", fn ->
              Elzoo.OauthClient.Migration.install(bad)
            end)
    end
  end
end
