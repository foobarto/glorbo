defmodule Glorbo.Company.Supervisor do
  @moduledoc """
  Per-company supervisor (AGT-01; D-44).

  Owns an 11- to 12-child supervision tree:

    1. `Glorbo.Company.AuditLog`       — append-only JSONL + SQLite mirror (Plan 2-01)
    2. `Glorbo.Filesystem.Watcher`     — inotify + PubSub broadcast (Plan 2-04 + 3-05)
    3. `Glorbo.Company.Router`         — permission-checked outbox routing (Plan 3-02)
    4. `Glorbo.Company.Scheduler`      — cron heartbeats (Plan 3-02; GEP-14)
    5. `Glorbo.Company.BudgetTracker`  — pre-dispatch USD gate (Plan 3-02)
    6. `Glorbo.Company.AgentSupervisor` — per-agent DynamicSupervisor (Plan 3-03)
    7. `Glorbo.Approvals.Gate`         — SEC-04 Director approval flow (GAP-5)
    8. `Glorbo.PathRequestGate`        — GEP-27 Agent sandbox path requests
    9. `Glorbo.Network.Proxy` (conditional) — HTTPS CONNECT allowlist for
       proxy agents (GAP-4; started iff at least one AGENT.md declares
       `network: proxy`).
   10. `Glorbo.Company.ProposalsSink`  — GEP-28 wave 2a audit event emitter
       for `proposals/*.md` writes.
   11. `Glorbo.Company.AgentBoot`      — one-shot enumerator that calls
       `AgentSupervisor.start_agent/2` and `Scheduler.register/3` for
       every on-disk agent; last so every dep is alive by the time it
       runs (gated by `config :glorbo, :auto_boot_agents`).

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
          | :task_scheduler
          | :budget_tracker
          | :dispatch_semaphore
          | :agent_sup
          | :agent_fleet
          | :network_proxy
          | :approvals_gate
          | :path_request_gate
          | :proposals_sink

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
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())

    base_children = [
      {Glorbo.Company.AuditLog, [name: via(company, :audit_log), company: company, base: base]},
      {Glorbo.Filesystem.Watcher,
       [name: via(company, :file_watcher), company: company, base: base]},
      {Glorbo.Company.Router, [name: via(company, :router), company: company, base: base]},
      {Glorbo.Company.Scheduler, [name: via(company, :scheduler), company: company, base: base]},
      {Glorbo.Company.TaskScheduler,
       [name: via(company, :task_scheduler), company: company, base: base]},
      {Glorbo.Company.BudgetTracker,
       [name: via(company, :budget_tracker), company: company, base: base]},
      # GEP-46: per-company concurrency cap. Reads
      # `max_concurrent_dispatches` from `company.md` at supervisor
      # boot; absence means `:unbounded` (today's behaviour).
      {Glorbo.Company.DispatchSemaphore,
       [
         name: via(company, :dispatch_semaphore),
         company: company,
         cap: read_dispatch_cap(company, base)
       ]},
      # AgentSupervisor + AgentBoot share a `:rest_for_one` sub-tree so
      # that if AgentSupervisor crashes, AgentBoot reruns and repopulates
      # the fleet. A bare `:one_for_one` at the company level + a
      # `:transient` one-shot AgentBoot would leave the company with
      # zero agents forever after a DynamicSupervisor crash.
      agent_fleet_spec(company, base)
    ]

    # GAP-4: start Glorbo.Network.Proxy when at least one agent declares
    # network: :proxy. Scanned from agent.md files on disk so the
    # decision tracks the filesystem source of truth (CLAUDE.md
    # invariant). `proxy?: true|false` in opts overrides the scan
    # for tests that want to assert a specific shape.
    #
    # GAP-5: Approvals.Gate always starts — its PubSub subscription is
    # the entry point for Director approval flow (SEC-04).
    children =
      base_children
      |> maybe_append_proxy(opts, company, base)
      |> append_gate(company, base)
      |> append_path_request_gate(company, base)
      |> append_proposals_sink(company, base)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Conditional Network.Proxy (GAP-4)
  # ---------------------------------------------------------------------------

  defp maybe_append_proxy(children, opts, company, base) do
    proxy? =
      Keyword.get_lazy(opts, :proxy?, fn -> company_has_proxy_agent?(company, base) end)

    if proxy? do
      children ++
        [
          {Glorbo.Network.Proxy,
           [
             name: via(company, :network_proxy),
             company: company,
             port: 0,
             # GEP-23 R19a (#283) — compose base allowlist + any
             # per-agent `network_allow:` frontmatter extensions at
             # proxy boot. Coarse-grained: proxy sees the union, so
             # any allowed host is reachable by any proxy agent
             # in the company. Per-requester gating is R19b.
             allowlist_fun: fn _co -> company_allowlist(company, base) end,
             # GEP-23 Phase 3 (#321) — smart-mode classifier. Built
             # once at supervisor boot from the company's agent
             # `egress:` blocks. Nil when no agent opts into
             # `mode: :smart` / `:strict` / `:deny` — keeps the
             # historic allowlist-only path bit-for-bit.
             classifier_fun: company_classifier_fun(company, base)
           ]}
        ]
    else
      children
    end
  end

  # Read every agent.md under the company and pick the first with
  # an egress block that requires a classifier (modes :strict or
  # :smart). Delegates to
  # `Glorbo.Network.SmartClassifier.smart_classify/3` with the
  # agent's egress config. Returns nil when no agent opts in —
  # which means the proxy stays in legacy allowlist-only mode.
  #
  # Coarse-grained on purpose: the proxy can't distinguish which
  # agent opened the connection (Phase 4 plumbs an ephemeral
  # per-dispatch token). So the first smart-mode agent's config
  # dictates classifier behaviour for the whole company. Directors
  # who want per-agent policies either stick to allow/deny lists
  # (which compose) or wait for Phase 4.
  defp company_classifier_fun(company, base) do
    case pick_smart_agent(company, base) do
      nil ->
        nil

      egress_config ->
        fn host, _port ->
          Glorbo.Network.SmartClassifier.smart_classify(host, egress_config)
        end
    end
  end

  defp pick_smart_agent(company, base) do
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Glorbo.Agent.FileLayout.agent_md(Path.join(agents_dir, &1)))
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&read_smart_egress/1)
        |> List.first()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Returns a single-element list when the agent opts into a mode
  # that needs a classifier; empty list otherwise. Flat-mapped
  # across all agents by pick_smart_agent/2.
  #
  # Threatmodel: agent.md files are agent-controlled. The boot scan
  # walks every one to decide whether to start the network proxy;
  # without a size guard, an agent with a 1 GB agent.md could OOM
  # the supervisor init. lstat-gate at @max_agent_md_bytes (256 KiB
  # — agent.md is YAML frontmatter + a system prompt; 256 KB is
  # already absurdly generous).
  @max_agent_md_bytes 262_144

  defp read_smart_egress(agent_md_path) do
    with :ok <- ensure_under_size(agent_md_path),
         {:ok, content} <- File.read(agent_md_path),
         {:ok, meta, _body} <- Glorbo.Filesystem.Frontmatter.parse(content),
         egress when is_map(egress) <- Map.get(meta, "egress"),
         mode <- to_string(Map.get(egress, "mode", "allow")),
         true <- mode in ["strict", "smart"] do
      [
        %{
          # Mode validated against a closed ["strict", "smart"]
          # list above. Hard-map to atoms so nothing relies on the
          # atom table being warm at compile time (to_existing_atom
          # can fail before the parser module has touched these
          # atoms in some boot orders).
          mode: mode_atom(mode),
          allow: list_or_empty(Map.get(egress, "allow")),
          deny: list_or_empty(Map.get(egress, "deny")),
          smart_allow: to_string(Map.get(egress, "smart_allow", "")),
          smart_deny: to_string(Map.get(egress, "smart_deny", "")),
          smart_model: Map.get(egress, "smart_model")
        }
      ]
    else
      _ -> []
    end
  end

  defp list_or_empty(nil), do: []
  defp list_or_empty(list) when is_list(list), do: Enum.map(list, &String.downcase/1)
  defp list_or_empty(_), do: []

  defp ensure_under_size(path) do
    case :file.read_link_info(path) do
      {:ok, info} ->
        case {elem(info, 2), elem(info, 1)} do
          {:regular, size} when size <= @max_agent_md_bytes -> :ok
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp mode_atom("strict"), do: :strict
  defp mode_atom("smart"), do: :smart

  defp company_allowlist(company, base) do
    agents_dir = Path.join([base, "companies", company, "agents"])
    base_hosts = Glorbo.Network.Proxy.default_allowlist()

    extra =
      case File.ls(agents_dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Glorbo.Agent.FileLayout.agent_md(Path.join(agents_dir, &1)))
          |> Enum.filter(&File.regular?/1)
          |> Enum.flat_map(&agent_network_allow_list/1)

        _ ->
          []
      end

    Enum.uniq(base_hosts ++ extra)
  rescue
    _ -> Glorbo.Network.Proxy.default_allowlist()
  end

  defp agent_network_allow_list(agent_md_path) do
    with :ok <- ensure_under_size(agent_md_path),
         {:ok, content} <- File.read(agent_md_path),
         {:ok, meta, _body} <- Glorbo.Filesystem.Frontmatter.parse(content),
         list when is_list(list) <- Map.get(meta, "network_allow") do
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&valid_hostname?/1)
    else
      _ -> []
    end
  end

  # Simple hostname validation — ASCII, no whitespace, no control
  # chars, no wildcards, no URL scheme. Rejects obvious garbage so
  # an agent with a typo doesn't pollute the allowlist.
  defp valid_hostname?(host) when is_binary(host) do
    Regex.match?(~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/, host)
  end

  defp valid_hostname?(_), do: false

  defp company_has_proxy_agent?(company, base) do
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Glorbo.Agent.FileLayout.agent_md(Path.join(agents_dir, &1)))
        |> Enum.filter(&File.regular?/1)
        |> Enum.any?(&agent_md_declares_proxy?/1)

      _ ->
        false
    end
  end

  # Fast-path: skim frontmatter for `network: proxy` via a substring
  # scan. Only full-parse if the skim says yes — avoids O(agents) YAML
  # parses on every company boot for the common case where no agent is
  # proxy (TODO.md Important #1).
  defp agent_md_declares_proxy?(agent_md_path) do
    case File.read(agent_md_path) do
      {:ok, content} ->
        if String.contains?(content, "proxy") do
          match?({:ok, %{network: :proxy}}, AgentParser.parse_file(agent_md_path))
        else
          false
        end

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Approvals.Gate (GAP-5)
  # ---------------------------------------------------------------------------

  defp append_gate(children, company, base) do
    # G1: point Gate at THIS company's AuditLog via tuple. Without this
    # it defaults to the bare module name `Glorbo.Company.AuditLog`
    # which is registered nowhere — so any time Gate tried to audit a
    # parse error it `GenServer.call`-ed a dead process, got :no_process
    # and the supervisor restarted Gate endlessly.
    children ++
      [
        {Glorbo.Approvals.Gate,
         [
           name: via(company, :approvals_gate),
           company: company,
           base: base,
           audit_server: via(company, :audit_log)
         ]}
      ]
  end

  # ---------------------------------------------------------------------------
  # PathRequestGate (GEP-27)
  # ---------------------------------------------------------------------------

  defp append_path_request_gate(children, company, base) do
    # Ensure the ETS grant store is initialized before the Gate starts.
    Glorbo.PathGrantStore.ensure_started()

    children ++
      [
        {Glorbo.PathRequestGate,
         [
           name: via(company, :path_request_gate),
           company: company,
           base: base,
           audit_server: via(company, :audit_log)
         ]}
      ]
  end

  # ---------------------------------------------------------------------------
  # ProposalsSink (GEP-28 wave 2a)
  # ---------------------------------------------------------------------------

  defp append_proposals_sink(children, company, base) do
    children ++
      [
        {Glorbo.Company.ProposalsSink,
         [
           name: via(company, :proposals_sink),
           company: company,
           base: base
         ]}
      ]
  end

  # ---------------------------------------------------------------------------
  # AgentBoot — one-shot enumerator that calls AgentSupervisor.start_agent
  # and Scheduler.register for each on-disk agent. Last in the children
  # list so every dependency (AgentSupervisor, Scheduler, AuditLog) is
  # alive by the time it runs.
  # ---------------------------------------------------------------------------

  # Sub-supervisor spec that owns AgentSupervisor + AgentBoot with
  # `:rest_for_one`. Ordering matters — AgentSupervisor first, AgentBoot
  # second — so that an AgentSupervisor crash terminates AgentBoot and
  # then restarts both. AgentBoot's `:transient` restart type means the
  # normal completion (one-shot enumerate + exit) never triggers a
  # spurious re-run; only the supervisor-driven crash-restart does.
  defp agent_fleet_spec(company, base) do
    children = [
      {Glorbo.Company.AgentSupervisor,
       [name: via(company, :agent_sup), company: company, base: base]},
      {Glorbo.Company.AgentBoot, [company: company, base: base]}
    ]

    %{
      id: {:agent_fleet, company},
      start:
        {Supervisor, :start_link,
         [children, [strategy: :rest_for_one, name: via(company, :agent_fleet)]]},
      type: :supervisor,
      restart: :permanent
    }
  end

  # GEP-46: read the `max_concurrent_dispatches` field from
  # `company.md` frontmatter. Absence (or any parse failure) yields
  # `:unbounded` so the semaphore stays out of the way for companies
  # that don't opt in.
  defp read_dispatch_cap(company, base) do
    path = Path.join([base, "companies", company, "company.md"])

    with {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Glorbo.Filesystem.Frontmatter.parse(content),
         n when is_integer(n) and n >= 1 <- Map.get(meta, "max_concurrent_dispatches") do
      min(n, 256)
    else
      _ -> :unbounded
    end
  rescue
    _ -> :unbounded
  end
end
