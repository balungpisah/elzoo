# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableMailbox do
  @moduledoc """
  Durable mail to an address and the continuation chain of the address's Runs, over a
  consumer-owned Ecto Repo on PostgreSQL 19, in the three tables that
  `Elzoo.DurableMailbox.Migration.install/1` creates under the `state/tenant-isolation` floor.

  `new/2` binds a Repo, a schema and a declaration of the accepted message names and their
  `core/payload-schema` schemas. `open/3` creates a chain and its first link; `put/3` accepts
  only declared mail whose payload passes its schema; `claim/3` gives the oldest pending
  message to the live tip, one at a time; `settle/3` records the result; `plan_rollover/3` and
  `rollover/3` close the tip and create exactly one successor; `chain/3` and `status/3` read.

  Errors are `{:error, reason}` with a fixed atom that never echoes an ID or a payload. The
  Piece emits no telemetry and no log; its queries pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableMailbox.Migration
  alias Elzoo.{PayloadSchema, TenantIsolation}

  @enforce_keys [:repo, :prefix, :identity, :max_pending, :messages]
  defstruct [:repo, :prefix, :identity, :max_pending, :messages]

  @max_int32 2_147_483_647
  @max_json 65_536
  @max_depth 32
  @sender_kinds [:human, :service, :agent]
  @reasons [:record_size, :unacknowledged, :invalid_input, :input_id_conflict]
  @passed [
    :isolation,
    :unknown_chain,
    :declaration_mismatch,
    :conflict,
    :mailbox_full,
    :identity_in_use,
    :unknown_link,
    :not_delivering,
    :not_tip,
    :delivery_unsettled,
    :already_rolled_over,
    :plan_mismatch,
    :unknown_message
  ]
  @terms Map.new(
           [:opened, :finished, :restarted, :live, :closed, :pending, :delivering, :consumed] ++
             [:refused, :human, :service, :agent | @reasons],
           &{Atom.to_string(&1), &1}
         )
  @link_columns "seq, run_id, unit_identity, predecessor_seq, pin, planned_pin, carry_kind, state, outcome, change_ref, stopped"
  @message_columns "message_id, sender_kind, sender_id, name, schema_version, payload, seq"

  @doc """
  A mailbox over `opts`, exactly `repo:` (a started Ecto Repo module) and `prefix:` (the schema
  of the installed tables), and a declaration `%{id, version, max_pending, messages}`:
  `{:ok, mailbox}` or `{:error, :invalid_declaration}`.
  """
  def new(opts, declaration) do
    with true <- options?(opts) and declaration?(declaration),
         {:ok, messages} <- build(declaration.messages) do
      {:ok,
       %__MODULE__{
         repo: opts[:repo],
         prefix: opts[:prefix],
         identity: identity(declaration),
         max_pending: declaration.max_pending,
         messages: messages
       }}
    else
      _ -> {:error, :invalid_declaration}
    end
  end

  @doc """
  `Elzoo.TenantIsolation.verify/3` for the chains, links and messages tables: `:ok` or
  `{:error, {table, reason}}` for the first failing one. Runs inside a caller's transaction too.
  """
  def verify(%__MODULE__{} = mailbox) do
    floor = [prefix: mailbox.prefix, tenant_column: "tenant", space_column: nil]

    Enum.zip([:chains, :links, :messages], Migration.tables())
    |> Enum.reduce_while(:ok, fn {name, table}, :ok ->
      case TenantIsolation.verify(mailbox.repo, {mailbox.prefix, table}, floor) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  @doc """
  Create the chain `chain_id` with the binding's declaration identity and its first link,
  `%{chain_id, run_id, unit_identity, pin, carry}`: `{:ok, :applied}`, `{:ok, :duplicate}`
  for an equal request under the same declaration, else `{:error, :conflict}`.
  """
  def open(mailbox, tenant, request) do
    with :ok <- shape(mailbox, tenant, open?(request)),
         {:ok, carry} <- json(request.carry),
         :ok <- free(mailbox) do
      write(mailbox, tenant, &open_chain(&1, &2, tenant, mailbox.identity, request, carry))
    end
  end

  @doc """
  Accept one message, `%{sender, address, message}`, as pending on the address's chain:
  `{:ok, :applied}` or `{:ok, :duplicate}`. Checks in the README order.
  """
  def put(mailbox, tenant, request) do
    with :ok <- shape(mailbox, tenant, put?(request)),
         {:ok, payload} <- json(request.message.payload),
         :ok <- declared(mailbox, request.message),
         :ok <- free(mailbox) do
      write(mailbox, tenant, &accept(&1, &2, tenant, mailbox, request, payload))
    end
  end

  @doc """
  Give the delivering message again, else `{:ok, :stopped}` for a stopped tip, else mark the
  oldest pending message delivering to the live tip: `{:ok, %{message, link_seq, run_id,
  unit_identity}}`, `{:ok, :stopped}` or `{:ok, :empty}`.
  """
  def claim(mailbox, tenant, request) do
    with :ok <- shape(mailbox, tenant, exact?(request, [:chain_id]) and text?(request.chain_id)),
         :ok <- free(mailbox) do
      write(mailbox, tenant, &claim_next(&1, &2, tenant, request.chain_id))
    end
  end

  @doc """
  Record the result of a delivery, `%{chain_id, message_id, link_seq, result}`:
  `{:ok, :applied}`, `{:ok, :duplicate}` or `{:error, :not_delivering}`.
  """
  def settle(mailbox, tenant, request) do
    with :ok <- shape(mailbox, tenant, settle?(request)),
         :ok <- free(mailbox) do
      write(mailbox, tenant, &settle_message(&1, &2, tenant, request))
    end
  end

  @doc """
  Record on the live tip the pin of its successor, `%{chain_id, link_seq, change}`:
  `{:ok, %{planned_pin, previous}}`.
  """
  def plan_rollover(mailbox, tenant, request) do
    valid? =
      exact?(request, [:chain_id, :change, :link_seq]) and text?(request.chain_id) and
        seq?(request.link_seq) and change?(request.change)

    with :ok <- shape(mailbox, tenant, valid?),
         :ok <- free(mailbox) do
      write(mailbox, tenant, &plan(&1, &2, tenant, request))
    end
  end

  @doc """
  Close the live tip with `outcome` and create its one successor, `%{chain_id, link_seq,
  outcome, successor, change}`: `{:ok, %{seq: successor_seq}}`.
  """
  def rollover(mailbox, tenant, request) do
    with :ok <- shape(mailbox, tenant, rollover?(request)),
         {:ok, carry} <- json(request.successor.carry),
         :ok <- free(mailbox) do
      write(mailbox, tenant, &roll(&1, &2, tenant, request, carry))
    end
  end

  @doc """
  The declaration identity, the links after `after_seq` (at most `limit`, oldest first,
  without their carry), whether more follow, and the tip with its carry:
  `%{chain_id, after_seq, limit}` gives `{:ok, %{declaration, links, more, tip}}`.
  """
  def chain(mailbox, tenant, request) do
    valid? =
      exact?(request, [:after_seq, :chain_id, :limit]) and text?(request.chain_id) and
        (request.after_seq == nil or seq?(request.after_seq)) and is_integer(request.limit) and
        request.limit in 1..256

    with :ok <- shape(mailbox, tenant, valid?),
         :ok <- free(mailbox) do
      scoped(mailbox, tenant, &chain_page(&1, &2, tenant, request))
    end
  end

  @doc """
  The state of one message, `%{chain_id, message_id}`: `{:ok, %{state, link_seq, reason}}` or
  `{:error, :unknown_message}`.
  """
  def status(mailbox, tenant, request) do
    valid? =
      exact?(request, [:chain_id, :message_id]) and text?(request.chain_id) and
        text?(request.message_id, 155)

    with :ok <- shape(mailbox, tenant, valid?),
         :ok <- free(mailbox) do
      scoped(mailbox, tenant, &message_status(&1, &2, tenant, request))
    end
  end

  # -- Transactions ---------------------------------------------------------------------------

  defp shape(mailbox, tenant, valid?) do
    if mailbox?(mailbox) and text?(tenant) and valid?, do: :ok, else: {:error, :invalid}
  end

  defp free(mailbox),
    do: if(mailbox.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # One tenant-scoped transaction whose first query refuses anything but READ COMMITTED.
  defp write(mailbox, tenant, fun) do
    scoped(mailbox, tenant, fn repo, t ->
      case query(repo, "SELECT current_setting('transaction_isolation')", []) do
        {:ok, %{rows: [["read committed"]]}} -> fun.(repo, t)
        {:ok, _} -> {:error, :isolation}
        {:error, _} -> {:error, :unavailable}
      end
    end)
  end

  defp scoped(%{repo: repo, prefix: prefix}, tenant, fun) do
    p = Migration.prefix!(prefix)

    t = %{
      chains: "#{p}.elzoo_mailbox_chains",
      links: "#{p}.elzoo_mailbox_links",
      messages: "#{p}.elzoo_mailbox_messages"
    }

    case TenantIsolation.transact(repo, %{tenant: tenant}, fn -> fun.(repo, t) end) do
      {:ok, _} = ok -> ok
      {:error, reason} when reason in @passed -> {:error, reason}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # The chain row lock: every write after open/3 takes it before it reads a link or a message.
  defp lock(repo, t, tenant, chain_id) do
    sql = """
    SELECT declaration_id, declaration_version, declaration_sha256, tip_seq, next_message_seq
    FROM #{t.chains} WHERE tenant = $1 AND chain_id = $2 FOR UPDATE
    """

    case query(repo, sql, [tenant, chain_id]) do
      {:ok, %{rows: [[id, version, sha, tip, next]]}} ->
        {:ok, %{identity: {id, version, sha}, tip: tip, next: next}}

      {:ok, %{rows: []}} ->
        {:error, :unknown_chain}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  # -- open/3 ---------------------------------------------------------------------------------

  # A concurrent open of the same chain_id waits on the key, then compares the stored bytes.
  defp open_chain(repo, t, tenant, {id, version, sha}, r, carry) do
    chain_sql = """
    INSERT INTO #{t.chains} (tenant, chain_id, declaration_id, declaration_version,
      declaration_sha256, tip_seq, next_message_seq)
    VALUES ($1, $2, $3, $4, $5, 1, 1)
    ON CONFLICT (tenant, chain_id) DO NOTHING
    """

    case query(repo, chain_sql, [tenant, r.chain_id, id, version, sha]) do
      {:ok, %{num_rows: 1}} ->
        first = %{run_id: r.run_id, unit_identity: r.unit_identity, carry_kind: "opened"}
        insert_link(repo, t, tenant, r.chain_id, 1, nil, r.pin, carry, nil, first)

      {:ok, %{num_rows: 0}} ->
        sql = """
        SELECT c.declaration_id, c.declaration_version, c.declaration_sha256,
               l.run_id, l.unit_identity, l.pin, l.carry
        FROM #{t.chains} c
        JOIN #{t.links} l ON l.tenant = c.tenant AND l.chain_id = c.chain_id AND l.seq = 1
        WHERE c.tenant = $1 AND c.chain_id = $2
        """

        expected = [id, version, sha, r.run_id, r.unit_identity, r.pin, carry]

        case query(repo, sql, [tenant, r.chain_id]) do
          {:ok, %{rows: [^expected]}} -> {:ok, :duplicate}
          {:ok, %{rows: [_]}} -> {:error, :conflict}
          _ -> {:error, :unavailable}
        end

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  # open/3 inserts with ON CONFLICT DO NOTHING: a run_id or unit_identity that a link of the
  # tenant holds (also one a concurrent open commits first) is :identity_in_use. rollover/3
  # checks first and inserts plainly, so a unique violation there is :unavailable.
  defp insert_link(repo, t, tenant, chain_id, seq, predecessor, pin, carry, change_ref, s) do
    on_conflict = if seq == 1, do: "ON CONFLICT DO NOTHING", else: ""

    sql = """
    INSERT INTO #{t.links} (tenant, chain_id, seq, run_id, unit_identity, predecessor_seq, pin,
      planned_pin, carry, carry_kind, state, outcome, change_ref, stopped)
    VALUES ($1, $2, $3, $4, $5, $6, $7, NULL, $8, $9, 'live', NULL, $10, false)
    #{on_conflict}
    """

    params = [
      tenant,
      chain_id,
      seq,
      s.run_id,
      s.unit_identity,
      predecessor,
      pin,
      carry,
      to_string(s.carry_kind),
      change_ref
    ]

    case query(repo, sql, params) do
      {:ok, %{num_rows: 1}} when seq == 1 -> {:ok, :applied}
      {:ok, %{num_rows: 1}} -> {:ok, %{seq: seq}}
      {:ok, %{num_rows: 0}} -> {:error, :identity_in_use}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # -- put/3 ----------------------------------------------------------------------------------

  # Steps 2-4: no query; the declaration is the binding's.
  defp declared(mailbox, message) do
    case Map.fetch(mailbox.messages, message.name) do
      :error ->
        {:error, :undeclared_name}

      {:ok, {version, port, checked}} ->
        cond do
          version != message.schema_version -> {:error, :schema_version}
          PayloadSchema.check(checked, port, message.payload) != :ok -> {:error, :invalid_payload}
          true -> :ok
        end
    end
  end

  # Steps 6-10.
  defp accept(repo, t, tenant, mailbox, r, payload) do
    %{sender: sender, message: m} = r

    with {:ok, chain_id} <- resolve(repo, t, tenant, r.address),
         {:ok, chain} <- lock(repo, t, tenant, chain_id),
         :ok <-
           if(chain.identity == mailbox.identity, do: :ok, else: {:error, :declaration_mismatch}),
         :absent <- stored(repo, t, tenant, chain_id, r, payload),
         :ok <- room(repo, t, tenant, chain_id, mailbox.max_pending) do
      insert_sql = """
      INSERT INTO #{t.messages} (tenant, chain_id, message_id, seq, sender_kind, sender_id, name,
        schema_version, payload, state, link_seq, reason)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'pending', NULL, NULL)
      """

      params = [
        tenant,
        chain_id,
        m.message_id,
        chain.next,
        Atom.to_string(sender.kind),
        sender.id,
        m.name,
        m.schema_version,
        payload
      ]

      next_sql =
        "UPDATE #{t.chains} SET next_message_seq = $3 WHERE tenant = $1 AND chain_id = $2"

      with {:ok, %{num_rows: 1}} <- query(repo, insert_sql, params),
           {:ok, %{num_rows: 1}} <- query(repo, next_sql, [tenant, chain_id, chain.next + 1]) do
        {:ok, :applied}
      else
        _ -> {:error, :unavailable}
      end
    end
  end

  # The one read before the chain row lock: links are never deleted and a run_id names one
  # link of a tenant, so the chain it names cannot change.
  defp resolve(_repo, _t, _tenant, {:chain, chain_id}), do: {:ok, chain_id}

  defp resolve(repo, t, tenant, {:run, run_id}) do
    sql = "SELECT chain_id FROM #{t.links} WHERE tenant = $1 AND run_id = $2"

    case query(repo, sql, [tenant, run_id]) do
      {:ok, %{rows: [[chain_id]]}} -> {:ok, chain_id}
      {:ok, %{rows: []}} -> {:error, :unknown_chain}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # The address is not compared: the same mail to the chain and to any of its Run IDs is one.
  defp stored(repo, t, tenant, chain_id, %{sender: s, message: m}, payload) do
    sql = """
    SELECT sender_kind, sender_id, name, schema_version, payload
    FROM #{t.messages} WHERE tenant = $1 AND chain_id = $2 AND message_id = $3
    """

    expected = [Atom.to_string(s.kind), s.id, m.name, m.schema_version, payload]

    case query(repo, sql, [tenant, chain_id, m.message_id]) do
      {:ok, %{rows: []}} -> :absent
      {:ok, %{rows: [^expected]}} -> {:ok, :duplicate}
      {:ok, %{rows: [_]}} -> {:error, :conflict}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp room(repo, t, tenant, chain_id, max_pending) do
    sql = """
    SELECT count(*) FROM (
      SELECT 1 FROM #{t.messages}
      WHERE tenant = $1 AND chain_id = $2 AND state IN ('pending', 'delivering') LIMIT $3
    ) open
    """

    case query(repo, sql, [tenant, chain_id, max_pending]) do
      {:ok, %{rows: [[n]]}} when n < max_pending -> :ok
      {:ok, %{rows: [[_]]}} -> {:error, :mailbox_full}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # -- claim/3 and settle/3 -------------------------------------------------------------------

  defp claim_next(repo, t, tenant, chain_id) do
    tip_sql =
      "SELECT run_id, unit_identity, stopped FROM #{t.links} WHERE tenant = $1 AND chain_id = $2 AND seq = $3"

    delivering_sql = """
    SELECT #{@message_columns} FROM #{t.messages}
    WHERE tenant = $1 AND chain_id = $2 AND state = 'delivering'
    """

    # The chain row lock serializes this with every other write of the chain.
    claim_sql = """
    UPDATE #{t.messages} SET state = 'delivering', link_seq = $3
    WHERE tenant = $1 AND chain_id = $2 AND seq = (
      SELECT seq FROM #{t.messages}
      WHERE tenant = $1 AND chain_id = $2 AND state = 'pending' ORDER BY seq LIMIT 1
    )
    RETURNING #{@message_columns}
    """

    with {:ok, %{tip: tip}} <- lock(repo, t, tenant, chain_id),
         {:ok, %{rows: [[run_id, unit, stopped]]}} <- query(repo, tip_sql, [tenant, chain_id, tip]),
         {:ok, %{rows: delivering}} <- query(repo, delivering_sql, [tenant, chain_id]) do
      claimed = fn row ->
        {:ok, %{message: message_term(row), link_seq: tip, run_id: run_id, unit_identity: unit}}
      end

      case delivering do
        [row] ->
          claimed.(row)

        [] when stopped ->
          {:ok, :stopped}

        [] ->
          case query(repo, claim_sql, [tenant, chain_id, tip]) do
            {:ok, %{rows: [row]}} -> claimed.(row)
            {:ok, %{rows: []}} -> {:ok, :empty}
            _ -> {:error, :unavailable}
          end

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  defp settle_message(repo, t, tenant, %{link_seq: link_seq, result: result} = r) do
    sql = """
    SELECT state, link_seq, reason FROM #{t.messages}
    WHERE tenant = $1 AND chain_id = $2 AND message_id = $3
    """

    with {:ok, _} <- lock(repo, t, tenant, r.chain_id),
         {:ok, %{rows: rows}} <- query(repo, sql, [tenant, r.chain_id, r.message_id]) do
      refused = fn reason -> {:refused, Map.fetch!(@terms, reason)} end

      case rows do
        [["consumed", ^link_seq, nil]] when result == :applied ->
          {:ok, :duplicate}

        [["refused", ^link_seq, reason]] when is_tuple(result) ->
          if refused.(reason) == result, do: {:ok, :duplicate}, else: {:error, :not_delivering}

        [["delivering", ^link_seq, nil]] ->
          finish(repo, t, tenant, r)

        _ ->
          {:error, :not_delivering}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  defp finish(repo, t, tenant, r) do
    {state, link_seq, reason} =
      case r.result do
        :applied -> {"consumed", r.link_seq, nil}
        :not_applied -> {"pending", nil, nil}
        {:refused, reason} -> {"refused", r.link_seq, Atom.to_string(reason)}
      end

    sql = """
    UPDATE #{t.messages} SET state = $4, link_seq = $5, reason = $6
    WHERE tenant = $1 AND chain_id = $2 AND message_id = $3
    """

    stop_sql =
      "UPDATE #{t.links} SET stopped = true WHERE tenant = $1 AND chain_id = $2 AND seq = $3"

    with {:ok, %{num_rows: 1}} <-
           query(repo, sql, [tenant, r.chain_id, r.message_id, state, link_seq, reason]),
         {:ok, %{num_rows: 1}} <-
           if(r.result == {:refused, :record_size},
             do: query(repo, stop_sql, [tenant, r.chain_id, r.link_seq]),
             else: {:ok, %{num_rows: 1}}
           ) do
      {:ok, :applied}
    else
      _ -> {:error, :unavailable}
    end
  end

  # -- plan_rollover/3 and rollover/3 ---------------------------------------------------------

  defp plan(repo, t, tenant, %{link_seq: link_seq, change: change} = r) do
    sql = """
    SELECT pin, planned_pin, state FROM #{t.links}
    WHERE tenant = $1 AND chain_id = $2 AND seq = $3
    """

    update_sql =
      "UPDATE #{t.links} SET planned_pin = $4 WHERE tenant = $1 AND chain_id = $2 AND seq = $3"

    with {:ok, _} <- lock(repo, t, tenant, r.chain_id),
         {:ok, [pin, previous, "live"]} <- one(query(repo, sql, [tenant, r.chain_id, link_seq])) do
      planned = if change, do: change.pin, else: pin

      case query(repo, update_sql, [tenant, r.chain_id, link_seq, planned]) do
        {:ok, %{num_rows: 1}} -> {:ok, %{planned_pin: planned, previous: previous}}
        _ -> {:error, :unavailable}
      end
    else
      {:ok, [_, _, "closed"]} -> {:error, :not_tip}
      {:error, reason} -> {:error, reason}
    end
  end

  # The atomic step, under the chain row lock, in the README order.
  defp roll(repo, t, tenant, %{link_seq: link_seq, successor: s, change: change} = r, carry) do
    link_sql = """
    SELECT pin, planned_pin, state, outcome FROM #{t.links}
    WHERE tenant = $1 AND chain_id = $2 AND seq = $3
    """

    with {:ok, _} <- lock(repo, t, tenant, r.chain_id),
         {:ok, [pin, planned, "live", nil]} <-
           one(query(repo, link_sql, [tenant, r.chain_id, link_seq])),
         :ok <- settled(repo, t, tenant, r.chain_id, link_seq),
         :ok <- if(planned == successor_pin(pin, change), do: :ok, else: {:error, :plan_mismatch}),
         :ok <- identity_free(repo, t, tenant, s) do
      close_sql = """
      UPDATE #{t.links} SET state = 'closed', outcome = $4
      WHERE tenant = $1 AND chain_id = $2 AND seq = $3
      """

      tip_sql = "UPDATE #{t.chains} SET tip_seq = $3 WHERE tenant = $1 AND chain_id = $2"
      next = link_seq + 1
      ref = change && change.ref

      with {:ok, %{num_rows: 1}} <-
             query(repo, close_sql, [tenant, r.chain_id, link_seq, r.outcome]),
           {:ok, %{seq: ^next}} <-
             insert_link(
               repo,
               t,
               tenant,
               r.chain_id,
               next,
               link_seq,
               successor_pin(pin, change),
               carry,
               ref,
               s
             ),
           {:ok, %{num_rows: 1}} <- query(repo, tip_sql, [tenant, r.chain_id, next]) do
        {:ok, %{seq: next}}
      else
        _ -> {:error, :unavailable}
      end
    else
      {:ok, [_, _, "closed", outcome]} -> rolled(repo, t, tenant, r, outcome, carry)
      {:error, reason} -> {:error, reason}
    end
  end

  defp successor_pin(pin, nil), do: pin
  defp successor_pin(_pin, change), do: change.pin

  # Step 2: the recorded successor with equal bytes of outcome, successor and change.
  defp rolled(repo, t, tenant, r, outcome, carry) do
    sql = """
    SELECT seq, run_id, unit_identity, pin, carry, carry_kind, change_ref FROM #{t.links}
    WHERE tenant = $1 AND chain_id = $2 AND predecessor_seq = $3
    """

    case one(query(repo, sql, [tenant, r.chain_id, r.link_seq])) do
      {:ok, [seq, run_id, unit, pin, stored_carry, kind, ref]} ->
        recorded = {outcome, run_id, unit, stored_carry, kind, ref && %{pin: pin, ref: ref}}

        requested =
          {r.outcome, r.successor.run_id, r.successor.unit_identity, carry,
           Atom.to_string(r.successor.carry_kind), r.change}

        if recorded == requested, do: {:ok, %{seq: seq}}, else: {:error, :already_rolled_over}

      _ ->
        {:error, :unavailable}
    end
  end

  # Step 3: a refused message does not block; only one delivering to the link does.
  defp settled(repo, t, tenant, chain_id, link_seq) do
    sql = """
    SELECT 1 FROM #{t.messages}
    WHERE tenant = $1 AND chain_id = $2 AND state = 'delivering' AND link_seq = $3
    """

    case query(repo, sql, [tenant, chain_id, link_seq]) do
      {:ok, %{rows: []}} -> :ok
      {:ok, %{rows: [_ | _]}} -> {:error, :delivery_unsettled}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp identity_free(repo, t, tenant, s) do
    sql = """
    SELECT 1 FROM #{t.links} WHERE tenant = $1 AND (run_id = $2 OR unit_identity = $3) LIMIT 1
    """

    case query(repo, sql, [tenant, s.run_id, s.unit_identity]) do
      {:ok, %{rows: []}} -> :ok
      {:ok, %{rows: [_]}} -> {:error, :identity_in_use}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp one({:ok, %{rows: [row]}}), do: {:ok, row}
  defp one({:ok, %{rows: []}}), do: {:error, :unknown_link}
  defp one(_), do: {:error, :unavailable}

  # -- chain/3 and status/3 -------------------------------------------------------------------

  # One statement, so the page and the tip come from one snapshot. Sequences are contiguous
  # from 1 (each successor is seq + 1 and links are never deleted), so the page after
  # after_seq is the range (after_seq, after_seq + limit].
  defp chain_page(repo, t, tenant, %{chain_id: chain_id, limit: limit} = r) do
    after_seq = r.after_seq || 0

    sql = """
    SELECT c.declaration_id, c.declaration_version, c.declaration_sha256, c.tip_seq,
           #{Enum.map_join(String.split(@link_columns, ", "), ", ", &("l." <> &1))},
           CASE WHEN l.seq = c.tip_seq THEN l.carry END
    FROM #{t.chains} c
    JOIN #{t.links} l ON l.tenant = c.tenant AND l.chain_id = c.chain_id
    WHERE c.tenant = $1 AND c.chain_id = $2
      AND ((l.seq > $3 AND l.seq <= $3::bigint + $4) OR l.seq = c.tip_seq)
    ORDER BY l.seq
    """

    case query(repo, sql, [tenant, chain_id, after_seq, limit]) do
      {:ok, %{rows: []}} ->
        {:error, :unknown_chain}

      {:ok, %{rows: [[id, version, sha, tip_seq | _] | _] = rows}} ->
        links = for [_, _, _, _ | link] <- rows, do: Enum.split(link, 11)
        {tip, [carry]} = Enum.find(links, fn {[seq | _], _} -> seq == tip_seq end)

        {:ok,
         %{
           declaration: {id, version, sha},
           links:
             for(
               {[seq | _] = link, _} <- links,
               seq > after_seq and seq <= after_seq + limit,
               do: link_term(link)
             ),
           more: tip_seq > after_seq + limit,
           tip: Map.put(link_term(tip), :carry, decode(carry))
         }}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp message_status(repo, t, tenant, r) do
    sql = """
    SELECT state, link_seq, reason FROM #{t.messages}
    WHERE tenant = $1 AND chain_id = $2 AND message_id = $3
    """

    case query(repo, sql, [tenant, r.chain_id, r.message_id]) do
      {:ok, %{rows: [[state, link_seq, reason]]}} ->
        {:ok,
         %{
           state: Map.fetch!(@terms, state),
           link_seq: link_seq,
           reason: reason && Map.fetch!(@terms, reason)
         }}

      {:ok, %{rows: []}} ->
        {:error, :unknown_message}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp link_term([
         seq,
         run_id,
         unit,
         predecessor,
         pin,
         planned,
         kind,
         state,
         outcome,
         ref,
         stopped
       ]) do
    %{
      seq: seq,
      run_id: run_id,
      unit_identity: unit,
      predecessor_seq: predecessor,
      pin: pin,
      planned_pin: planned,
      carry_kind: Map.fetch!(@terms, kind),
      state: Map.fetch!(@terms, state),
      outcome: outcome,
      change_ref: ref,
      stopped: stopped
    }
  end

  defp message_term([message_id, kind, sender_id, name, version, payload, seq]) do
    %{
      message_id: message_id,
      sender: %{kind: Map.fetch!(@terms, kind), id: sender_id},
      name: name,
      schema_version: version,
      payload: decode(payload),
      seq: seq
    }
  end

  defp query(repo, sql, params), do: SQL.query(repo, sql, params, log: false)

  # -- Declaration ----------------------------------------------------------------------------

  defp options?(opts) do
    Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:prefix, :repo] and
      repo?(opts[:repo]) and Migration.prefix?(opts[:prefix])
  end

  defp declaration?(d) do
    exact?(d, [:id, :max_pending, :messages, :version]) and name?(d.id) and int32?(d.version) and
      is_integer(d.max_pending) and d.max_pending in 1..65_536 and is_map(d.messages) and
      not is_struct(d.messages) and map_size(d.messages) in 1..64 and
      Enum.all?(d.messages, fn {name, spec} ->
        name?(name) and exact?(spec, [:schema, :schema_version]) and int32?(spec.schema_version)
      end)
  end

  defp build(messages) do
    Enum.reduce_while(messages, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      port = %{
        "id" => name,
        "direction" => "input",
        "schema_id" => name,
        "schema_version" => spec.schema_version
      }

      case PayloadSchema.build(port, spec.schema) do
        {:ok, checked} -> {:cont, {:ok, Map.put(acc, name, {spec.schema_version, port, checked})}}
        _ -> {:halt, :error}
      end
    end)
  end

  # SHA-256, lowercase hex, of the canonical JSON of the whole declaration (README).
  defp identity(d) do
    term = %{
      "id" => d.id,
      "version" => d.version,
      "max_pending" => d.max_pending,
      "messages" =>
        Map.new(d.messages, fn {name, spec} ->
          {name, %{"schema_version" => spec.schema_version, "schema" => spec.schema}}
        end)
    }

    {d.id, d.version, Base.encode16(:crypto.hash(:sha256, canonical(term)), case: :lower)}
  end

  # -- Request shapes -------------------------------------------------------------------------

  defp open?(r) do
    exact?(r, [:carry, :chain_id, :pin, :run_id, :unit_identity]) and text?(r.chain_id) and
      text?(r.run_id) and unit?(r.unit_identity) and text?(r.pin)
  end

  defp put?(r) do
    exact?(r, [:address, :message, :sender]) and sender?(r.sender) and address?(r.address) and
      exact?(r.message, [:message_id, :name, :payload, :schema_version]) and
      text?(r.message.message_id, 155) and is_binary(r.message.name) and
      is_integer(r.message.schema_version)
  end

  defp settle?(r) do
    exact?(r, [:chain_id, :link_seq, :message_id, :result]) and text?(r.chain_id) and
      text?(r.message_id, 155) and seq?(r.link_seq) and
      (r.result in [:applied, :not_applied] or
         (is_tuple(r.result) and tuple_size(r.result) == 2 and elem(r.result, 0) == :refused and
            elem(r.result, 1) in @reasons))
  end

  defp rollover?(r) do
    exact?(r, [:chain_id, :change, :link_seq, :outcome, :successor]) and text?(r.chain_id) and
      seq?(r.link_seq) and is_binary(r.outcome) and r.outcome =~ ~r/\A[a-z0-9_]{1,64}\z/ and
      change?(r.change) and exact?(r.successor, [:carry, :carry_kind, :run_id, :unit_identity]) and
      text?(r.successor.run_id) and unit?(r.successor.unit_identity) and
      r.successor.carry_kind in [:finished, :restarted]
  end

  defp sender?(s), do: exact?(s, [:id, :kind]) and s.kind in @sender_kinds and text?(s.id)

  defp address?({:chain, id}), do: text?(id)
  defp address?({:run, id}), do: text?(id)
  defp address?(_), do: false

  defp change?(nil), do: true
  defp change?(c), do: exact?(c, [:pin, :ref]) and text?(c.pin) and text?(c.ref, 256)

  defp exact?(map, keys),
    do: is_map(map) and not is_struct(map) and Enum.sort(Map.keys(map)) == keys

  defp mailbox?(%__MODULE__{repo: repo, prefix: prefix}),
    do: repo?(repo) and Migration.prefix?(prefix)

  defp mailbox?(_), do: false

  defp repo?(repo), do: is_atom(repo) and repo not in [nil, true, false]
  defp name?(n), do: is_binary(n) and n =~ ~r/\A[a-z0-9._-]{1,128}\z/
  defp int32?(n), do: is_integer(n) and n in 1..@max_int32
  defp seq?(n), do: int32?(n)

  defp text?(t, max \\ 128),
    do: is_binary(t) and byte_size(t) in 1..max and String.valid?(t) and printable?(t)

  # No C0 or C1 control character (U+0000-U+001F, U+007F-U+009F).
  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false

  defp unit?(u),
    do:
      is_binary(u) and byte_size(u) in 1..160 and String.valid?(u) and
        not String.contains?(u, <<0>>)

  # -- Canonical JSON -------------------------------------------------------------------------

  # A JSON term of at most 65,536 canonical bytes, as its canonical text; else :invalid.
  defp json(term) do
    with true <- json?(term, 0),
         text when byte_size(text) <= @max_json <- canonical(term) do
      {:ok, text}
    else
      _ -> {:error, :invalid}
    end
  end

  defp json?(v, depth) when is_map(v) and not is_struct(v),
    do:
      depth < @max_depth and
        Enum.all?(v, fn {k, x} -> is_binary(k) and String.valid?(k) and json?(x, depth + 1) end)

  defp json?(v, depth) when is_list(v), do: depth < @max_depth and elements?(v, depth + 1)
  defp json?(v, _) when is_binary(v), do: String.valid?(v)
  defp json?(v, _) when is_integer(v) or is_float(v) or v in [nil, true, false], do: true
  defp json?(_, _), do: false

  defp elements?([], _), do: true
  defp elements?([h | rest], depth), do: json?(h, depth) and elements?(rest, depth)
  defp elements?(_, _), do: false

  # OTP's :json decoder keeps integers of any length (Jason 1.4.5 refuses more than 1,024
  # digits, which a stored term may hold within 65,536 bytes); null is nil.
  defp decode(text) do
    {term, :ok, ""} = :json.decode(text, :ok, %{null: nil})
    term
  end

  # Compact Jason 1.4 encoding with the keys of every object sorted by their bytes.
  defp canonical(term), do: Jason.encode!(ordered(term))

  defp ordered(map) when is_map(map),
    do:
      map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, ordered(v)} end) |> Jason.OrderedObject.new()

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
