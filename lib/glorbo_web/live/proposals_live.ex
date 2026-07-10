defmodule GlorboWeb.ProposalsLive do
  @moduledoc """
  Director-facing proposals queue — GET `/companies/:company/proposals`
  (GEP-28).

  Lists every `proposals/*.md` file under the company grouped by
  `status:` frontmatter (pending-approval, approved, denied,
  superseded). Pending rows carry Approve / Deny buttons. Denials
  prompt for an inline reason. All flips go through
  `Glorbo.Company.Proposals.flip/4` which writes the proposal
  frontmatter in place and appends an audit row.

  Read-only for agent-created writes — agents still hit the
  outbox → Router path from GEP-28 D7. This LiveView is strictly
  the Director's counterpart.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias Glorbo.Company.Proposals
  alias GlorboWeb.Components.ChatDrawer

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    cond do
      not Glorbo.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not File.dir?(Path.join([base_dir(), "companies", co])) ->
        {:ok,
         socket
         |> put_flash(:error, "Company \"#{co}\" not found.")
         |> push_navigate(to: ~p"/companies")}

      true ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:proposals")
          Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:status")
        end

        {:ok, load_and_assign(socket, co)}
    end
  end

  @impl true
  def handle_info({:file_event, _rel, _events}, socket) do
    {:noreply, load_and_assign(socket, socket.assigns.company_slug)}
  end

  def handle_info({:agent_status, _slug, _status, _working_on}, socket), do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("approve", %{"id" => id}, socket) do
    case Proposals.flip(socket.assigns.company_slug, id, :approved, base: base_dir()) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Approved #{id}.")
         |> load_and_assign(socket.assigns.company_slug)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(reason)}")}
    end
  end

  def handle_event("deny_prompt", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :deny_id, id)}

  def handle_event("deny_cancel", _params, socket),
    do: {:noreply, assign(socket, :deny_id, nil)}

  def handle_event("deny_confirm", %{"reason" => reason}, socket) do
    id = socket.assigns.deny_id

    case Proposals.flip(socket.assigns.company_slug, id, :denied,
           base: base_dir(),
           denial_reason: reason
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(:deny_id, nil)
         |> put_flash(:info, "Denied #{id}.")
         |> load_and_assign(socket.assigns.company_slug)}

      {:error, reason_err} ->
        {:noreply, put_flash(socket, :error, "Deny failed: #{inspect(reason_err)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-proposals">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">{@company_slug} /</span> proposals
          </h1>
          <p class="gl-overview__quote">
            // Agent-created structural proposals (hire, fire, budget, project, custom).
          </p>
        </div>
        <div class="gl-proposals__counts">
          <span class="gl-pill gl-pill--info">
            <span class="gl-pill__dot"></span>{length(@pending)} pending
          </span>
          <span class="gl-pill gl-pill--alive">
            <span class="gl-pill__dot"></span>{length(@approved)} approved
          </span>
          <span class="gl-pill gl-pill--stop">
            <span class="gl-pill__dot"></span>{length(@denied)} denied
          </span>
        </div>
      </header>

      <section class="gl-proposals__section">
        <h2 class="gl-heading gl-heading--section">pending</h2>
        <div :if={@pending == []} class="gl-empty">No proposals awaiting approval.</div>
        <ul :if={@pending != []} class="gl-proposals__list">
          <li :for={p <- @pending} class="gl-proposals__row gl-proposals__row--pending">
            <div class="gl-proposals__meta">
              <span class="gl-tabular gl-proposals__id">{p.id}</span>
              <span class="gl-tag">{p.subtype}</span>
              <span class="gl-muted">proposed by {p.proposed_by || "?"}</span>
              <span class="gl-muted">{format_at(p.proposed_at)}</span>
            </div>
            <div class="gl-proposals__body">{truncate(p.body)}</div>
            <div class="gl-proposals__actions">
              <button
                type="button"
                class="gl-btn gl-btn--primary gl-btn--sm"
                phx-click="approve"
                phx-value-id={p.id}
              >
                ✓ approve
              </button>
              <button
                type="button"
                class="gl-btn gl-btn--sm"
                phx-click="deny_prompt"
                phx-value-id={p.id}
              >
                ✗ deny
              </button>
            </div>
          </li>
        </ul>
      </section>

      <section :if={@approved != []} class="gl-proposals__section">
        <h2 class="gl-heading gl-heading--section">approved</h2>
        <ul class="gl-proposals__list">
          <li :for={p <- @approved} class="gl-proposals__row gl-proposals__row--approved">
            <div class="gl-proposals__meta">
              <span class="gl-tabular gl-proposals__id">{p.id}</span>
              <span class="gl-tag">{p.subtype}</span>
              <span class="gl-muted">by {p.proposed_by || "?"} → {p.approved_by || "?"}</span>
              <span class="gl-muted">{format_at(p.approved_at)}</span>
            </div>
            <div class="gl-proposals__body">{truncate(p.body)}</div>
          </li>
        </ul>
      </section>

      <section :if={@denied != []} class="gl-proposals__section">
        <h2 class="gl-heading gl-heading--section">denied</h2>
        <ul class="gl-proposals__list">
          <li :for={p <- @denied} class="gl-proposals__row gl-proposals__row--denied">
            <div class="gl-proposals__meta">
              <span class="gl-tabular gl-proposals__id">{p.id}</span>
              <span class="gl-tag">{p.subtype}</span>
              <span class="gl-muted">
                by {p.proposed_by || "?"} · denied by {p.approved_by || "?"}
              </span>
            </div>
            <div :if={p.denial_reason} class="gl-proposals__reason">{p.denial_reason}</div>
            <div class="gl-proposals__body">{truncate(p.body)}</div>
          </li>
        </ul>
      </section>

      <div :if={@deny_id} class="gl-modal" phx-window-keydown="deny_cancel" phx-key="Escape">
        <div class="gl-modal__backdrop" phx-click="deny_cancel"></div>
        <form id="proposal-deny-form" phx-submit="deny_confirm" class="gl-modal__card">
          <header class="gl-modal__header">
            <h3 class="gl-heading gl-heading--section">Deny {@deny_id}</h3>
            <button type="button" class="gl-modal__close" phx-click="deny_cancel" aria-label="close">
              ×
            </button>
          </header>
          <div class="gl-modal__body">
            <label class="gl-form__row">
              <span class="gl-form__label">reason</span>
              <textarea
                name="reason"
                class="gl-input gl-input--textarea"
                rows="4"
                placeholder="Persisted to the proposal frontmatter + audit log."
                autofocus
              ></textarea>
            </label>
          </div>
          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn" phx-click="deny_cancel">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary">deny</button>
          </footer>
        </form>
      </div>
    </section>
    """
  end

  # ------------------------------------------------------------------
  # Data
  # ------------------------------------------------------------------

  defp load_and_assign(socket, co) do
    all = Proposals.list(co, base: base_dir())

    pending = Enum.filter(all, &(&1.status == "pending-approval"))
    approved = Enum.filter(all, &(&1.status == "approved"))
    denied = Enum.filter(all, &(&1.status == "denied"))

    socket
    |> assign(:page_title, "Proposals — #{co} — Glorbo")
    |> assign(:sidebar_active, :proposals)
    |> assign(:company_slug, co)
    |> assign(:base, base_dir())
    |> assign(:pending, pending)
    |> assign(:approved, approved)
    |> assign(:denied, denied)
    |> assign_new(:deny_id, fn -> nil end)
    |> ChatDrawer.State.wire_drawer()
  end

  defp truncate(nil), do: ""

  defp truncate(body) when is_binary(body) do
    body
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.take(3)
    |> Enum.join(" · ")
    |> String.slice(0, 240)
  end

  defp format_at(nil), do: "—"

  defp format_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> value
    end
  end

  defp format_at(_), do: "—"
end

# Codex round-6 finding (PR #38, LOW): agent-controlled
# frontmatter scalars (subtype, proposed_at, proposed_by,
# denial_reason) rendered unbounded in the proposals list.
# `body` was already capped via `truncate/1`; the others
# weren't. AgentWritableFile's 10 MiB file cap bounds the
# worst case but a single proposal still hits ~10 MiB of
# HTML per list refresh. Normalise these in
# `Glorbo.Company.Proposals.list/2` (the loader) so every
# render path benefits, not just the LV.
