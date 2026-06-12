defmodule Glorbo.Research do
  @moduledoc """
  Deep-research orchestrator (GEP-0057, v1 — template-first / D3).

  Drives a bounded, governed research task through five stages:

      plan → gather → read/extract → synthesise → render

  and emits a portable, sanitised artifact pair into the company tree:

      companies/<co>/projects/<slug>/reports/<id>/report.md
      companies/<co>/projects/<slug>/reports/<id>/report.html

  The orchestration follows the rails GEP-0057 mandates rather than
  inventing parallel machinery:

    * **Gather rides `web_fetch` (GEP-32).** Source bodies are pulled via
      the injected `:fetch_fun` (defaults to the native harness
      `web_fetch` tool), so `network:` policy + the egress proxy + the
      audit log apply unchanged.
    * **Each step is a budgeted unit (D2).** Before every gather step the
      injected `:budget_fun` is consulted. The default wires it to
      `Glorbo.Company.BudgetTracker.check_budget/2`, so a research task is
      as governed as any other dispatch.
    * **Budget = degrade-to-partial (D4).** When the budget gate REFUSES
      the next step (`{:stop, _, _}`) — or `max_steps` / `max_sources` is
      hit — the loop stops and the report is finalised *partial* with a
      leading `> Truncated at budget` banner. The task never crashes on a
      budget boundary.
    * **Source framing (D5).** Every fetched / extracted span is wrapped
      as untrusted via `Glorbo.Prompt.Untrusted.wrap/1` (GEP-0056) before
      it reaches the synthesise step, so injected web content reads to the
      synthesiser as data, not instructions.
    * **Sanitised render (D1).** The markdown report is rendered to HTML
      through Earmark and then `HtmlSanitizeEx.markdown_html/1` — the same
      defeat-XSS pipeline `GlorboWeb.Markdown` uses — wrapped in a
      self-contained HTML document so the artifact is portable (`scp`-able,
      openable offline).

  ## Dependency injection

  All IO + LLM steps route through injected functions (same discipline as
  `Glorbo.Skills.Resolver` / `Glorbo.Company.BudgetTracker`), so the suite
  runs deterministically offline:

    * `:plan_fun` — `(question) -> [url]`. Produces the candidate source
      URLs. In production an ordinary budgeted LLM planning call.
    * `:fetch_fun` — `(url) -> {:ok, %{"body" => ..}} | {:error, _}`.
      Defaults to a `web_fetch` adapter.
    * `:synthesise_fun` — `(question, [framed_source]) -> markdown_body`.
      Receives the FRAMED (untrusted-wrapped) source spans.
    * `:budget_fun` — `() -> :ok | {:alert, u, c} | {:stop, u, c}`.
    * `:fs_fun` — `%{mkdir_p!:, write!:}` filesystem seam.
    * `:audit_fun` — `(company, entry) -> any`.
    * `:id_fun` — `() -> report_id` (defaults to a time-sortable id).
  """

  require Logger

  alias Glorbo.CLI.Harness.Tools
  alias Glorbo.Company.AuditLog
  alias Glorbo.Prompt.Untrusted

  @default_max_steps 8
  @default_max_sources 6
  @truncation_banner "> Truncated at budget"

  @type framed_source :: %{
          url: String.t(),
          raw: String.t(),
          framed: String.t()
        }

  @type result :: %{
          id: String.t(),
          slug: String.t(),
          company: String.t(),
          question: String.t(),
          partial?: boolean(),
          report_md_path: String.t(),
          report_html_path: String.t(),
          sources: [framed_source()]
        }

  @doc """
  Run a research task for `question`. Returns `{:ok, result}` with the
  artifact paths and the framed source list, or `{:error, reason}` if the
  request shape is invalid (bad slug / bad company).

  Opts (see the moduledoc for the injection seams):

    * `:company`, `:slug` — REQUIRED; both slug-validated before any IO.
    * `:base` — filesystem root (defaults to `default_root/0`).
    * `:agent_slug` — owning agent, used for budget checks + audit actor.
    * `:max_steps`, `:max_sources` — bound the gather loop (D4 caps).
    * `:plan_fun`, `:fetch_fun`, `:synthesise_fun`, `:budget_fun`,
      `:fs_fun`, `:audit_fun`, `:id_fun` — injection seams.
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(question, opts \\ []) when is_binary(question) and is_list(opts) do
    company = Keyword.get(opts, :company, "")
    slug = Keyword.get(opts, :slug, "")

    cond do
      not Glorbo.Slug.valid?(company) ->
        {:error, {:invalid_company, company}}

      not Glorbo.Slug.valid?(slug) ->
        {:error, {:invalid_slug, slug}}

      true ->
        do_run(question, company, slug, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Orchestration
  # ---------------------------------------------------------------------------

  defp do_run(question, company, slug, opts) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    agent_slug = Keyword.get(opts, :agent_slug, "researcher")
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    max_sources = Keyword.get(opts, :max_sources, @default_max_sources)

    plan_fun = Keyword.get(opts, :plan_fun, &default_plan_fun/1)
    fetch_fun = Keyword.get(opts, :fetch_fun, default_fetch_fun(opts))
    synthesise_fun = Keyword.get(opts, :synthesise_fun, &default_synthesise_fun/2)
    budget_fun = Keyword.get(opts, :budget_fun, default_budget_fun(company, agent_slug, opts))
    fs_fun = Keyword.get(opts, :fs_fun, default_fs_fun())
    audit_fun = Keyword.get(opts, :audit_fun, &AuditLog.append_for/2)
    id_fun = Keyword.get(opts, :id_fun, &default_id_fun/0)

    id = id_fun.()
    # Do NOT pre-truncate the plan to the caps: the gather loop enforces
    # `max_steps` / `max_sources` itself so that hitting a cap is observable
    # as a partial result (D4) rather than silently capped upstream.
    candidates = plan_fun.(question) |> List.wrap()

    {framed_sources, partial?} =
      gather(candidates, fetch_fun, budget_fun, max_steps, max_sources)

    emit_audit(audit_fun, company, %{
      action: "research.completed",
      actor: agent_slug,
      company: company,
      agent: agent_slug,
      slug: slug,
      report_id: id,
      sources: length(framed_sources),
      partial: partial?
    })

    markdown = render_markdown(question, framed_sources, synthesise_fun, partial?)
    html = render_html(question, markdown)

    report_dir = report_dir(base, company, slug, id)
    fs_fun.mkdir_p!.(report_dir)

    md_path = Path.join(report_dir, "report.md")
    html_path = Path.join(report_dir, "report.html")
    fs_fun.write!.(md_path, markdown)
    fs_fun.write!.(html_path, html)

    {:ok,
     %{
       id: id,
       slug: slug,
       company: company,
       question: question,
       partial?: partial?,
       report_md_path: md_path,
       report_html_path: html_path,
       sources: framed_sources
     }}
  end

  # Gather loop. Walks candidate URLs, checking the budget gate before each
  # fetch. Stops early (returning partial?: true) when the budget gate
  # refuses, or the step / source caps bite. Source framing happens here:
  # every fetched body is wrapped via Untrusted.wrap/1 (D5) the moment it
  # leaves the network and before it can reach synthesise.
  defp gather(candidates, fetch_fun, budget_fun, max_steps, max_sources) do
    candidates
    |> Enum.with_index()
    |> Enum.reduce_while({[], false}, fn {url, idx}, {acc, _partial} ->
      cond do
        idx >= max_steps ->
          {:halt, {acc, true}}

        length(acc) >= max_sources ->
          {:halt, {acc, true}}

        budget_refused?(budget_fun) ->
          {:halt, {acc, true}}

        true ->
          case fetch_source(url, fetch_fun) do
            {:ok, framed} -> {:cont, {acc ++ [framed], false}}
            :skip -> {:cont, {acc, false}}
          end
      end
    end)
  end

  defp budget_refused?(budget_fun) do
    case budget_fun.() do
      {:stop, _used, _cap} -> true
      _ -> false
    end
  end

  # Read/extract + frame a single source. A failed fetch is skipped (the
  # report degrades gracefully) rather than aborting the whole task.
  defp fetch_source(url, fetch_fun) do
    case fetch_fun.(url) do
      {:ok, %{"body" => body}} when is_binary(body) ->
        raw = String.trim(body)
        {:ok, %{url: url, raw: raw, framed: Untrusted.wrap(raw)}}

      _ ->
        :skip
    end
  end

  # ---------------------------------------------------------------------------
  # Render — markdown
  # ---------------------------------------------------------------------------

  defp render_markdown(question, framed_sources, synthesise_fun, partial?) do
    banner = if partial?, do: @truncation_banner <> "\n\n", else: ""
    body = synthesise_fun.(question, framed_sources)

    sources_section = render_sources_section(framed_sources)

    """
    #{banner}# Research report

    **Question:** #{escape_md(question)}

    #{body}

    #{sources_section}
    """
    |> String.trim_leading()
  end

  defp render_sources_section([]), do: "## Sources\n\n_No sources gathered._"

  defp render_sources_section(framed_sources) do
    list =
      framed_sources
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {%{url: url}, n} -> "#{n}. <#{url}>" end)

    "## Sources\n\n" <> list
  end

  # ---------------------------------------------------------------------------
  # Render — sanitised, self-contained HTML (D1)
  # ---------------------------------------------------------------------------

  # Same defeat-XSS pipeline as `GlorboWeb.Markdown`: Earmark renders the
  # untrusted markdown to HTML, then `HtmlSanitizeEx.markdown_html/1` strips
  # every tag not on its allowlist (`<script>`, `<iframe>`, inline event
  # handlers, `javascript:` URLs all dropped). We then wrap the sanitised
  # fragment in a minimal self-contained document so the artifact opens
  # offline with no external assets.
  defp render_html(question, markdown) do
    fragment =
      markdown
      |> Earmark.as_html!(%Earmark.Options{compact_output: true, smartypants: false, gfm: true})
      |> HtmlSanitizeEx.markdown_html()

    title = html_escape(String.slice(question, 0, 120))

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Research report — #{title}</title>
    <style>
    body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#1a1a1a}
    blockquote{border-left:4px solid #d97706;background:#fff7ed;margin:0 0 1rem;padding:.5rem 1rem;color:#92400e}
    code{background:#f3f4f6;padding:.1rem .3rem;border-radius:.2rem}
    pre{background:#f3f4f6;padding:1rem;overflow:auto;border-radius:.4rem}
    h1,h2,h3{line-height:1.25}
    a{color:#2563eb}
    </style>
    </head>
    <body>
    #{fragment}
    </body>
    </html>
    """
  end

  # ---------------------------------------------------------------------------
  # Paths
  # ---------------------------------------------------------------------------

  defp report_dir(base, company, slug, id) do
    Path.join([base, "companies", company, "projects", slug, "reports", id])
  end

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  # In production the planner is an ordinary budgeted LLM call that proposes
  # source URLs for the question. The native-LLM wiring lands with GEP-0032 /
  # GEP-0055; until then the orchestrator is exercised via injected
  # `:plan_fun`, and the default is a conservative empty plan rather than a
  # silent network call.
  defp default_plan_fun(_question), do: []

  # `web_fetch` adapter (GEP-32). Drives the native harness tool with the
  # same shape `Glorbo.CLI.Harness` uses, then normalises the payload to the
  # `{:ok, %{"body" => _}}` contract the gather loop expects.
  defp default_fetch_fun(opts) do
    workspace = Keyword.get(opts, :workspace, System.tmp_dir!())
    config = %{workspace: workspace}

    fn url ->
      call = %{
        "function" => %{"name" => "web_fetch", "arguments" => Jason.encode!(%{"url" => url})}
      }

      case Tools.execute(call, config, []) do
        %{payload: %{"ok" => true, "body" => body} = payload} ->
          {:ok, payload |> Map.put("body", body)}

        %{payload: payload} ->
          {:error, payload}
      end
    end
  end

  # The synthesiser turns the framed source spans into the report body. In
  # production an ordinary budgeted LLM call; the default is a deterministic
  # transcription so the orchestrator is usable without LLM wiring and the
  # framing (D5) is preserved verbatim in the artifact.
  defp default_synthesise_fun(_question, []) do
    "## Findings\n\n_No sources were available to synthesise from._"
  end

  defp default_synthesise_fun(_question, framed_sources) do
    body =
      framed_sources
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {%{url: url, framed: framed}, n} ->
        "### Source #{n} — #{escape_md(url)}\n\n```\n#{framed}\n```"
      end)

    "## Findings\n\n" <> body
  end

  defp default_budget_fun(_company, agent_slug, opts) do
    case Keyword.get(opts, :budget_server) do
      nil ->
        # No budget tracker wired (CLI / test contexts without a running
        # company supervisor): treat as unlimited, same default as
        # BudgetTracker for an un-capped agent.
        fn -> :ok end

      server ->
        fn -> Glorbo.Company.BudgetTracker.check_budget(server, agent_slug) end
    end
  end

  defp default_id_fun do
    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "")
    rand = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "rpt-#{ts}-#{rand}"
  end

  defp default_fs_fun do
    %{
      mkdir_p!: &File.mkdir_p!/1,
      write!: &File.write!/2
    }
  end

  # ---------------------------------------------------------------------------
  # Small helpers
  # ---------------------------------------------------------------------------

  defp emit_audit(audit_fun, company, entry) do
    audit_fun.(company, entry)
    :ok
  rescue
    e ->
      Logger.warning("research audit emit failed: #{Exception.message(e)}")
      :ok
  end

  # Markdown-escape a user/source-controlled string used inside the report
  # body so it can't smuggle markdown structure (the HTML render still
  # sanitises, but keep the markdown layer honest too).
  defp escape_md(s) when is_binary(s) do
    String.replace(s, ~r/([\\`*_{}\[\]()#+!|>-])/, "\\\\\\1")
  end

  defp html_escape(s) when is_binary(s) do
    s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
