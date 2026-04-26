defmodule Glorbo.Company.BudgetTracker do
  @moduledoc """
  Per-company budget gate + usage recorder (SEC-05).

  Responsibilities:

    * `check_budget/2` — pre-dispatch gate returning
      `:ok | {:alert, used, cap} | {:stop, used, cap}`. At the alert
      threshold (default 80%) a one-time-per-month alert file is written to
      `<base>/companies/<co>/alerts/<agent>-budget.md` and a `budget.alert`
      audit event is emitted. At the cap a `budget.hard_stop` audit event
      is emitted on every call (each denied dispatch gets a trail).
    * `record/3` — fire-and-forget (cast) recording of a usage report.
      Computes `cost_usd_cents` via `Glorbo.Budget.Ledger.compute_cost_cents/4`
      and calls `Ledger.record!/1` to upsert the monthly row. Emits
      `budget.usage` audit.
    * `reload_config/1` — clears the in-memory cap cache so the next
      `check_budget` re-reads caps via the dep-injected `budgets_fun`.

  **Pre-dispatch only (D-32):** mid-invocation kills are out of scope for
  v0.0.1. Once `Agent.Server` has seen `:ok` from `check_budget/2` the
  dispatch runs to completion even if the call pushes spending over cap.
  The next `check_budget` call will observe the overshoot and hard-stop
  subsequent dispatches.

  **Sole writer:** This GenServer is the only writer of the `budgets` table
  in production code paths (Plan 03-02 locked decision). Tests that need
  direct ledger access go through `Glorbo.Budget.Ledger.record!/1` which
  uses the same atomic upsert.

  **Statelessness invariant (D-45):** All durable state lives in the
  `budgets` SQLite table + alert files on disk. On crash the GenServer
  rebuilds caches lazily (`caps_cache` repopulates on first check;
  `alerts_fired` repopulates by scanning `alerts/` dir — implemented in
  handle_info({:rescan, _}) left for Plan 03-05 when AgentSupervisor wiring
  provides a startup hook. v0.0.1 accepts that after crash the first call
  per agent-month writes the alert file once more; the filesystem's
  File.write! is idempotent at content level so this is safe).
  """
  use GenServer
  require Logger

  alias Glorbo.Budget.Ledger
  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.Frontmatter

  @default_alert_threshold_pct 80

  @type budget_state ::
          :ok
          | {:alert, used_cents :: non_neg_integer(), cap_cents :: pos_integer()}
          | {:stop, used_cents :: non_neg_integer(), cap_cents :: pos_integer()}

  @type usage_record :: %{
          required(:agent_slug) => String.t(),
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:prompt_tokens) => non_neg_integer(),
          required(:completion_tokens) => non_neg_integer(),
          required(:task_id) => String.t()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Pre-dispatch budget gate. Returns `:ok` when the agent may dispatch,
  `{:alert, used, cap}` when over the alert threshold but under cap,
  or `{:stop, used, cap}` when at or over cap.
  """
  @spec check_budget(GenServer.server(), String.t()) :: budget_state()
  def check_budget(server, agent_slug) when is_binary(agent_slug) do
    GenServer.call(server, {:check_budget, agent_slug})
  end

  @doc """
  Record a usage observation. Fire-and-forget. Cost is computed from the
  LLM rate table via `Ledger.compute_cost_cents/4`.
  """
  @spec record(GenServer.server(), usage_record(), keyword()) :: :ok
  def record(server, %{} = usage, opts \\ []) do
    GenServer.cast(server, {:record, usage, opts})
  end

  @doc """
  Clear the in-memory caps cache. Next `check_budget/2` call re-invokes the
  dep-injected `budgets_fun` to read per-agent caps fresh from disk.
  """
  @spec reload_config(GenServer.server()) :: :ok
  def reload_config(server) do
    GenServer.call(server, :reload_config)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    alert_threshold_pct = Keyword.get(opts, :alert_threshold_pct, @default_alert_threshold_pct)
    repo = Keyword.get(opts, :repo, Glorbo.Repo)
    budgets_fun = Keyword.get(opts, :budgets_fun, &default_budgets_fun(company, base, &1))
    audit_fun = Keyword.get(opts, :audit_fun, &AuditLog.append/2)

    fs_fun =
      Keyword.get(opts, :fs_fun, %{
        write!: &File.write!/2,
        exists?: &File.exists?/1,
        mkdir_p!: &File.mkdir_p!/1
      })

    state = %{
      company: company,
      base: base,
      alert_threshold_pct: alert_threshold_pct,
      repo: repo,
      budgets_fun: budgets_fun,
      audit_fun: audit_fun,
      fs_fun: fs_fun,
      caps_cache: %{},
      alerts_fired: rehydrate_alerts_fired(company, base)
    }

    {:ok, state}
  end

  # Rehydrate `alerts_fired` by scanning `<base>/companies/<c>/alerts/*.md`
  # and parsing each file's frontmatter for agent + month. Without this,
  # a tracker restart would re-fire alerts that had already been emitted
  # in the current month, writing duplicate alert files
  # (TODO.md Important #7).
  defp rehydrate_alerts_fired(company, base) do
    alerts_dir = Path.join([base, "companies", company, "alerts"])

    case File.ls(alerts_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, "-budget.md"))
        |> Enum.reduce(MapSet.new(), fn name, acc ->
          path = Path.join(alerts_dir, name)

          case parse_alert_key(name, path) do
            {:ok, key} -> MapSet.put(acc, key)
            _ -> acc
          end
        end)

      _ ->
        MapSet.new()
    end
  end

  # Wave 34 (defense-in-depth): the canonical agent slug for the
  # alert key comes from the FILENAME (`<agent>-budget.md`), not from
  # the frontmatter. The writer puts both fields and they always match,
  # but on a hand-edited / operator-tampered alert file the frontmatter
  # could disagree with the filename. Trusting the frontmatter would
  # let an attacker write `editor-budget.md` with `agent: "ceo"` and
  # silently suppress ceo's real alerts (the MapSet would carry the
  # wrong key). The filename is the on-disk truth — same dirname-vs-
  # content discipline as waves 31-33 in the GEP-34 reindex paths.
  defp parse_alert_key(filename, path) do
    with agent when is_binary(agent) <- agent_from_alert_filename(filename),
         {:ok, contents} <- File.read(path),
         {:ok, meta, _body} <- Frontmatter.parse(contents),
         month when is_binary(month) <- meta["month"] do
      {:ok, {agent, month}}
    else
      _ -> :error
    end
  end

  defp agent_from_alert_filename(filename) do
    case String.split(filename, "-budget.md", parts: 2) do
      [agent, ""] when agent != "" -> agent
      _ -> nil
    end
  end

  @impl GenServer
  def handle_call({:check_budget, agent_slug}, _from, state) do
    {cap_cents, state} = lookup_cap(agent_slug, state)
    year_month = Ledger.month_bucket(DateTime.utc_now())
    used_cents = fetch_used(state.company, agent_slug, year_month)

    cond do
      is_nil(cap_cents) ->
        # No cap configured — treat as unlimited (D-32 default).
        {:reply, :ok, state}

      used_cents >= cap_cents ->
        emit_hard_stop(agent_slug, year_month, used_cents, cap_cents, state)
        {:reply, {:stop, used_cents, cap_cents}, state}

      used_cents * 100 >= cap_cents * state.alert_threshold_pct ->
        state = maybe_fire_alert(agent_slug, year_month, used_cents, cap_cents, state)
        {:reply, {:alert, used_cents, cap_cents}, state}

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:reload_config, _from, state) do
    {:reply, :ok, %{state | caps_cache: %{}}}
  end

  @impl GenServer
  def handle_cast({:record, usage, opts}, state) do
    safe_record(usage, opts, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp safe_record(usage, opts, state) do
    month = Keyword.get(opts, :month, Ledger.month_bucket(DateTime.utc_now()))

    cost_cents =
      Ledger.compute_cost_cents(
        usage.provider,
        usage.model,
        usage.prompt_tokens,
        usage.completion_tokens
      )

    _ =
      Ledger.record!(%{
        company_slug: state.company,
        agent_slug: usage.agent_slug,
        year_month: month,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        cost_usd_cents: cost_cents
      })

    emit_audit(state, %{
      action: "budget.usage",
      actor: usage.agent_slug,
      company: state.company,
      agent: usage.agent_slug,
      task_id: usage.task_id,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd_cents: cost_cents,
      model: usage.model
    })

    :ok
  rescue
    e ->
      Logger.error(
        "budget_tracker.record failed for #{inspect(usage[:agent_slug])}: #{Exception.message(e)} — usage dropped (best-effort recording)"
      )

      :error
  end

  defp lookup_cap(agent_slug, state) do
    case Map.fetch(state.caps_cache, agent_slug) do
      {:ok, cached} ->
        {cached, state}

      :error ->
        cap = state.budgets_fun.(agent_slug)
        {cap, %{state | caps_cache: Map.put(state.caps_cache, agent_slug, cap)}}
    end
  end

  defp fetch_used(company_slug, agent_slug, year_month) do
    case Ledger.fetch(company_slug, agent_slug, year_month) do
      nil -> 0
      row -> row.cost_usd_cents
    end
  end

  defp maybe_fire_alert(agent_slug, year_month, used_cents, cap_cents, state) do
    key = {agent_slug, year_month}

    if MapSet.member?(state.alerts_fired, key) do
      state
    else
      write_alert_file(agent_slug, year_month, used_cents, cap_cents, state)
      emit_alert_audit(agent_slug, year_month, used_cents, cap_cents, state)
      %{state | alerts_fired: MapSet.put(state.alerts_fired, key)}
    end
  end

  defp write_alert_file(agent_slug, year_month, used_cents, cap_cents, state) do
    # Threatmodel: agent_slug flows in from agent creation /
    # disk-driven recording paths and is otherwise unvalidated.
    # Path.join/1 doesn't normalize "..", so a slug like
    # "../../etc" would put the alert file outside the company
    # scope. Slug-validate at this seam; refuse the write if the
    # value isn't canonical.
    if Glorbo.Actions.Support.valid_slug?(agent_slug) do
      do_write_alert_file(agent_slug, year_month, used_cents, cap_cents, state)
    else
      Logger.warning(
        "budget_tracker: refusing alert write for non-slug agent=#{inspect(agent_slug)} (company=#{state.company})"
      )

      :ok
    end
  end

  defp do_write_alert_file(agent_slug, year_month, used_cents, cap_cents, state) do
    path =
      Path.join([
        state.base,
        "companies",
        state.company,
        "alerts",
        "#{agent_slug}-budget.md"
      ])

    dir = Path.dirname(path)
    state.fs_fun.mkdir_p!.(dir)

    used_usd = used_cents / 100.0
    cap_usd = cap_cents / 100.0
    pct = state.alert_threshold_pct

    content = """
    ---
    agent: "#{agent_slug}"
    month: "#{year_month}"
    used_usd: #{:erlang.float_to_binary(used_usd, decimals: 2)}
    cap_usd: #{:erlang.float_to_binary(cap_usd, decimals: 2)}
    threshold_pct: #{pct}
    created_at: "#{DateTime.utc_now() |> DateTime.to_iso8601()}"
    ---

    Budget alert — agent `#{agent_slug}` has crossed the #{pct}% threshold for
    #{year_month}. Used $#{:erlang.float_to_binary(used_usd, decimals: 2)} of
    $#{:erlang.float_to_binary(cap_usd, decimals: 2)}.
    """

    state.fs_fun.write!.(path, content)
    :ok
  end

  defp emit_alert_audit(agent_slug, year_month, used_cents, cap_cents, state) do
    pct = round(used_cents * 100 / cap_cents)

    emit_audit(state, %{
      action: "budget.alert",
      actor: "system",
      company: state.company,
      agent: agent_slug,
      year_month: year_month,
      used_cents: used_cents,
      cap_cents: cap_cents,
      pct: pct
    })
  end

  defp emit_hard_stop(agent_slug, year_month, used_cents, cap_cents, state) do
    emit_audit(state, %{
      action: "budget.hard_stop",
      actor: "system",
      company: state.company,
      agent: agent_slug,
      year_month: year_month,
      used_cents: used_cents,
      cap_cents: cap_cents,
      attempted_task: nil
    })
  end

  defp emit_audit(state, entry) do
    state.audit_fun.(state.company, entry)
    :ok
  rescue
    e ->
      Logger.error("budget_tracker audit emit failed: #{Exception.message(e)}")
      :error
  end

  # Default budgets_fun: read per-agent cap from
  # `<base>/companies/<co>/agents/<slug>/AGENT.md` frontmatter field
  # `budget.monthly_usd:` (legacy `budget_usd_cents_month:` still accepted).
  # Returns `nil` if the agent or field is missing.
  defp default_budgets_fun(company, base, agent_slug) do
    agent_dir = Path.join([base, "companies", company, "agents", agent_slug])
    path = Glorbo.Agent.FileLayout.agent_md(agent_dir)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Frontmatter.parse(content) do
      parse_cap_value(Map.get(meta, "budget"), Map.get(meta, "budget_usd_cents_month"))
    else
      _ -> nil
    end
  end

  defp parse_cap_value(budget, legacy) when is_map(budget) do
    case parse_budget_monthly_usd(Map.get(budget, "monthly_usd")) do
      nil -> parse_cap_value(nil, legacy)
      cents -> cents
    end
  end

  defp parse_cap_value(_budget, legacy) when is_integer(legacy) and legacy >= 0, do: legacy
  defp parse_cap_value(_budget, _legacy), do: nil

  defp parse_budget_monthly_usd(v) when is_integer(v) and v >= 0, do: v * 100
  defp parse_budget_monthly_usd(v) when is_float(v) and v >= 0, do: round(v * 100)

  defp parse_budget_monthly_usd(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {amount, ""} when amount >= 0 -> round(amount * 100)
      _ -> nil
    end
  end

  defp parse_budget_monthly_usd(_), do: nil
end
