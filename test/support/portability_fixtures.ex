defmodule Glorbo.Test.PortabilityFixtures do
  @moduledoc """
  Source/target host stagers for Phase-5 portability + backup/restore tests.

  `write_minimal_company/3` seeds a single-company tree into `base` so
  `Glorbo.Backup.run(base: base)` produces a non-empty archive.

  `stage_host/1` provisions an ephemeral per-test tmp root that is
  recursively cleaned up on exit.

  Shape follows RESEARCH.md §Pattern 6 (portability test blueprint).
  """

  @doc """
  Seed a minimal `~/.glorbo/`-shaped tree at `base` containing:

    * `config.md` with a deterministic `erl_cookie:` so backup is
      cookie-stable across host A → B.
    * `companies/<company>/{company.md,agents/<agent>/{inbox,outbox,
      workspace,history,state,stdout.log,AGENT.md},audit/<YYYY-MM>.jsonl}`
    * `audit/_system/<YYYY-MM>.jsonl` (system-scope audit)
    * `run/` (empty — will hold glorbo.pid post-up)
    * `glorbo.db` (empty file — tests that exercise the real Repo start
      it with a per-test database path).
  """
  @spec write_minimal_company(Path.t(), String.t(), String.t()) :: :ok
  def write_minimal_company(base, company, agent) do
    File.mkdir_p!(Path.join(base, "audit/_system"))
    File.mkdir_p!(Path.join(base, "run"))

    File.write!(Path.join(base, "config.md"), """
    ---
    secret_key_base: #{:crypto.strong_rand_bytes(64) |> Base.encode64()}
    dashboard_token: null
    erl_cookie: portability_test_cookie_24byte_fixed
    host: "127.0.0.1"
    port: 4000
    ---

    # Glorbo configuration — portability fixture
    """)

    File.chmod!(Path.join(base, "config.md"), 0o600)

    co_path = Path.join([base, "companies", company])
    File.mkdir_p!(Path.join(co_path, "audit"))
    File.write!(Path.join(co_path, "company.md"), "---\nname: #{company}\n---\n\n# #{company}\n")

    ag_path = Path.join([co_path, "agents", agent])
    Enum.each(~w(inbox outbox workspace history state), &File.mkdir_p!(Path.join(ag_path, &1)))
    File.write!(Path.join(ag_path, "stdout.log"), "")

    File.write!(Path.join(ag_path, "AGENT.md"), """
    ---
    name: #{String.upcase(agent)}
    slug: #{agent}
    role: "Portability test agent"
    provider: claude-code
    model: claude-sonnet-4-5
    network: none
    permissions: []
    budget:
      monthly_usd: 10.00
    skills: []
    ---

    # #{agent}
    Portability fixture agent.
    """)

    now = DateTime.utc_now() |> DateTime.to_iso8601()
    month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")

    File.write!(
      Path.join([co_path, "audit", month <> ".jsonl"]),
      Jason.encode!(%{
        ts: now,
        actor: "system",
        action: "company.create",
        target: company,
        detail: %{}
      }) <> "\n"
    )

    File.write!(
      Path.join([base, "audit/_system", month <> ".jsonl"]),
      Jason.encode!(%{
        ts: now,
        actor: "system",
        action: "init.complete",
        target: "_system",
        detail: %{}
      }) <> "\n"
    )

    # Minimal glorbo.db — a non-empty SQLite file so checkpoint has
    # something to operate on. Tests that exercise the real Repo start
    # it with a per-test database path.
    File.touch!(Path.join(base, "glorbo.db"))

    :ok
  end

  @doc """
  Provision an ephemeral tmp root under `System.tmp_dir!()` with label
  `:a` or `:b` (matches the A → B portability blueprint naming).
  """
  @spec stage_host(atom()) :: Path.t()
  def stage_host(label) when label in [:a, :b] do
    path =
      Path.join(
        System.tmp_dir!(),
        "glorbo-port#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
