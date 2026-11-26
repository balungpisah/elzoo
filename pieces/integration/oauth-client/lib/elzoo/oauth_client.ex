# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OauthClient do
  @moduledoc """
  A tenant's OAuth 2.0 connections to host-declared authorization servers, over a
  consumer-owned Ecto Repo on PostgreSQL 19 (ELZ-361).

  A connection is made by an authorization code grant with PKCE S256 that a tenant admin
  consents to once, or by a client credentials grant. Its access and refresh tokens are stored
  only as `Elzoo.Encryption` envelopes. `access_token/3` is the one function that returns a token
  value: a token that is fresh under the trusted clock, or one that it obtains under the
  connection row lock, so concurrent callers make one exchange.

  Every exchange is one `application/x-www-form-urlencoded` POST through Req, after
  `Elzoo.EgressPolicy.resolve/3`, with retries and redirects off, in a task stopped at
  `exchange_timeout_ms`. Every write runs in its own transaction through
  `Elzoo.TenantIsolation` at READ COMMITTED (a consumer Need that the Piece checks).

  Errors are `{:error, reason}` with a fixed atom that echoes no ID, URL, token, code or provider
  message. The Piece emits no telemetry and no log; its queries pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.EgressPolicy
  alias Elzoo.Encryption
  alias Elzoo.Secrets
  alias Elzoo.Secrets.Credential
  alias Elzoo.TenantIsolation

  @message "invalid oauth client prefix"
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
  @required [:clock, :policy, :prefix, :providers, :repo, :resolver, :sealing, :secrets, :transport]
  @optional [:exchange_timeout_ms, :skew_ms, :refresh_deadline]
  @provider_keys Enum.sort(~w(provider_id authorization_endpoint token_endpoint
                    revocation_endpoint redirect_uri client_id client_secret_ref client_auth
                    scopes_allowed refresh_rotation default_lifetime_s)a)
  @attempt_ms 600_000
  @max_body 65_536
  @max_token 4_096
  @max_lifetime_s 31_536_000
  @max_now 9_007_199_254_740_991
  @tables ~w(elzoo_oauth_connections elzoo_oauth_attempts)
  @grants %{
    "authorization_code" => :authorization_code,
    "client_credentials" => :client_credentials
  }
  @states %{
    "pending" => :pending,
    "active" => :active,
    "reauthorization_required" => :reauthorization_required,
    "revoked" => :revoked
  }
  @cleared %{access_token: nil, refresh_token: nil, obtained_at_ms: nil, expires_at_ms: nil}

  @enforce_keys [
    :repo,
    :prefix,
    :providers,
    :policy,
    :resolver,
    :transport,
    :exchange_timeout_ms,
    :secrets,
    :sealing,
    :clock,
    :skew_ms
  ]
  defstruct @enforce_keys ++ [refresh_deadline: nil]

  defimpl Inspect do
    def inspect(_binding, _opts), do: "#Elzoo.OauthClient<redacted>"
  end

  # ── binding ─────────────────────────────────────────────────────────────

  @doc """
  A binding from exactly the options of the README (`exchange_timeout_ms`, `skew_ms` and `refresh_deadline`
  optional): `{:ok, binding}` or `{:error, :invalid}`. Calls no Need.
  """
  def new(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in (@required ++ @optional))),
         true <- Enum.all?(@required, &(&1 in keys)),
         repo when is_atom(repo) and repo not in [nil, true, false] <- opts[:repo],
         true <- identifier?(opts[:prefix]),
         policy when is_struct(policy, EgressPolicy) <- opts[:policy],
         true <- is_function(opts[:resolver], 1) and is_function(opts[:transport], 1),
         true <- is_function(opts[:secrets], 1) and is_function(opts[:clock], 0),
         timeout when is_integer(timeout) and timeout in 1..30_000 <-
           Keyword.get(opts, :exchange_timeout_ms, 10_000),
         {:ok, budget} <- refresh_budget(Keyword.fetch(opts, :refresh_deadline), timeout),
         skew when is_integer(skew) and skew in 0..3_600_000 <- Keyword.get(opts, :skew_ms, 60_000),
         true <- sealing?(opts[:sealing]),
         {:ok, providers} <- providers(opts[:providers], policy) do
      {:ok,
       %__MODULE__{
         repo: repo,
         prefix: opts[:prefix],
         providers: providers,
         policy: policy,
         resolver: opts[:resolver],
         transport: opts[:transport],
         exchange_timeout_ms: timeout,
         refresh_deadline: budget,
         secrets: opts[:secrets],
         sealing: opts[:sealing],
         clock: opts[:clock],
         skew_ms: skew
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp refresh_budget(:error, _exchange), do: {:ok, nil}

  defp refresh_budget(
         {:ok, %{lock_wait_ms: lock, overhead_ms: overhead, persistence_reserve_ms: reserve} = m},
         exchange
       )
       when map_size(m) == 3 and is_integer(lock) and lock > 0 and is_integer(overhead) and
              is_integer(reserve) and reserve > 0 and reserve <= overhead and
              lock + exchange + overhead <= 600_000,
       do: {:ok, {lock + exchange + overhead, exchange + reserve}}

  defp refresh_budget(_, _), do: :invalid

  @doc false
  # The quoted schema name, shared with Elzoo.OauthClient.Migration.install/1.
  def prefix!(prefix) do
    if identifier?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  defp identifier?(name), do: is_binary(name) and name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  defp providers(list, policy) do
    with true <- list != [] and within?(list, 64),
         true <- Enum.all?(list, &provider?(&1, policy)),
         ids = Enum.map(list, & &1.provider_id),
         true <- ids == Enum.uniq(ids) do
      {:ok, Map.new(list, &{&1.provider_id, &1})}
    else
      _ -> :error
    end
  end

  defp provider?(p, policy) when is_map(p) and not is_struct(p) and map_size(p) == 11 do
    Enum.sort(Map.keys(p)) == @provider_keys and provider_id?(p.provider_id) and
      endpoint?(p.authorization_endpoint, policy) and endpoint?(p.token_endpoint, policy) and
      (is_nil(p.revocation_endpoint) or endpoint?(p.revocation_endpoint, policy)) and
      redirect_uri?(p.redirect_uri) and text?(p.client_id, 256) and
      secret_ref?(p.client_secret_ref) and client_auth?(p.client_auth, p.client_secret_ref) and
      scopes?(p.scopes_allowed) and is_boolean(p.refresh_rotation) and
      (is_nil(p.default_lifetime_s) or
         (is_integer(p.default_lifetime_s) and p.default_lifetime_s in 1..@max_lifetime_s))
  end

  defp provider?(_p, _policy), do: false

  defp provider_id?(id),
    do: is_binary(id) and byte_size(id) in 1..64 and id =~ ~r/\A[a-z0-9._-]+\z/

  defp endpoint?(url, policy), do: match?({:ok, _}, EgressPolicy.check(url, policy))

  # An https URL that is only placed in requests, never fetched.
  defp redirect_uri?(uri) when is_binary(uri) and byte_size(uri) in 1..2_048 do
    String.valid?(uri) and
      match?(
        {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
        when is_binary(host) and host != "",
        URI.new(uri)
      )
  end

  defp redirect_uri?(_uri), do: false

  defp secret_ref?(nil), do: true

  defp secret_ref?(%{ref: ref, scope: scope} = r) when not is_struct(r) and map_size(r) == 2,
    do:
      is_binary(ref) and byte_size(ref) in 1..128 and is_binary(scope) and
        byte_size(scope) in 1..128

  defp secret_ref?(_ref), do: false

  defp client_auth?(:none, nil), do: true
  defp client_auth?(auth, %{}) when auth in [:client_secret_basic, :client_secret_post], do: true
  defp client_auth?(_auth, _ref), do: false

  defp sealing?(%{key_id: id, key: key, keys: keys} = s) when not is_struct(s) and map_size(s) == 3,
    do: text?(id, 128) and is_function(key, 0) and is_function(keys, 2)

  defp sealing?(_sealing), do: false

  # 1..64 unique RFC 6749 scope-tokens of 1..128 bytes.
  defp scopes?(list),
    do:
      list != [] and within?(list, 64) and Enum.all?(list, &scope_token?/1) and
        list == Enum.uniq(list)

  defp scope_token?(t) when is_binary(t) and byte_size(t) in 1..128, do: scope_bytes?(t)
  defp scope_token?(_t), do: false

  defp scope_bytes?(<<>>), do: true

  defp scope_bytes?(<<c, rest::binary>>) when c == 0x21 or c in 0x23..0x5B or c in 0x5D..0x7E,
    do: scope_bytes?(rest)

  defp scope_bytes?(_t), do: false

  # ── authorization code ──────────────────────────────────────────────────

  @doc """
  Create the connection `:pending` (or take an existing one of the same provider and grant that
  is not revoked) and record one authorization attempt: `{:ok, %{authorization_url: url}}`. The
  URL carries the attempt's `state`.
  """
  def begin_authorization(binding, tenant, request) do
    with {:ok, b} <- checked(binding),
         {:ok, id, provider_id, scopes} <- connect_shape(tenant, request),
         {:ok, p} <- provider(b, provider_id),
         :ok <- allowed(p, scopes),
         :ok <- outside(b) do
      run(b, tenant, fn ->
        with {:ok, now} <- now(b),
             {:ok, key} <- seal_key(b),
             :ok <- take(b, tenant, id, provider_id, scopes) do
          state = b64(:crypto.strong_rand_bytes(32))
          verifier = b64(:crypto.strong_rand_bytes(32))

          query(
            b,
            "INSERT INTO #{table(b, :attempts)} (tenant, state_digest, connection_id, scopes, verifier, expires_at_ms) VALUES ($1, $2, $3, $4, $5, $6)",
            [
              tenant,
              :crypto.hash(:sha256, state),
              id,
              scopes,
              seal(b, key, verifier, tenant, id, "pkce_verifier"),
              now + @attempt_ms
            ]
          )

          {:ok, {:ok, %{authorization_url: authorization_url(p, scopes, state, verifier)}}}
        end
      end)
    end
  end

  defp take(b, tenant, id, provider_id, scopes) do
    inserted =
      query(
        b,
        "INSERT INTO #{table(b, :connections)} (tenant, connection_id, provider_id, grant_type, scopes, state, revision) VALUES ($1, $2, $3, 'authorization_code', $4, 'pending', 1) ON CONFLICT DO NOTHING",
        [tenant, id, provider_id, scopes]
      )

    if inserted.num_rows == 1 do
      :ok
    else
      case connection(b, tenant, id, :lock) do
        {:ok, %{provider_id: ^provider_id, grant: :authorization_code, state: :revoked}} ->
          {:error, :revoked}

        {:ok, %{provider_id: ^provider_id, grant: :authorization_code}} ->
          :ok

        {:ok, _other} ->
          {:error, :conflict}

        {:error, :unknown_connection} ->
          {:error, :unavailable}
      end
    end
  end

  defp authorization_url(p, scopes, state, verifier) do
    query =
      URI.encode_query([
        {"response_type", "code"},
        {"client_id", p.client_id},
        {"redirect_uri", p.redirect_uri},
        {"scope", Enum.join(scopes, " ")},
        {"state", state},
        {"code_challenge", b64(:crypto.hash(:sha256, verifier))},
        {"code_challenge_method", "S256"}
      ])

    p.authorization_endpoint |> URI.parse() |> URI.append_query(query) |> URI.to_string()
  end

  @doc """
  Complete an attempt with the host's callback `%{state, code}`: one authorization code exchange.
  `{:ok, connection}` with the connection `:active`, or an error that leaves it as it was.
  """
  def complete_authorization(binding, tenant, request) do
    with {:ok, b} <- checked(binding),
         {:ok, state, code} <- callback_shape(tenant, request),
         :ok <- outside(b),
         {:ok, claim} <-
           run(b, tenant, fn -> claim(b, tenant, :crypto.hash(:sha256, state), code) end),
         {:sent, outcome} <- send_bounded(b, claim.request, nil) do
      case tokens(outcome, claim.now, claim.provider) do
        {:tokens, t} ->
          run(b, tenant, fn ->
            with {:ok, c} <- connection(b, tenant, claim.connection_id, :lock) do
              if c.state == :revoked do
                {:error, :revoked}
              else
                c = stored(b, tenant, c, claim.key, t, nil, claim.scopes)
                {:ok, {:ok, public(c)}}
              end
            end
          end)

        other ->
          failure(other)
      end
    end
  end

  # Reads and marks the attempt used in one transaction, so a state is used at most once; every
  # step before the exchange runs here, so a refusal before any byte is sent commits nothing.
  defp claim(b, tenant, digest, code) do
    with {:ok, now} <- now(b),
         {:ok, id, scopes, verifier} <- attempt(b, tenant, digest, now),
         {:ok, c} <- connection(b, tenant, id, :lock),
         :ok <- if(c.state == :revoked, do: {:error, :revoked}, else: :ok),
         {:ok, p} <- provider(b, c.provider_id),
         {:ok, verifier} <- open(b, verifier, tenant, id, "pkce_verifier"),
         {:ok, key} <- seal_key(b),
         {:ok, request} <-
           prepare(b, p, p.token_endpoint, [
             {"grant_type", "authorization_code"},
             {"code", code},
             {"redirect_uri", p.redirect_uri},
             {"code_verifier", verifier}
           ]) do
      query(
        b,
        "UPDATE #{table(b, :attempts)} SET used = true WHERE tenant = $1 AND state_digest = $2",
        [tenant, digest]
      )

      {:ok,
       {:ok,
        %{
          request: request,
          provider: p,
          key: key,
          connection_id: id,
          scopes: scopes,
          now: now
        }}}
    end
  end

  defp attempt(b, tenant, digest, now) do
    case rows(
           b,
           "SELECT connection_id, scopes, verifier, expires_at_ms, used FROM #{table(b, :attempts)} WHERE tenant = $1 AND state_digest = $2 FOR UPDATE",
           [tenant, digest]
         ) do
      [[id, scopes, verifier, expires_at, false]] when now < expires_at ->
        {:ok, id, scopes, verifier}

      _ ->
        {:error, :invalid_state}
    end
  end

  # ── client credentials ──────────────────────────────────────────────────

  @doc """
  Create an `:active` client credentials connection with no token: `{:ok, :applied}`, or
  `{:ok, :duplicate}` for an existing one with equal provider, grant and scopes, `:revoked` for a
  revoked one of that provider, else `:conflict`.
  """
  def connect_client(binding, tenant, request) do
    with {:ok, b} <- checked(binding),
         {:ok, id, provider_id, scopes} <- connect_shape(tenant, request),
         {:ok, p} <- provider(b, provider_id),
         :ok <- allowed(p, scopes),
         :ok <- outside(b) do
      run(b, tenant, fn ->
        inserted =
          query(
            b,
            "INSERT INTO #{table(b, :connections)} (tenant, connection_id, provider_id, grant_type, scopes, state, revision) VALUES ($1, $2, $3, 'client_credentials', $4, 'active', 1) ON CONFLICT DO NOTHING",
            [tenant, id, provider_id, scopes]
          )

        if inserted.num_rows == 1 do
          {:ok, {:ok, :applied}}
        else
          case connection(b, tenant, id, :lock) do
            {:ok, %{provider_id: ^provider_id, grant: :client_credentials, state: :revoked}} ->
              {:error, :revoked}

            {:ok, %{provider_id: ^provider_id, grant: :client_credentials, scopes: ^scopes}} ->
              {:ok, {:ok, :duplicate}}

            {:ok, _other} ->
              {:error, :conflict}

            {:error, :unknown_connection} ->
              {:error, :unavailable}
          end
        end
      end)
    end
  end

  # ── tokens ──────────────────────────────────────────────────────────────

  @doc """
  `{:ok, token}`: a token fresh under the trusted clock, or one obtained now under the connection
  row lock. The one function that returns a token value.
  """
  def access_token(binding, tenant, request) do
    with {:ok, b} <- checked(binding),
         {:ok, id} <- id_shape(tenant, request),
         :ok <- outside(b) do
      {opts, latest_dispatch} =
        case b.refresh_deadline do
          nil ->
            {[], nil}

          {total, required} ->
            {[timeout: total],
             System.monotonic_time() +
               System.convert_time_unit(total - required, :millisecond, :native)}
        end

      run(b, tenant, opts, fn ->
        with {:ok, c} <- connection(b, tenant, id, :lock),
             {:ok, now} <- now(b) do
          token(b, tenant, c, now, latest_dispatch)
        end
      end)
    end
  end

  defp token(_b, _tenant, %{state: :revoked}, _now, _latest), do: {:error, :revoked}

  defp token(_b, _tenant, %{state: :reauthorization_required}, _now, _latest),
    do: {:error, :reauthorization_required}

  defp token(_b, _tenant, %{state: :pending}, _now, _latest), do: {:error, :not_active}

  defp token(b, tenant, c, now, latest) do
    if fresh?(c, now, b.skew_ms) do
      with {:ok, t} <- open(b, c.access_token, tenant, c.connection_id, "access_token"),
           do: {:ok, {:ok, t}}
    else
      renew(b, tenant, c, now, latest)
    end
  end

  # Fresh: expires after now by at least the skew, or by half the token's lifetime when that is
  # shorter.
  defp fresh?(%{access_token: a, expires_at_ms: e, obtained_at_ms: o}, now, skew)
       when is_binary(a) and is_integer(e) and is_integer(o),
       do: e > now and e - now >= min(skew, div(e - o, 2))

  defp fresh?(_c, _now, _skew), do: false

  defp renew(b, tenant, %{grant: :client_credentials} = c, now, latest) do
    with {:ok, p} <- provider(b, c.provider_id),
         {:ok, key} <- seal_key(b),
         {:sent, outcome} <-
           exchange(b, p, p.token_endpoint, latest, [
             {"grant_type", "client_credentials"},
             {"scope", Enum.join(c.scopes, " ")}
           ]) do
      case tokens(outcome, now, p) do
        {:tokens, t} ->
          stored(b, tenant, c, key, t, c.refresh_token, c.scopes)
          {:ok, {:ok, t.access}}

        other ->
          failure(other)
      end
    end
  end

  defp renew(b, tenant, %{refresh_token: nil} = c, _now, _latest), do: reauthorize(b, tenant, c)

  defp renew(b, tenant, c, now, latest) do
    with {:ok, p} <- provider(b, c.provider_id),
         {:ok, refresh} <- open(b, c.refresh_token, tenant, c.connection_id, "refresh_token"),
         {:ok, key} <- seal_key(b),
         {:sent, outcome} <-
           exchange(b, p, p.token_endpoint, latest, [
             {"grant_type", "refresh_token"},
             {"refresh_token", refresh}
           ]) do
      case tokens(outcome, now, p) do
        {:tokens, t} ->
          stored(b, tenant, c, key, t, c.refresh_token, c.scopes)
          {:ok, {:ok, t.access}}

        {:refused, :invalid_grant} ->
          reauthorize(b, tenant, c)

        {:refused, _error} ->
          {:error, :exchange_refused}

        # The refresh token may be spent: it is never sent again.
        _unknown_or_malformed when p.refresh_rotation ->
          reauthorize(b, tenant, c)

        other ->
          failure(other)
      end
    end
  end

  defp failure({:refused, _error}), do: {:error, :exchange_refused}
  defp failure(:unknown), do: {:error, :exchange_unknown}
  defp failure(:malformed), do: {:error, :malformed_response}

  # Store new tokens; a response without refresh_token keeps `fallback`. Returns the connection.
  defp stored(b, tenant, c, key, t, fallback, scopes) do
    id = c.connection_id

    refresh =
      if t.refresh, do: seal(b, key, t.refresh, tenant, id, "refresh_token"), else: fallback

    update(b, tenant, c, %{
      state: :active,
      scopes: scopes,
      access_token: seal(b, key, t.access, tenant, id, "access_token"),
      refresh_token: refresh,
      obtained_at_ms: t.obtained_at_ms,
      expires_at_ms: t.expires_at_ms
    })
  end

  # Committed with the error it returns.
  defp reauthorize(b, tenant, c) do
    update(b, tenant, c, Map.put(@cleared, :state, :reauthorization_required))
    {:ok, {:error, :reauthorization_required}}
  end

  # ── revocation and reads ────────────────────────────────────────────────

  @doc """
  Revoke a connection: one RFC 7009 call when the provider has a `revocation_endpoint` and the
  connection holds a token, then `:revoked` with the tokens removed whatever that call returns.
  `{:ok, :applied}`, or `{:ok, :duplicate}` with no call for a revoked connection.
  """
  def revoke(binding, tenant, request) do
    with {:ok, b} <- checked(binding),
         {:ok, id} <- id_shape(tenant, request),
         :ok <- outside(b) do
      run(b, tenant, fn ->
        with {:ok, c} <- connection(b, tenant, id, :lock) do
          if c.state == :revoked do
            {:ok, {:ok, :duplicate}}
          else
            revocation(b, tenant, c)
            update(b, tenant, c, Map.put(@cleared, :state, :revoked))
            {:ok, {:ok, :applied}}
          end
        end
      end)
    end
  end

  # The refresh token when there is one, else the access token; the outcome is not read.
  defp revocation(b, tenant, c) do
    {envelope, hint} =
      if c.refresh_token,
        do: {c.refresh_token, "refresh_token"},
        else: {c.access_token, "access_token"}

    with true <- is_binary(envelope),
         {:ok, %{revocation_endpoint: url} = p} when is_binary(url) <- provider(b, c.provider_id),
         {:ok, token} <- open(b, envelope, tenant, c.connection_id, hint),
         do: exchange(b, p, url, nil, [{"token", token}, {"token_type_hint", hint}])

    :ok
  end

  @doc "`{:ok, connection}` without any token."
  def get(binding, tenant, request) do
    with {:ok, b} <- checked(binding),
         {:ok, id} <- id_shape(tenant, request),
         :ok <- outside(b) do
      run(b, tenant, fn ->
        with {:ok, c} <- connection(b, tenant, id, :read), do: {:ok, {:ok, public(c)}}
      end)
    end
  end

  @doc "`Elzoo.TenantIsolation.verify/3` of both tables: `:ok` or `{:error, {table, reason}}`."
  def verify(binding) do
    with {:ok, b} <- checked(binding) do
      Enum.find_value(@tables, :ok, fn name ->
        case TenantIsolation.verify(b.repo, {b.prefix, name},
               prefix: b.prefix,
               tenant_column: "tenant",
               space_column: nil
             ) do
          :ok -> nil
          {:error, reason} -> {:error, {name, reason}}
        end
      end)
    end
  end

  # ── exchanges ───────────────────────────────────────────────────────────

  defp exchange(b, p, url, latest, form) do
    with {:ok, request} <- prepare(b, p, url, form),
         :ok <- headroom(latest),
         do: send_bounded(b, request, latest)
  end

  defp headroom(nil), do: :ok

  defp headroom(latest),
    do: if(System.monotonic_time() <= latest, do: :ok, else: {:error, :unavailable})

  # Everything before the first byte: egress, the client secret and the transport Need.
  defp prepare(b, p, url, form) do
    with {:ok, target} <- egress(b, url),
         {:ok, form, headers} <- client_auth(b, p, form),
         {:ok, opts} <- transport(b, target) do
      request(b, opts, url, form, headers)
    end
  end

  # A failed or malformed answer of the transport Need is :egress: nothing was sent.
  defp transport(b, target) do
    case call(fn -> b.transport.(target) end) do
      {:ok, opts} when is_list(opts) ->
        if Keyword.keyword?(opts), do: {:ok, opts}, else: {:error, :egress}

      _ ->
        {:error, :egress}
    end
  end

  defp egress(b, url) do
    case EgressPolicy.resolve(url, b.policy, b.resolver) do
      {:ok, target} -> {:ok, target}
      {:error, _reason} -> {:error, :egress}
    end
  end

  defp client_auth(_b, %{client_auth: :none} = p, form),
    do: {:ok, form ++ [{"client_id", p.client_id}], []}

  defp client_auth(b, p, form) do
    case secret(b, p.client_secret_ref) do
      {:ok, s} when p.client_auth == :client_secret_post ->
        {:ok, form ++ [{"client_id", p.client_id}, {"client_secret", s}], []}

      {:ok, s} ->
        # RFC 6749 section 2.3.1: each part form-encoded before Basic.
        basic = Base.encode64(URI.encode_www_form(p.client_id) <> ":" <> URI.encode_www_form(s))
        {:ok, form, [{"authorization", "Basic " <> basic}]}

      :error ->
        {:error, :secret_unavailable}
    end
  end

  defp secret(b, ref) do
    with %{} = context <- call(fn -> b.secrets.(ref) end),
         {:ok, %Credential{} = credential} <- Secrets.resolve(ref, context) do
      {:ok, Secrets.reveal(credential)}
    else
      _ -> :error
    end
  end

  # The host's options first, then the Piece's, so retries, redirects and compression cannot be
  # turned back on (the body bound counts the raw bytes).
  defp request(b, opts, url, form, headers) do
    {:ok,
     opts
     |> Req.new()
     |> Req.merge(
       method: :post,
       url: url,
       form: form,
       headers: [{"accept", "application/json"} | headers],
       compressed: false,
       raw: true,
       into: &bounded/2,
       retry: false,
       redirect: false,
       receive_timeout: b.exchange_timeout_ms
     )}
  rescue
    _ -> {:error, :egress}
  end

  # Keep at most @max_body bytes; past that, drop the body and mark the response.
  defp bounded({:data, data}, {request, response}) do
    body = if is_binary(response.body), do: response.body, else: ""

    if byte_size(body) + byte_size(data) > @max_body do
      {:halt, {request, Req.Response.put_private(%{response | body: ""}, :elzoo_oversize, true)}}
    else
      {:cont, {request, %{response | body: body <> data}}}
    end
  end

  # A stopped opt-in task is unknown only if it passed the dispatch check.
  defp send_bounded(b, request, latest) do
    admitted = if latest, do: :atomics.new(1, [])

    task =
      Task.async(fn ->
        try do
          # Task scheduling spends the same budget. A local refusal is not a provider outcome.
          with :ok <- headroom(latest) do
            if admitted, do: :atomics.put(admitted, 1, 1)
            {:sent, Req.request(request)}
          end
        catch
          _kind, _reason -> {:sent, :failed}
        end
      end)

    case Task.yield(task, b.exchange_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, :unavailable} = refused} ->
        refused

      {:ok, {:sent, result}} ->
        {:sent, outcome(result)}

      _stopped ->
        if admitted && :atomics.get(admitted, 1) == 0,
          do: {:error, :unavailable},
          else: {:sent, :unknown}
    end
  end

  defp outcome({:ok, %Req.Response{status: status} = r}) when status in 200..299,
    do: {:ok, if(r.private[:elzoo_oversize], do: :oversize, else: r.body)}

  defp outcome({:ok, %Req.Response{status: status} = r}) when status in 400..499,
    do: {:refused, error_code(r)}

  # A 3xx (not followed), a 5xx, a transport error, a timeout or a stopped task.
  defp outcome(_result), do: :unknown

  defp error_code(r) do
    with false <- r.private[:elzoo_oversize] == true,
         body when is_binary(body) <- r.body,
         {:ok, %{"error" => "invalid_grant"}} <- Jason.decode(body) do
      :invalid_grant
    else
      _ -> :other
    end
  end

  # The success shape of a token response; anything else from a 2xx is malformed.
  defp tokens({:ok, body}, now, p) when is_binary(body) do
    with {:ok, %{} = m} <- Jason.decode(body),
         access when is_binary(access) and byte_size(access) in 1..@max_token <-
           m["access_token"],
         type when is_binary(type) <- m["token_type"],
         "bearer" <- String.downcase(type, :ascii),
         {:ok, lifetime} <- lifetime(m, p),
         {:ok, refresh} <- refresh(m),
         true <- not Map.has_key?(m, "scope") or is_binary(m["scope"]) do
      {:tokens,
       %{
         access: access,
         refresh: refresh,
         obtained_at_ms: now,
         expires_at_ms: now + lifetime * 1_000
       }}
    else
      _ -> :malformed
    end
  end

  defp tokens({:ok, :oversize}, _now, _p), do: :malformed
  defp tokens(other, _now, _p), do: other

  defp lifetime(m, p) do
    case Map.fetch(m, "expires_in") do
      :error -> {:ok, p.default_lifetime_s || 0}
      {:ok, n} when is_integer(n) and n in 1..@max_lifetime_s -> {:ok, n}
      {:ok, _other} -> :error
    end
  end

  defp refresh(m) do
    case Map.fetch(m, "refresh_token") do
      :error -> {:ok, nil}
      {:ok, t} when is_binary(t) and byte_size(t) in 1..@max_token -> {:ok, t}
      {:ok, _other} -> :error
    end
  end

  # ── sealing ─────────────────────────────────────────────────────────────

  # The current key, checked by a probe seal before any byte is sent.
  defp seal_key(b) do
    with {:ok, %Credential{} = key} <- call(b.sealing.key),
         {:ok, _probe} <- Encryption.seal("", "", b.sealing.key_id, key) do
      {:ok, key}
    else
      _ -> {:error, :seal}
    end
  end

  defp seal(b, key, value, tenant, id, field) do
    {:ok, envelope} = Encryption.seal(value, aad(tenant, id, field), b.sealing.key_id, key)
    envelope
  end

  defp open(b, envelope, tenant, id, field) do
    case Encryption.open(envelope, aad(tenant, id, field), b.sealing.keys) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, :seal}
    end
  end

  # The canonical AAD (README "Sealing"): a tag, then each part as a 32-bit length and its bytes.
  defp aad(tenant, id, field) do
    IO.iodata_to_binary([
      "elzoo-oauth-client/1" | for(part <- [tenant, id, field], do: [<<byte_size(part)::32>>, part])
    ])
  end

  # ── rows ────────────────────────────────────────────────────────────────

  defp connection(b, tenant, id, mode) do
    lock = if mode == :lock, do: " FOR UPDATE", else: ""

    case rows(
           b,
           "SELECT provider_id, grant_type, scopes, state, access_token, refresh_token, obtained_at_ms, expires_at_ms, revision FROM #{table(b, :connections)} WHERE tenant = $1 AND connection_id = $2" <>
             lock,
           [tenant, id]
         ) do
      [] ->
        {:error, :unknown_connection}

      [[provider_id, grant, scopes, state, access, refresh, obtained, expires, revision]] ->
        {:ok,
         %{
           connection_id: id,
           provider_id: provider_id,
           grant: Map.fetch!(@grants, grant),
           scopes: scopes,
           state: Map.fetch!(@states, state),
           access_token: access,
           refresh_token: refresh,
           obtained_at_ms: obtained,
           expires_at_ms: expires,
           revision: revision
         }}
    end
  end

  # Every change of a connection row goes through here and bumps its revision.
  defp update(b, tenant, c, changes) do
    c = Map.merge(c, changes)

    query(
      b,
      "UPDATE #{table(b, :connections)} SET scopes = $3, state = $4, access_token = $5, refresh_token = $6, obtained_at_ms = $7, expires_at_ms = $8, revision = revision + 1 WHERE tenant = $1 AND connection_id = $2",
      [
        tenant,
        c.connection_id,
        c.scopes,
        Atom.to_string(c.state),
        c.access_token,
        c.refresh_token,
        c.obtained_at_ms,
        c.expires_at_ms
      ]
    )

    %{c | revision: c.revision + 1}
  end

  defp public(c),
    do:
      Map.take(c, [:connection_id, :provider_id, :grant, :scopes, :state, :expires_at_ms, :revision])

  # ── shapes ──────────────────────────────────────────────────────────────

  defp checked(%__MODULE__{} = b), do: {:ok, b}
  defp checked(_other), do: {:error, :invalid}

  defp connect_shape(tenant, %{connection_id: id, provider_id: provider_id, scopes: scopes} = r)
       when map_size(r) == 3 do
    if text?(tenant, 128) and text?(id, 128) and provider_id?(provider_id) and scopes?(scopes),
      do: {:ok, id, provider_id, scopes},
      else: {:error, :invalid}
  end

  defp connect_shape(_tenant, _request), do: {:error, :invalid}

  defp id_shape(tenant, %{connection_id: id} = r) when map_size(r) == 1,
    do: if(text?(tenant, 128) and text?(id, 128), do: {:ok, id}, else: {:error, :invalid})

  defp id_shape(_tenant, _request), do: {:error, :invalid}

  defp callback_shape(tenant, %{state: state, code: code} = r) when map_size(r) == 2 do
    if text?(tenant, 128) and bytes?(state) and bytes?(code),
      do: {:ok, state, code},
      else: {:error, :invalid}
  end

  defp callback_shape(_tenant, _request), do: {:error, :invalid}

  defp bytes?(v), do: is_binary(v) and byte_size(v) in 1..2_048

  defp provider(b, provider_id) do
    case b.providers do
      %{^provider_id => p} -> {:ok, p}
      _ -> {:error, :unknown_provider}
    end
  end

  defp allowed(p, scopes),
    do: if(Enum.all?(scopes, &(&1 in p.scopes_allowed)), do: :ok, else: {:error, :scope})

  # ── plumbing ────────────────────────────────────────────────────────────

  # The trusted clock; an answer outside 0..2^53-1 is unavailable.
  defp now(b) do
    case call(b.clock) do
      n when is_integer(n) and n in 0..@max_now//1 -> {:ok, n}
      _ -> {:error, :unavailable}
    end
  end

  # A host Need: a raise, throw or exit is a failed answer.
  defp call(fun) do
    fun.()
  catch
    _kind, _reason -> :failed
  end

  # The Piece opens its own transaction and never joins a caller's.
  defp outside(b), do: if(b.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # One transaction under the tenant scope, after the READ COMMITTED check. `fun` returns
  # `{:ok, result}` to commit and return `result`, or `{:error, reason}` to roll back. A database
  # failure is :unavailable and says nothing about whether a write committed.
  defp run(b, tenant, opts \\ [], fun) do
    case TenantIsolation.transact(
           b.repo,
           %{tenant: tenant},
           fn ->
             with :ok <- isolation(b), do: fun.()
           end,
           opts
         ) do
      {:ok, result} -> result
      {:error, {:tenant_isolation, :in_transaction}} -> {:error, :in_transaction}
      {:error, reason} when reason in @errors -> {:error, reason}
      {:error, _other} -> {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp isolation(b) do
    case rows(b, "SELECT current_setting('transaction_isolation')", []) do
      [["read committed"]] -> :ok
      _ -> {:error, :isolation}
    end
  end

  defp table(b, :connections), do: ~s("#{b.prefix}".elzoo_oauth_connections)
  defp table(b, :attempts), do: ~s("#{b.prefix}".elzoo_oauth_attempts)

  defp query(b, sql, params), do: SQL.query!(b.repo, sql, params, log: false)
  defp rows(b, sql, params), do: query(b, sql, params).rows

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  # A proper list of at most n elements, without walking past n.
  defp within?([], _n), do: true
  defp within?([_ | rest], n) when n > 0, do: within?(rest, n - 1)
  defp within?(_list, _n), do: false

  # 1..max bytes of valid UTF-8 without a C0 or C1 control character.
  defp text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max//1 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_t), do: false
end
