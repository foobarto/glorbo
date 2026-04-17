defmodule Glorbo.Company.Supervisor do
  @moduledoc """
  Per-company supervisor (AGT-01; D-44).

  Owns a 7- or 8-child supervision tree (expanded from Phase 2's 2-child
  shape by Plan 03-05 + the GAP-closure work):

    1. `Glorbo.Company.AuditLog`       — append-only JSONL + SQLite mirror (Plan 2-01)
    2. `Glorbo.Filesystem.Watcher`     — inotify + PubSub broadcast (Plan 2-04 + 3-05)
    3. `Glorbo.Company.Router`         — permission-checked outbox routing (Plan 3-02)
    4. `Glorbo.Company.Scheduler`      — cron heartbeats (Plan 3-02)
    5. `Glorbo.Company.BudgetTracker`  — pre-dispatch USD gate (Plan 3-02)
    6. `Glorbo.Company.AgentSupervisor` — per-agent DynamicSupervisor (Plan 3-03)
    7. `Glorbo.Approvals.Gate`         — SEC-04 Director approval flow (GAP-5)
    8. `Glorbo.Network.Proxy` (conditional) — HTTPS CONNECT allowlist for
       api-only agents (GAP-4; started iff at least one agent.md declares
       `network: api-only`).

  Strategy: `:one_for_one` — killing any single child restarts only that
  child. Kill this supervisor → only this company's children restart;
  other companies + the dashboard are unaffected.

  ## Cross-child state recovery (D-45)

    * **Router crash:** Watcher re-emits recent outbox events when Router
      re-subscribes to `company:<co>:outbox` on restart.
    * **BudgetTracker crash:** rebuilds cap cache lazily; SQLite `budgets`
      rows are authoritative; alert file idempotency accepts one duplicate
      write per agent-month after crash (File.write! is content-idempotent).
    * **Scheduler crash:** heartbeats re-registered by AgentSupervisor's
      per-agent startup hooks.
    * **AgentSupervisor crash:** per-agent sub-trees are transient children
      — they do NOT auto-restart on AgentSupervisor restart. The next
      company boot re-starts them from agent.md files.

  ## Boot-order invariants

    1. AuditLog first — every subsequent child's audit emits go here.
    2. Watcher second — Router + Gate subscribe to its PubSub broadcasts.
    3. Router, Scheduler, BudgetTracker in parallel (no direct deps).
    4. AgentSupervisor last — children may call Router.route/2 etc during
       their own startup.
  """
  use Supervisor

  alias Glorbo.Agent.Parser, as: AgentParser

  @typedoc """
  Roles registered under `Glorbo.Agent.Registry` by a per-company tree.
  Compile-time atoms — never derived from user input (GEP-12 / T-03-15).
  """
  @type role ::
          :audit_log
          | :file_watcher
          | :router
          | :scheduler
          | :budget_tracker
          | :agent_sup
          | :network_proxy
          | :approvals_gate

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  `:via` tuple for a named per-company child process. Key is
  `{:company_child, company_slug, role}` — see GEP-12 for the rule.

  Use this from tests or operator-tools that need to send messages to
  a specific company's Router, AuditLog, etc., instead of guessing
  at a registered-name atom.
  """
  @spec via(String.t(), role()) ::
          {:via, Registry, {module(), {:company_child, String.t(), role()}}}
  def via(company, role) when is_binary(company) and is_atom(role) do
    {:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, role}}}
  end

  @impl Supervisor
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))

    base_children = [
      {Glorbo.Company.AuditLog, [name: via(company, :audit_log), company: company, base: base]},
      {Glorbo.Filesystem.Watcher,
       [name: via(company, :file_watcher), company: company, base: base]},
      {Glorbo.Company.Router, [name: via(company, :router), company: company, base: base]},
      {Glorbo.Company.Scheduler, [name: via(company, :scheduler), company: company, base: base]},
      {Glorbo.Company.BudgetTracker,
       [name: via(company, :budget_tracker), company: company, base: base]},
      {Glorbo.Company.AgentSupervisor,
       [name: via(company, :agent_sup), company: company, base: base]}
    ]

    # GAP-4: start Glorbo.Network.Proxy when at least one agent declares
    # network: :api_only. Scanned from agent.md files on disk so the
    # decision tracks the filesystem source of truth (CLAUDE.md
    # invariant). `api_only?: true|false` in opts overrides the scan
    # for tests that want to assert a specific shape.
    #
    # GAP-5: Approvals.Gate always starts — its PubSub subscription is
    # the entry point for Director approval flow (SEC-04).
    children =
      base_children
      |> maybe_append_proxy(opts, company, base)
      |> append_gate(company, base)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Conditional Network.Proxy (GAP-4)
  # ---------------------------------------------------------------------------

  defp maybe_append_proxy(children, opts, company, base) do
    api_only? =
      Keyword.get_lazy(opts, :api_only?, fn -> company_has_api_only_agent?(company, base) end)

    if api_only? do
      children ++
        [
          {Glorbo.Network.Proxy, [name: via(company, :network_proxy), company: company, port: 0]}
        ]
    else
      children
    end
  end

  defp company_has_api_only_agent?(company, base) do
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join([agents_dir, &1, "agent.md"]))
        |> Enum.filter(&File.regular?/1)
        |> Enum.any?(&agent_md_declares_api_only?/1)

      _ ->
        false
    end
  end

  defp agent_md_declares_api_only?(agent_md_path) do
    case AgentParser.parse_file(agent_md_path) do
      {:ok, %{network: :api_only}} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Approvals.Gate (GAP-5)
  # ---------------------------------------------------------------------------

  defp append_gate(children, company, base) do
    children ++
      [
        {Glorbo.Approvals.Gate,
         [name: via(company, :approvals_gate), company: company, base: base]}
      ]
  end
end
