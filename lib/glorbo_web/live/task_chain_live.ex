defmodule GlorboWeb.TaskChainLive do
  @moduledoc """
  GEP-40 chain audit view — GET
  `/companies/:company/tasks/:task_id/chain`.

  Renders the task's `handoff_chain:` (structured) alongside the
  reconciled `task.reassign` audit events (free-form in JSONL).
  The two sources should agree — when they don't, the view shows
  a `chain drift` warning so a director or provenance-auditor
  can investigate.

  Peer-review audit events (`peer_review.requested` emitted by
  `Glorbo.Approvals.Gate`, and `task.peer_review.<verdict>`
  emitted by the reviewer's verdict-land path) render in a
  separate `<details>` section below the reassign cross-
  reference — so directors can see the full review lifecycle
  without leaving the chain view (GEP-41 rollout item 6).

  Pure read view; no actions. Link from the main task-detail
  page's header.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  @impl true
  def mount(%{"company" => co, "task_id" => task_id}, _session, socket) do
    cond do
      not Glorbo.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not valid_task_id?(task_id) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid task identifier.")
         |> push_navigate(to: ~p"/companies/#{co}")}

      true ->
        mount_valid(co, task_id, socket)
    end
  end

  defp mount_valid(co, task_id, socket) do
    base = base_dir()
    co_path = Path.join([base, "companies", co])

    with true <- File.dir?(co_path),
         {:ok, project} <- derive_project(task_id),
         {:ok, rel_path, abs_path} <- resolve_task_file(co_path, project, task_id),
         {:ok, task} <- Glorbo.TaskDefinition.parse_file(abs_path, base: base, company: co) do
      audits = Glorbo.Audit.Query.for_task(base, co, rel_path, limit: 100)
      reassigns = Enum.filter(audits, &(&1["action"] == "task.reassign"))
      peer_review = Enum.filter(audits, &peer_review_audit?/1)

      {:ok,
       socket
       |> assign(:page_title, "#{task_id} chain — #{co} — Glorbo")
       |> assign(:sidebar_active, :kanban)
       |> assign(:current_company, co)
       |> assign(:company_slug, co)
       |> assign(:task_id, task_id)
       |> assign(:rel_path, rel_path)
       |> assign(:project, project)
       |> assign(:task, task)
       |> assign(:chain, Enum.with_index(task.handoff_chain))
       |> assign(:audit_reassigns, reassigns)
       |> assign(:audit_peer_review, peer_review)
       |> assign(:drift, compute_drift(task.handoff_chain, reassigns))}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Task \"#{task_id}\" not found.")
         |> push_navigate(to: ~p"/companies/#{co}/kanban")}
    end
  end

  defp valid_task_id?(tid) when is_binary(tid),
    do: Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, tid) and byte_size(tid) <= 128

  defp valid_task_id?(_), do: false

  defp derive_project(task_id) do
    case Regex.run(~r/\A([a-z][a-z0-9_-]*?)-(\d+)\z/, task_id) do
      [_whole, project, _num] -> {:ok, project}
      _ -> :error
    end
  end

  defp resolve_task_file(co_path, project, task_id) do
    path = Path.join([co_path, "projects", project, "tasks", "#{task_id}.md"])

    if File.regular?(path) do
      rel = "projects/#{project}/tasks/#{task_id}.md"
      {:ok, rel, path}
    else
      :error
    end
  end

  # Drift detection: compare the number of chain entries against
  # the number of reassign audit events. If the audit log has more
  # reassigns than the chain, something silently truncated the
  # chain (hand-edit, pre-Round-G write path). If the chain has
  # more entries than the audit log, the audit log was likely
  # truncated or a prior write missed the audit emit.
  defp compute_drift(chain, reassigns) do
    chain_len = length(chain)
    audit_len = length(reassigns)

    cond do
      chain_len == audit_len -> nil
      chain_len < audit_len -> {:missing_chain_entries, audit_len - chain_len}
      chain_len > audit_len -> {:missing_audit_entries, chain_len - audit_len}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-task-chain">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">chain /</span> {@task_id}
          </h1>
          <p class="gl-muted">
            handoff history · {length(@chain)} step{if length(@chain) == 1, do: "", else: "s"}
          </p>
        </div>
        <div class="gl-overview__actions">
          <.link
            navigate={~p"/companies/#{@company_slug}/tasks/#{@task_id}"}
            class="gl-btn"
          >
            ← task detail
          </.link>
        </div>
      </header>

      <aside :if={@drift} class="gl-task-chain__drift" role="alert">
        <strong>chain drift</strong>
        · {drift_copy(@drift)}
        <p class="gl-muted">
          The task's <code>handoff_chain:</code>
          frontmatter and the <code>task.reassign</code>
          audit events disagree. Compare
          below to find the gap.
        </p>
      </aside>

      <section class="gl-task-chain__body">
        <div :if={@task.requested_by} class="gl-task-chain__requested-by">
          <span class="gl-muted">requested by</span>
          <strong>{@task.requested_by}</strong>
        </div>

        <ol :if={@chain != []} class="gl-task-chain__list">
          <li :for={{entry, idx} <- @chain} class="gl-task-chain__entry">
            <div class="gl-task-chain__entry-head">
              <span class="gl-task-chain__step">#{idx + 1}</span>
              <strong class="gl-task-chain__from">{entry_value(entry, :from)}</strong>
              <span class="gl-muted" aria-hidden="true">→</span>
              <strong class="gl-task-chain__to">{entry_value(entry, :to)}</strong>
              <span class="gl-muted gl-task-chain__ts">{entry_value(entry, :ts)}</span>
            </div>
            <p class="gl-task-chain__reason">{entry_value(entry, :reason)}</p>
          </li>
        </ol>

        <p :if={@chain == []} class="gl-muted gl-task-chain__empty">
          No handoffs recorded. The task has stayed with its initial
          assignee since creation.
        </p>
      </section>

      <details :if={@audit_reassigns != []} class="gl-task-chain__audit">
        <summary>
          audit cross-reference · {length(@audit_reassigns)} reassign
          event{if length(@audit_reassigns) == 1, do: "", else: "s"}
        </summary>
        <ol class="gl-task-chain__audit-list">
          <li :for={e <- @audit_reassigns} class="gl-task-chain__audit-entry">
            <span class="gl-muted">{e["ts"]}</span> · <strong>{reassign_from(e)}</strong>
            <span aria-hidden="true">→</span>
            <strong>{reassign_to(e)}</strong> · <span class="gl-muted">by {e["actor"]}</span>
          </li>
        </ol>
      </details>

      <details :if={@audit_peer_review != []} class="gl-task-chain__peer-review">
        <summary>
          peer review · {length(@audit_peer_review)} event{if length(@audit_peer_review) == 1,
            do: "",
            else: "s"}
        </summary>
        <ol class="gl-task-chain__peer-review-list">
          <li :for={e <- @audit_peer_review} class="gl-task-chain__peer-review-entry">
            <span class="gl-muted">{e["ts"]}</span>
            ·
            <strong class="gl-task-chain__peer-review-action">
              {peer_review_label(e["action"])}
            </strong>
            <span :if={peer_review_detail(e) != ""} class="gl-task-chain__peer-review-detail">
              — {peer_review_detail(e)}
            </span>
            <span :if={e["actor"]} class="gl-muted">· by {e["actor"]}</span>
          </li>
        </ol>
      </details>
    </section>
    """
  end

  defp entry_value(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key)) || ""
  end

  defp drift_copy({:missing_chain_entries, n}),
    do: "audit log shows #{n} extra reassign#{if n == 1, do: "", else: "s"} not in chain"

  defp drift_copy({:missing_audit_entries, n}),
    do: "chain has #{n} entr#{if n == 1, do: "y", else: "ies"} not in audit log"

  # GEP-41 rollout item 6: surface peer-review activity in the chain view.
  # `peer_review.requested` comes from Approvals.Gate; the task.peer_review.*
  # family comes from the verdict-land path in Actions.Tasks.
  defp peer_review_audit?(%{"action" => "peer_review.requested"}), do: true

  defp peer_review_audit?(%{"action" => "task.peer_review." <> _verdict}), do: true

  defp peer_review_audit?(_), do: false

  # `task.reassign` audit entries written by `Actions.Tasks.reassign/4`
  # stash `from` + `to` on the entry map, but `AuditLog.append/2` moves
  # anything outside {ts, company, actor, action, target} into the
  # `detail` JSON object before writing to JSONL. So the persisted
  # shape is `entry["detail"]["from"]` / `entry["detail"]["to"]`; the
  # top-level keys exist only in the pre-persist struct. Codex P3
  # v0.8.0 pre-release: fall back to top-level for test-seeded rows
  # and for any historical rows that pre-date this nesting.
  defp reassign_from(e), do: pick_detail(e, "from")
  defp reassign_to(e), do: pick_detail(e, "to")

  defp pick_detail(entry, key) do
    detail = entry["detail"] || %{}
    detail[key] || entry[key] || ""
  end

  defp peer_review_label("peer_review.requested"), do: "review requested"
  defp peer_review_label("task.peer_review.approve"), do: "verdict: approve"
  defp peer_review_label("task.peer_review.revise"), do: "verdict: revise"
  defp peer_review_label("task.peer_review.block"), do: "verdict: block"
  defp peer_review_label(other) when is_binary(other), do: other
  defp peer_review_label(_), do: ""

  # Audit entries land as `{"action":..., "detail": {...}, ...}`.
  # `peer_review.requested` stashes `reviewer` + `severity` under detail;
  # `task.peer_review.<v>` stashes `note` under detail. We flatten the
  # most useful field per action family into a single display string.
  defp peer_review_detail(entry) do
    detail = entry["detail"] || %{}

    cond do
      is_binary(detail["reviewer"]) and detail["reviewer"] != "" ->
        "reviewer " <> detail["reviewer"] <> severity_suffix(detail)

      is_binary(detail["note"]) and detail["note"] != "" ->
        detail["note"]

      true ->
        ""
    end
  end

  defp severity_suffix(%{"severity" => sev}) when is_binary(sev) and sev not in ["", "unset"],
    do: " · severity " <> sev

  defp severity_suffix(_), do: ""
end
