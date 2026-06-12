defmodule Glorbo.ResearchTest do
  @moduledoc """
  Suite for the GEP-0057 deep-research orchestrator (`Glorbo.Research`).

  Covers the three load-bearing invariants from the GEP:

    * **Degrade-to-partial (D4):** when the 100% budget gate REFUSES the
      next step (`{:stop, _, _}`) — or `max_steps` / `max_sources` is hit —
      the orchestrator finalises a *partial* report with a leading
      `> Truncated at budget` banner instead of crashing.
    * **Sanitised HTML output (D1):** `report.html` is rendered through
      Earmark + `html_sanitize_ex`; no `<script>` survives even when a
      fetched source body carries one.
    * **Source framing (D5):** every fetched / extracted span is framed as
      untrusted via `Glorbo.Prompt.Untrusted.wrap/1` before it reaches the
      synthesise step.

  All web + LLM IO is dependency-injected so the suite is deterministic
  and offline (same DI pattern as `Glorbo.Skills.Resolver` /
  `Glorbo.Company.BudgetTracker`).
  """
  use ExUnit.Case, async: true

  alias Glorbo.Research

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-research-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  # A plan that wants three sources.
  defp plan_three(_question),
    do: ["http://a.example/1", "http://b.example/2", "http://c.example/3"]

  # A fetch fn that returns a benign body keyed off the URL.
  defp fetch_ok(url), do: {:ok, %{"url" => url, "status" => 200, "body" => "content of #{url}"}}

  # A synthesise fn that just concatenates the framed source blocks it is
  # handed, so the test can assert on what reached it.
  defp synth_echo(_question, framed_sources) do
    body =
      framed_sources
      |> Enum.map_join("\n\n", & &1.framed)

    "# Findings\n\n" <> body
  end

  defp run_opts(base, overrides) do
    Keyword.merge(
      [
        base: base,
        company: "acme",
        slug: "market-scan",
        agent_slug: "ceo",
        id_fun: fn -> "rpt-fixed" end,
        plan_fun: &plan_three/1,
        fetch_fun: &fetch_ok/1,
        synthesise_fun: &synth_echo/2,
        budget_fun: fn -> :ok end,
        audit_fun: fn _company, _entry -> :ok end
      ],
      overrides
    )
  end

  describe "happy path" do
    test "writes report.md and report.html under projects/<slug>/reports/<id>/", %{base: base} do
      assert {:ok, result} = Research.run("what is the market?", run_opts(base, []))

      expected_dir =
        Path.join([base, "companies", "acme", "projects", "market-scan", "reports", "rpt-fixed"])

      assert result.id == "rpt-fixed"
      refute result.partial?
      assert result.report_md_path == Path.join(expected_dir, "report.md")
      assert result.report_html_path == Path.join(expected_dir, "report.html")
      assert File.exists?(result.report_md_path)
      assert File.exists?(result.report_html_path)

      md = File.read!(result.report_md_path)
      refute md =~ "Truncated at budget"
      assert md =~ "what is the market?"
    end
  end

  describe "degrade-to-partial (D4)" do
    test "budget refusal mid-gather finalises a partial report with the banner", %{base: base} do
      # Allow the first source, then refuse: the second budget check returns
      # the 100% hard-stop tuple. The orchestrator must NOT crash.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      budget_fun = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n == 0, do: :ok, else: {:stop, 10_000, 10_000}
      end

      assert {:ok, result} = Research.run("q", run_opts(base, budget_fun: budget_fun))

      assert result.partial?
      md = File.read!(result.report_md_path)
      assert md =~ "> Truncated at budget"
      # The banner must be the LEADING line (after no preamble).
      assert String.starts_with?(String.trim_leading(md), "> Truncated at budget")
      # Only the first source was gathered before the refusal.
      assert length(result.sources) == 1
    end

    test "hitting max_sources finalises a partial report", %{base: base} do
      assert {:ok, result} = Research.run("q", run_opts(base, max_sources: 2))

      assert result.partial?
      assert length(result.sources) == 2
      assert File.read!(result.report_md_path) =~ "> Truncated at budget"
    end

    test "hitting max_steps finalises a partial report", %{base: base} do
      assert {:ok, result} = Research.run("q", run_opts(base, max_steps: 1))

      assert result.partial?
      assert File.read!(result.report_md_path) =~ "> Truncated at budget"
    end

    test "a non-partial report carries no banner", %{base: base} do
      assert {:ok, result} = Research.run("q", run_opts(base, max_sources: 99, max_steps: 99))
      refute result.partial?
      refute File.read!(result.report_md_path) =~ "Truncated at budget"
    end
  end

  describe "report.html is sanitised (D1)" do
    test "a <script> in a fetched source body does not survive into report.html", %{base: base} do
      poison_fetch = fn url ->
        {:ok,
         %{"url" => url, "status" => 200, "body" => "hi <script>alert('xss')</script> there"}}
      end

      assert {:ok, result} = Research.run("q", run_opts(base, fetch_fun: poison_fetch))

      html = File.read!(result.report_html_path)
      # No live <script> tag may survive sanitisation.
      refute html =~ ~r/<script[\s>]/i
      refute html =~ ~r{</script>}i
      # And it must actually be HTML (Earmark ran).
      assert html =~ "<h1>" or html =~ "<p>"
    end

    test "report.html is self-contained HTML with a doctype", %{base: base} do
      assert {:ok, result} = Research.run("q", run_opts(base, []))
      html = File.read!(result.report_html_path)
      assert html =~ ~r/<!doctype html>/i
      assert html =~ "<body"
    end
  end

  describe "source framing (D5)" do
    test "every fetched span is wrapped via Glorbo.Prompt.Untrusted before synthesise", %{
      base: base
    } do
      {:ok, captured} = Agent.start_link(fn -> nil end)

      capturing_synth = fn question, framed_sources ->
        Agent.update(captured, fn _ -> framed_sources end)
        synth_echo(question, framed_sources)
      end

      assert {:ok, _result} = Research.run("q", run_opts(base, synthesise_fun: capturing_synth))

      framed_sources = Agent.get(captured, & &1)
      assert is_list(framed_sources)
      assert framed_sources != []

      sentinel = Glorbo.Prompt.Untrusted.wrap("content of http://a.example/1")

      Enum.each(framed_sources, fn s ->
        assert is_binary(s.framed)
        # The framed text must be s.raw wrapped in a matched-random UNTRUSTED
        # boundary (GEP-56): identical opening/closing nonce, body verbatim
        # between them. Each wrap/1 mints a FRESH random nonce (that freshness
        # IS the breakout mitigation), so assert STRUCTURE, not equality to
        # another wrap/1 call.
        assert Regex.match?(
                 ~r/\AUNTRUSTED-START-([0-9A-F]+)\n#{Regex.escape(s.raw)}\nUNTRUSTED-END-\1\z/,
                 s.framed
               ),
               "source not matched-random framed: #{inspect(s.framed)}"
      end)

      # Cross-check the wrap output is non-trivial framing (contains a marker
      # distinct from the raw body).
      refute sentinel == "content of http://a.example/1"
    end
  end
end
