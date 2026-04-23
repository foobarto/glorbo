defmodule Glorbo.Benchmarks do
  @moduledoc """
  GEP-26 Phase B — read + score benchmark runs on disk.

  A benchmark run lives at
  `~/.glorbo/benchmarks/runs/<run-id>/` with the shape:

      runs/<run-id>/
      ├── manifest.md         kind: benchmark-run/v1
      ├── task.md             task body (frozen)
      ├── providers/
      │   └── <provider>/
      │       ├── output.md   final reply
      │       └── runlog.md   stdout + timings (optional)
      └── scores.md           director rankings + rationale

  This module is the Director-side reader + scorer. The matching
  dispatch machinery (`glorbo bench run ...`) that actually forks
  shadow companies and fans a task out to N providers is a
  follow-up; until it lands, Directors hand-assemble run directories
  or use whatever ad-hoc orchestration they have.
  """

  alias Glorbo.Filesystem.Frontmatter
  alias Glorbo.Filesystem.FrontmatterWriter
  alias Glorbo.Filesystem.Hierarchy

  @type run_summary :: %{
          required(:run_id) => String.t(),
          required(:template) => String.t() | nil,
          required(:task) => String.t() | nil,
          required(:providers) => [String.t()],
          required(:status) => String.t() | nil,
          required(:started_at) => String.t() | nil,
          required(:completed_at) => String.t() | nil,
          required(:path) => Path.t()
        }

  @type run :: %{
          required(:summary) => run_summary(),
          required(:task_body) => String.t(),
          required(:outputs) => [%{provider: String.t(), body: String.t()}],
          required(:scores_body) => String.t(),
          required(:blind_order) => [String.t()]
        }

  @spec list(keyword()) :: [run_summary()]
  def list(opts \\ []) do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    dir = Path.join([base, "benchmarks", "runs"])

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&read_summary/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.started_at, :desc)

      _ ->
        []
    end
  end

  @spec fetch(String.t(), keyword()) :: {:ok, run()} | {:error, term()}
  def fetch(run_id, opts \\ []) when is_binary(run_id) do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    dir = Path.join([base, "benchmarks", "runs", run_id])

    case read_summary(dir) do
      nil ->
        {:error, :not_found}

      summary ->
        task_body =
          case File.read(Path.join(dir, "task.md")) do
            {:ok, content} ->
              case Frontmatter.parse(content) do
                {:ok, _meta, body} -> body
                _ -> content
              end

            _ ->
              ""
          end

        outputs = read_outputs(dir, summary.providers)
        scores_body = File.read(Path.join(dir, "scores.md")) |> unwrap_body()

        {:ok,
         %{
           summary: summary,
           task_body: task_body,
           outputs: outputs,
           scores_body: scores_body,
           blind_order: blind_order(run_id, summary.providers)
         }}
    end
  end

  @doc """
  Append a Director-ranked scoring event to `scores.md`.

  `ranking` is the provider order from best (index 0) to worst.
  `rationale` is optional free-text prose.
  """
  @spec score(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def score(run_id, ranking, opts \\ []) when is_binary(run_id) and is_list(ranking) do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    actor = Keyword.get(opts, :actor, "director")
    rationale = Keyword.get(opts, :rationale, "")
    dir = Path.join([base, "benchmarks", "runs", run_id])

    with {:ok, summary} <- fetch_summary(dir),
         :ok <- validate_ranking(ranking, summary.providers) do
      scores_path = Path.join(dir, "scores.md")
      new_section = render_score_section(actor, ranking, rationale)

      existing =
        case File.read(scores_path) do
          {:ok, body} -> body
          {:error, :enoent} -> scores_header(summary)
          {:error, reason} -> {:error, reason}
        end

      case existing do
        {:error, reason} ->
          {:error, reason}

        body when is_binary(body) ->
          FrontmatterWriter.atomic_write(
            scores_path,
            String.trim_trailing(body) <> "\n\n" <> new_section <> "\n"
          )
          |> case do
            :ok -> update_manifest_status(dir, "scored")
            other -> other
          end
      end
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp read_summary(dir) do
    manifest_path = Path.join(dir, "manifest.md")

    with true <- File.regular?(manifest_path),
         {:ok, content} <- File.read(manifest_path),
         {:ok, meta, _body} <- Frontmatter.parse(content) do
      %{
        run_id: Path.basename(dir),
        template: Map.get(meta, "template"),
        task: Map.get(meta, "task"),
        providers: providers_list(Map.get(meta, "providers", [])),
        status: Map.get(meta, "status"),
        started_at: Map.get(meta, "started_at"),
        completed_at: Map.get(meta, "completed_at"),
        path: dir
      }
    else
      _ -> nil
    end
  end

  defp fetch_summary(dir) do
    case read_summary(dir) do
      nil -> {:error, :not_found}
      summary -> {:ok, summary}
    end
  end

  defp providers_list(list) when is_list(list) do
    list
    |> Enum.map(fn
      s when is_binary(s) -> s
      a when is_atom(a) -> Atom.to_string(a)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp providers_list(_), do: []

  defp read_outputs(dir, providers) do
    providers
    |> Enum.map(fn provider ->
      path = Path.join([dir, "providers", provider, "output.md"])

      body =
        case File.read(path) do
          {:ok, content} ->
            case Frontmatter.parse(content) do
              {:ok, _meta, payload} -> payload
              _ -> content
            end

          _ ->
            ""
        end

      %{provider: provider, body: body}
    end)
  end

  # Stable-random blind order seeded by the run_id — same Director,
  # same run, same panel order across reloads. Different runs
  # produce different orderings so the Director can't memorise the
  # left-slot = claude mapping.
  defp blind_order(run_id, providers) do
    seed =
      run_id
      |> :erlang.phash2()

    providers
    |> Enum.sort_by(&:erlang.phash2({&1, seed}))
  end

  defp validate_ranking(ranking, providers) do
    ranking_set = MapSet.new(ranking)
    providers_set = MapSet.new(providers)

    cond do
      ranking_set != providers_set ->
        {:error, {:ranking_mismatch, MapSet.to_list(ranking_set), MapSet.to_list(providers_set)}}

      length(ranking) != length(providers) ->
        {:error, {:ranking_duplicates, ranking}}

      true ->
        :ok
    end
  end

  defp scores_header(summary) do
    """
    ---
    kind: benchmark-scores/v1
    run_id: #{summary.run_id}
    ---
    # Scoring history — #{summary.run_id}

    """
  end

  defp render_score_section(actor, ranking, rationale) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    ranking_line =
      ranking
      |> Enum.with_index(1)
      |> Enum.map_join(" · ", fn {provider, rank} -> "#{rank}. #{provider}" end)

    body =
      case String.trim(rationale || "") do
        "" -> ""
        r -> "\n\n#{r}"
      end

    """
    ## #{now} | #{actor}

    **Ranking:** #{ranking_line}#{body}
    """
    |> String.trim_trailing()
  end

  defp update_manifest_status(dir, status) do
    path = Path.join(dir, "manifest.md")

    case FrontmatterWriter.update_keys(path, %{"status" => status}) do
      :ok -> :ok
      {:error, :no_frontmatter} -> :ok
      other -> other
    end
  end

  defp unwrap_body({:ok, content}), do: content
  defp unwrap_body(_), do: ""
end
