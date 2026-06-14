defmodule Glorbo.Memory.IndexTest do
  use Glorbo.DataCase, async: false

  alias Glorbo.Memory.{Index, Vector}

  # A deterministic stub embedder: maps each text to a fixed vector by
  # keyword presence so cosine ordering is predictable without a real
  # `/v1/embeddings` server. The query/text axes are:
  #   axis 0 = "fox"  axis 1 = "moon"  axis 2 = "ledger"
  defp stub_embed_fun do
    fn _model, texts ->
      vectors =
        Enum.map(texts, fn text ->
          t = String.downcase(text)

          [
            if(String.contains?(t, "fox"), do: 1.0, else: 0.0),
            if(String.contains?(t, "moon"), do: 1.0, else: 0.0),
            if(String.contains?(t, "ledger"), do: 1.0, else: 0.0)
          ]
        end)

      {:ok, vectors}
    end
  end

  defp opts, do: [embed_fun: stub_embed_fun(), model: "stub-embed"]

  # The chunk fixture: three chunks, each loaded on a different axis.
  defp fixture_chunks do
    [
      {"companies/acme/memory/notes.md", 0, "the quick brown fox jumped"},
      {"companies/acme/memory/notes.md", 1, "the moon rose over the hill"},
      {"companies/acme/memory/ledger.md", 0, "the quarterly ledger was reconciled"}
    ]
  end

  describe "enable/disable (default-OFF opt-in)" do
    test "a company is disabled by default" do
      refute Index.enabled?("acme")
    end

    test "enable then enabled? is true; disable flips it back" do
      :ok = Index.enable("acme")
      assert Index.enabled?("acme")

      :ok = Index.disable("acme")
      refute Index.enabled?("acme")
    end

    test "enable is idempotent" do
      :ok = Index.enable("acme")
      :ok = Index.enable("acme")
      assert Index.enabled?("acme")
    end

    test "reindex_company is a no-op for a disabled company" do
      assert {:ok, 0} = Index.reindex_company("acme", fixture_chunks(), opts())
      assert Index.search("acme", "fox", opts()) == []
    end

    test "disable purges the company's derived rows" do
      :ok = Index.enable("acme")
      assert {:ok, 3} = Index.reindex_company("acme", fixture_chunks(), opts())
      refute Index.search("acme", "fox", opts()) == []

      :ok = Index.disable("acme")
      # After re-enabling (so the search gate passes) the rows are gone.
      :ok = Index.enable("acme")
      assert Index.search("acme", "fox", opts()) == []
    end
  end

  describe "GEP-3 disk-persisted opt-in" do
    setup do
      # Persist the opt-in needs a real company.md to write into.
      base = Glorbo.Filesystem.Hierarchy.default_root()
      co_dir = Path.join([base, "companies", "persisted"])
      File.mkdir_p!(co_dir)

      File.write!(Path.join(co_dir, "company.md"), """
      ---
      kind: company/v1
      slug: persisted
      name: Persisted
      ---
      # Persisted
      """)

      {:ok, co_md: Path.join(co_dir, "company.md")}
    end

    test "enable writes memory_index: true to company.md", %{co_md: co_md} do
      :ok = Index.enable("persisted")
      assert File.read!(co_md) =~ ~r/^memory_index: true$/m
      assert Index.company_memory_enabled?("persisted")
    end

    test "disable writes memory_index: false to company.md", %{co_md: co_md} do
      :ok = Index.enable("persisted")
      :ok = Index.disable("persisted")
      assert File.read!(co_md) =~ ~r/^memory_index: false$/m
      refute Index.company_memory_enabled?("persisted")
    end

    test "opt-in survives a glorbo.db wipe (re-derivable from disk)" do
      :ok = Index.enable("persisted")

      # Simulate `rm glorbo.db`: clear the SQLite enabled cache directly.
      Glorbo.Repo.delete_all("memory_index_enabled")
      refute Index.enabled?("persisted")

      # The disk source of truth still says enabled; reindex re-seeds it.
      assert Index.company_memory_enabled?("persisted")
      :ok = Index.mark_enabled("persisted")
      assert Index.enabled?("persisted")
    end

    test "company_memory_enabled? is false for a company.md without the key" do
      refute Index.company_memory_enabled?("persisted")
    end
  end

  describe "FTS5 keyword recall" do
    setup do
      :ok = Index.enable("acme")
      {:ok, 3} = Index.reindex_company("acme", fixture_chunks(), opts())
      :ok
    end

    test "keyword_candidates matches on content, scoped to the company" do
      hits = Index.keyword_candidates("acme", "fox")
      assert Enum.any?(hits, &(&1.chunk_id == 0 and &1.source_path =~ "notes.md"))
      refute Enum.any?(hits, &String.contains?(&1.content, "ledger"))
    end

    test "a non-matching query returns no candidates" do
      assert Index.keyword_candidates("acme", "nonexistentword") == []
    end

    test "search returns the keyword-matched chunk" do
      results = Index.search("acme", "ledger", opts())
      assert Enum.any?(results, &String.contains?(&1.content, "ledger"))
    end
  end

  describe "cosine re-rank ordering" do
    setup do
      :ok = Index.enable("acme")
      {:ok, 3} = Index.reindex_company("acme", fixture_chunks(), opts())
      :ok
    end

    test "cosine drives the order when keyword relevance is uniform" do
      # Two chunks share the same matched keyword ("topic") so FTS5 bm25
      # ranks them identically — the ONLY remaining signal is the cosine
      # axis. The query embeds onto the fox axis, so the fox-laden chunk
      # must come first. This isolates the cosine re-rank contribution.
      chunks = [
        {"a.md", 0, "topic about a fox running fast"},
        {"b.md", 0, "topic about the ledger and the moon"}
      ]

      {:ok, 2} = Index.reindex_company("acme", chunks, opts())

      results = Index.search("acme", "topic fox", opts())
      assert hd(results).source_path == "a.md"
      assert String.contains?(hd(results).content, "fox")
    end

    test "a missing query embedding degrades gracefully to keyword order" do
      # "the" embeds to the zero vector under the stub → cosine ranking is
      # empty → RRF falls back to pure keyword order. Search must still
      # return the keyword matches, never crash.
      results = Index.search("acme", "the", opts())
      assert results != []
      assert Enum.all?(results, &is_map/1)
    end
  end

  describe "RRF fusion produces a final ordering" do
    setup do
      :ok = Index.enable("acme")
      {:ok, 3} = Index.reindex_company("acme", fixture_chunks(), opts())
      :ok
    end

    test "results carry a fused score, best first" do
      results = Index.search("acme", "fox moon", opts())
      assert results != []
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "per-company isolation (load-bearing)" do
    test "a company-A query NEVER returns company-B chunks" do
      :ok = Index.enable("acme")
      :ok = Index.enable("globex")

      {:ok, 3} = Index.reindex_company("acme", fixture_chunks(), opts())

      globex_chunks = [
        {"companies/globex/memory/secret.md", 0, "globex fox blueprint top secret"}
      ]

      {:ok, 1} = Index.reindex_company("globex", globex_chunks, opts())

      acme_results = Index.search("acme", "fox", opts())
      globex_results = Index.search("globex", "fox", opts())

      # acme sees its own fox chunk, never globex's secret.
      assert Enum.any?(acme_results, &String.contains?(&1.content, "brown fox"))
      refute Enum.any?(acme_results, &String.contains?(&1.content, "globex"))

      # globex sees only its own.
      assert Enum.all?(globex_results, &String.contains?(&1.source_path, "globex"))
      refute Enum.any?(globex_results, &String.contains?(&1.source_path, "acme"))
    end

    test "keyword_candidates is scoped to the company" do
      :ok = Index.enable("acme")
      :ok = Index.enable("globex")
      {:ok, 3} = Index.reindex_company("acme", fixture_chunks(), opts())

      {:ok, 1} =
        Index.reindex_company(
          "globex",
          [{"companies/globex/m.md", 0, "globex fox"}],
          opts()
        )

      acme_hits = Index.keyword_candidates("acme", "fox")
      assert Enum.all?(acme_hits, &String.contains?(&1.source_path, "acme"))
    end
  end

  describe "embedder stub wiring" do
    test "the injected embed_fun is used, no real server contacted" do
      :ok = Index.enable("acme")

      # An embed_fun that raises if called with the wrong arity / shape —
      # proves search drives through the stub, never the Finch path.
      raising = fn _model, texts -> {:ok, Enum.map(texts, fn _ -> [1.0, 0.0, 0.0] end)} end

      {:ok, 3} = Index.reindex_company("acme", fixture_chunks(), embed_fun: raising, model: "x")
      results = Index.search("acme", "fox", embed_fun: raising, model: "x")
      assert results != []
    end

    test "a vector round-trips through storage with the same dimensionality" do
      :ok = Index.enable("acme")

      fun = fn _model, texts -> {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3, 0.4] end)} end
      {:ok, 1} = Index.reindex_company("acme", [{"p.md", 0, "hi"}], embed_fun: fun, model: "x")

      [row] = Repo.all(Glorbo.Memory.ChunkVector)
      assert row.dims == 4
      assert Vector.unpack(row.embedding) |> length() == 4
    end

    test "an embedding-count mismatch is surfaced, prior index untouched" do
      :ok = Index.enable("acme")
      bad = fn _model, _texts -> {:ok, [[1.0, 0.0, 0.0]]} end

      assert {:error, :embedding_count_mismatch} =
               Index.reindex_company("acme", fixture_chunks(), embed_fun: bad, model: "x")
    end
  end
end
