defmodule GlorboWeb.BenchLive do
  @moduledoc """
  Blind A/B scoring view for one GEP-26 Phase B benchmark run —
  GET `/benchmarks/:run_id`.

  Renders the task prompt plus N output panels. Panels are labelled
  with opaque tokens (`Panel A`, `Panel B`, …) rather than provider
  names; the shuffle order is stable per `run_id` so a Director
  refreshing the page sees the same layout. Once a ranking is
  submitted the labels unmask and the score appends to
  `benchmarks/runs/<run-id>/scores.md`.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias Glorbo.Benchmarks
  alias GlorboWeb.Components.ChatDrawer

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    case Benchmarks.fetch(run_id, base: base_dir()) do
      {:ok, run} ->
        {:ok,
         socket
         |> assign(:page_title, "#{run.summary.run_id} — bench — Glorbo")
         |> assign(:sidebar_active, :benchmarks)
         |> assign(:run, run)
         |> assign(:unmasked?, false)
         |> assign(:ranking, [])
         |> ChatDrawer.State.wire_drawer()}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Run \"#{run_id}\" not found.")
         |> push_navigate(to: ~p"/benchmarks")}
    end
  end

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("select_rank", %{"panel" => panel}, socket) do
    ranking =
      cond do
        # Ignore tokens that aren't a real panel for this run. Without this an
        # out-of-range / stale token (e.g. "Z") would land in @ranking, render
        # in "Selected order:", and — once the length-based submit guard is
        # satisfied — crash submit_ranking on Map.fetch!/2 (KeyError). Keeping
        # @ranking well-formed makes the panel_map lookup total. (codex #58)
        not Map.has_key?(panel_map(socket.assigns.run.blind_order), panel) ->
          socket.assigns.ranking

        Enum.member?(socket.assigns.ranking, panel) ->
          List.delete(socket.assigns.ranking, panel)

        true ->
          socket.assigns.ranking ++ [panel]
      end

    {:noreply, assign(socket, :ranking, ranking)}
  end

  def handle_event("submit_ranking", %{"rationale" => rationale}, socket) do
    run = socket.assigns.run
    panel_to_provider = panel_map(run.blind_order)

    providers_ranked =
      socket.assigns.ranking
      |> Enum.map(&Map.fetch!(panel_to_provider, &1))

    case Benchmarks.score(run.summary.run_id, providers_ranked,
           base: base_dir(),
           rationale: rationale
         ) do
      :ok ->
        case Benchmarks.fetch(run.summary.run_id, base: base_dir()) do
          {:ok, refreshed} ->
            {:noreply,
             socket
             |> assign(:run, refreshed)
             |> assign(:unmasked?, true)
             |> put_flash(:info, "Scored. Panels unmasked.")}

          _ ->
            {:noreply, put_flash(socket, :info, "Scored.")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Score failed: #{inspect(reason)}")}
    end
  end

  def handle_event("reset_ranking", _params, socket),
    do: {:noreply, assign(socket, :ranking, [])}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :panels, Enum.with_index(assigns.run.blind_order, 0))

    ~H"""
    <section class="gl-view gl-bench">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">benchmarks /</span> {@run.summary.run_id}
          </h1>
          <p class="gl-overview__quote">
            // Blind A/B comparison. {if @unmasked?,
              do: "Panels unmasked after scoring.",
              else:
                "Panels are labelled A, B, C — provider identity is hidden until you submit a ranking."}
          </p>
        </div>
        <div>
          <span class="gl-pill gl-pill--info">{@run.summary.template || "?"}</span>
          <span class="gl-pill">{@run.summary.task || "?"}</span>
          <span class="gl-pill gl-pill--alive">{@run.summary.status || "?"}</span>
        </div>
      </header>

      <section class="gl-bench__task">
        <h2 class="gl-heading gl-heading--section">task</h2>
        <pre class="gl-bench__task-body">{@run.task_body}</pre>
      </section>

      <section class="gl-bench__panels">
        <article
          :for={{provider, idx} <- @panels}
          class={[
            "gl-bench__panel",
            rank_class(@ranking, panel_token(idx)),
            @unmasked? && "gl-bench__panel--unmasked"
          ]}
        >
          <header class="gl-bench__panel-header">
            <span class="gl-bench__panel-label">Panel {panel_token(idx)}</span>
            <span :if={@unmasked?} class="gl-tabular gl-accent-text">{provider}</span>
            <span class="gl-muted">rank {rank_of(@ranking, panel_token(idx))}</span>
            <button
              :if={not @unmasked?}
              type="button"
              class="gl-btn gl-btn--sm"
              phx-click="select_rank"
              phx-value-panel={panel_token(idx)}
            >
              {select_label(@ranking, panel_token(idx))}
            </button>
          </header>
          <pre class="gl-bench__output">{output_for(@run, provider)}</pre>
        </article>
      </section>

      <section :if={not @unmasked?} class="gl-bench__score">
        <h2 class="gl-heading gl-heading--section">submit ranking</h2>
        <form id="benchmark-ranking-form" phx-submit="submit_ranking" class="gl-bench__score-form">
          <p class="gl-overview__quote">
            Selected order: {render_selected(@ranking)}.
          </p>
          <label class="gl-form__row">
            <span class="gl-form__label">rationale (optional)</span>
            <textarea
              name="rationale"
              rows="4"
              class="gl-input gl-input--textarea"
              placeholder="Why this order? Appended to scores.md with your ranking."
            ></textarea>
          </label>
          <footer class="gl-bench__score-actions">
            <button
              type="button"
              class="gl-btn"
              phx-click="reset_ranking"
            >
              reset
            </button>
            <button
              type="submit"
              class="gl-btn gl-btn--primary"
              disabled={length(@ranking) != length(@run.blind_order)}
            >
              submit ranking
            </button>
          </footer>
        </form>
      </section>

      <section :if={String.trim(@run.scores_body) != ""} class="gl-bench__history">
        <h2 class="gl-heading gl-heading--section">scoring history</h2>
        <pre class="gl-bench__history-body">{@run.scores_body}</pre>
      </section>
    </section>
    """
  end

  # ------------------------------------------------------------------
  # View helpers
  # ------------------------------------------------------------------

  defp panel_token(idx), do: <<?A + idx::utf8>>

  defp panel_map(blind_order) do
    blind_order
    |> Enum.with_index(0)
    |> Map.new(fn {provider, idx} -> {panel_token(idx), provider} end)
  end

  defp output_for(run, provider) do
    case Enum.find(run.outputs, &(&1.provider == provider)) do
      nil -> "(no output.md for #{provider})"
      %{body: body} -> body
    end
  end

  defp rank_of(ranking, token) do
    case Enum.find_index(ranking, &(&1 == token)) do
      nil -> "—"
      idx -> Integer.to_string(idx + 1)
    end
  end

  defp rank_class(ranking, token) do
    case Enum.find_index(ranking, &(&1 == token)) do
      nil -> nil
      idx -> "gl-bench__panel--rank-#{idx + 1}"
    end
  end

  defp select_label(ranking, token) do
    if token in ranking, do: "unpick", else: "pick"
  end

  defp render_selected([]), do: "(none — click panels in best-to-worst order)"
  defp render_selected(tokens), do: Enum.join(tokens, " → ")
end
