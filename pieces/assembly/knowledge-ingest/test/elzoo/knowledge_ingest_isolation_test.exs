# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/knowledge_ingest_test_helper.exs", __DIR__)

defmodule Elzoo.KnowledgeIngestIsolationTest do
  # Group 8 of the task Contract: the Piece and its Oban instance run on a Repo whose every
  # connection SET ROLEs to the ELZ-285 application role (ELZOO_TEST_APP_ROLE; the test fails,
  # not skips, without it or when it bypasses row security), with only the README grants.
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Elzoo.KnowledgeIngest.Cases
  alias Elzoo.KnowledgeIngest, as: KI
  alias Elzoo.KnowledgeIngest.{AppRepo, Harness, Script, TestRepo}
  alias Elzoo.TenantIsolation

  setup_all do
    ap = Harness.module_setup!()
    role = Harness.app_role!()
    Harness.start!(AppRepo, pool_size: 6, after_connect: {Harness, :connect, [role, []]})

    # every application connection is the non-owner role that does not bypass row security
    assert [[^role, false, false]] =
             Harness.query!(
               AppRepo,
               "SELECT current_user, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
             ).rows

    %{ap: ap, role: role}
  end

  # The README grants for the application role, on the env's schema.
  defp grant!(p, role) do
    q = fn sql -> Harness.query!(TestRepo, sql) end
    q.(~s(GRANT USAGE ON SCHEMA "#{p}" TO "#{role}"))

    q.(
      ~s(GRANT SELECT, INSERT, UPDATE ON "#{p}".elzoo_knowledge_ingests, "#{p}".elzoo_knowledge_batches, "#{p}".elzoo_knowledge_attempts TO "#{role}")
    )

    q.(~s(GRANT SELECT, INSERT, UPDATE, DELETE ON "#{p}".elzoo_knowledge_chunks TO "#{role}"))
    q.(~s(GRANT SELECT, INSERT, UPDATE, DELETE ON "#{p}".oban_jobs TO "#{role}"))
    q.(~s(GRANT USAGE ON SEQUENCE "#{p}".oban_jobs_id_seq TO "#{role}"))
  end

  test "8 under the floor a T1 scope sees no T2 row and cannot write one", ctx do
    env = env(ctx, intent: Harness.memory_intent())
    grant!(env.p, ctx.role)
    name = :"ki_app_oban_#{env.p}"
    pid = Harness.oban!(name, env.p, repo: AppRepo)
    on_exit(fn -> Harness.stop_oban(pid) end)
    {:ok, c} = Harness.config(env, repo: AppRepo, oban: name)
    Harness.register(env, c)
    env = %{env | c: c, oban: name}
    assert :ok = KI.verify(c)

    [t1, t2] = [tenant(), tenant()]
    r1 = submit!(env, t1, doc(env, t1, "tenant one"))
    r2 = submit!(env, t2, doc(env, t2, "tenant two"))
    Harness.drain(env)
    assert %{state: :indexed} = status(env, t1, r1)
    assert %{state: :indexed} = status(env, t2, r2)
    # a failed T2 ingest keeps its staged chunk
    r3 = submit!(env, t2, doc(env, t2, "tenant two again", source_ref: "kept"))
    Script.script(env.script, [{:status, :permission_denied}])
    Harness.drain(env)
    assert %{state: :failed} = status(env, t2, r3)

    # without a tenant filter, T1's scope sees only its own rows
    for table <- ~w(elzoo_knowledge_ingests elzoo_knowledge_batches elzoo_knowledge_attempts) do
      assert [[t1]] ==
               Harness.scoped_as!(
                 AppRepo,
                 t1,
                 ~s[SELECT DISTINCT tenant FROM "#{env.p}".#{table} WHERE $1::text IS NOT NULL],
                 []
               )
    end

    assert [] ==
             Harness.scoped_as!(
               AppRepo,
               t1,
               ~s[SELECT tenant FROM "#{env.p}".elzoo_knowledge_chunks WHERE $1::text IS NOT NULL],
               []
             )

    assert [[1]] ==
             Harness.scoped_as!(
               AppRepo,
               t2,
               ~s[SELECT count(*) FROM "#{env.p}".elzoo_knowledge_chunks WHERE tenant = $1],
               []
             )

    # a direct T2 write from T1's scope is refused 42501
    error =
      assert_raise Postgrex.Error, fn ->
        TenantIsolation.transact(AppRepo, %{tenant: t1}, fn ->
          Harness.query!(
            AppRepo,
            ~s[INSERT INTO "#{env.p}".elzoo_knowledge_chunks (tenant, ingest_id, chunk_index, start_byte, end_byte, content, content_digest) VALUES ($1, 'x', 0, 0, 1, 'a', 'd')],
            [t2]
          )

          {:ok, :written}
        end)
      end

    assert error.postgres.code == :insufficient_privilege

    # the operations of T1 on T2's ingest
    for f <- [&KI.status/3, &KI.cancel/3, &KI.resubmit/3],
        do: assert({:error, :not_found} = f.(c, caller(t1), key(r3)))

    # a table whose floor was dropped
    Harness.query!(
      TestRepo,
      ~s(DROP POLICY elzoo_tenant_floor ON "#{env.p}".elzoo_knowledge_chunks)
    )

    assert {:error, :floor_missing} = KI.verify(c)
  end
end
