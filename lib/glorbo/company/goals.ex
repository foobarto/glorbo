defmodule Glorbo.Company.Goals do
  @moduledoc """
  The canonical goal store (GEP-63): one `goal/v1` file per goal under
  `companies/<co>/goals/<id>.md`.

  * `list/1` is the single hardened loader the three goals LiveViews
    (`GoalsLive`, `CompanyLive`, `OverviewLive`) call — collapsing the
    three near-duplicate `normalize_goal/1` readers that used to drift.
  * `add_goal/3` writes a new `goals/<id>.md` file (no more `company.md`
    frontmatter splicing) via `FileSpec.Formatter` + the existing atomic
    tmp+rename inside a HomeHistory transaction.

  `id` is the one identifier (Decision D1): it is the filename basename,
  the `task/v1` `goal:` join key, and the Kanban `?goal=<id>` value.
  """

  alias Glorbo.Filesystem.AgentWritableFile
  alias Glorbo.Filesystem.Frontmatter
  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx

  # `goals/` is a newly-enumerated, agent-writable directory, so the
  # loader applies the same hardening as the task readers: a 1 MiB
  # read cap (planted multi-GB / device files refused before slurping
  # into the dashboard heap).
  @goal_byte_cap 1_048_576

  # `id` doubles as a path component AND the goal filename, so it must
  # satisfy the strict slug shape (leading lowercase letter, then
  # lowercase / digit / hyphen, ≤64 chars) before `Path.join` touches
  # it. This is the single id shape the writer enforces, the loader
  # gates filenames against, and `GoalMd` specs — loader and writer
  # agree on exactly what a valid id is. `\A..\z` (not `^..$`) so a
  # trailing newline can never sneak past the anchors.
  @id_regex ~r/\A[a-z][a-z0-9-]{0,63}\z/

  @type goal :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          optional(:description) => String.t()
        }

  @typedoc """
  A goal as the LiveViews consume it. `title` is a display field
  (`name` || `id`); `id` is the identifier. `progress` is `nil` unless
  the file carries an explicit in-range integer.
  """
  @type loaded :: %{
          id: String.t(),
          title: String.t(),
          description: String.t(),
          status: String.t(),
          progress: non_neg_integer() | nil
        }

  # ---------------------------------------------------------------------------
  # Shared loader
  # ---------------------------------------------------------------------------

  @doc """
  List the company's goals, newest-on-disk order normalised to a stable
  sort by `id`. Reads every `goals/*.md` file under `company_dir`.

  Hardened (mirrors the task readers): refuses a symlinked `goals/`
  dir, gates each filename through the strict `@id_regex`, reads through
  the lstat + size-capped reader, requires `kind: goal/v1`, and coerces
  every field to a safe scalar. Malformed / wrong-kind / symlinked /
  oversized / non-slug-named files are skipped silently (no broken card,
  no crash). A missing `goals/` dir yields `[]`.
  """
  @spec list(Path.t()) :: [loaded()]
  def list(company_dir) when is_binary(company_dir) do
    goals_dir = Path.join(company_dir, "goals")

    if real_directory?(goals_dir) do
      case File.ls(goals_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&load_goal_file(goals_dir, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.id)

        _ ->
          []
      end
    else
      []
    end
  end

  defp load_goal_file(goals_dir, filename) do
    id = Path.rootname(filename)

    # Filename is the canonical id (filename wins over a mismatched
    # `id:` field, preserving the task-link invariant). Gate it on the
    # strict `@id_regex` — the SAME shape the writer enforces — so a
    # weird name an agent plants in this RW dir (`123.md`, `-evil.md`,
    # a 500-char name) can't surface a card the add-goal form could
    # never create.
    if Regex.match?(@id_regex, id) do
      path = Path.join(goals_dir, filename)

      # Require `kind: goal/v1`: this dir is agent-writable, so a
      # scratch note (no frontmatter → parses to an empty map), a
      # misfiled `task/v1`, or any other stray `.md` must NOT render as
      # a phantom goal card. Malformed / wrong-kind / fence-less files
      # all fall through to `nil` (skipped silently).
      with {:ok, content} <- AgentWritableFile.read_bounded(path, @goal_byte_cap),
           {:ok, %{"kind" => "goal/v1"} = fm, _body} <- Frontmatter.parse(content) do
        normalize(id, fm)
      else
        _ -> nil
      end
    end
  end

  defp normalize(id, fm) do
    name = safe_scalar(fm["name"])

    %{
      id: id,
      title: if(name == "", do: id, else: name),
      description: safe_scalar(fm["description"]),
      status: status_or_default(fm["status"]),
      progress: safe_progress(fm["progress"])
    }
  end

  # Preserve a scalar status verbatim (the Validator enforces the
  # enum on `glorbo validate`; the UI just maps it to a badge class).
  # Default to "active" only for an empty / non-scalar value.
  defp status_or_default(v) do
    case safe_scalar(v) do
      "" -> "active"
      s -> s
    end
  end

  # Explicit progress wins only when it is a genuine integer in 0..100.
  # A string `"60"`, out-of-range, or a map/list reads as "unspecified"
  # → callers derive from linked tasks.
  defp safe_progress(v) when is_integer(v) and v >= 0 and v <= 100, do: v
  defp safe_progress(_), do: nil

  # Agent-controlled YAML can set a field to a map / list, which would
  # crash `to_string/1`. Coerce only scalars.
  defp safe_scalar(v) when is_binary(v), do: v
  defp safe_scalar(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp safe_scalar(v) when is_number(v), do: to_string(v)
  defp safe_scalar(_), do: ""

  # lstat-refuse a symlinked `goals/` dir (mirrors the Codex PR#38
  # symlink-ancestor guard the task readers use).
  defp real_directory?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Writer
  # ---------------------------------------------------------------------------

  @doc """
  Create a new goal as `companies/<co>/goals/<id>.md`.

  `company_dir` is the company directory (e.g.
  `~/.glorbo/companies/acme`). The goal map carries `id`, `name`, and
  an optional `description`; new goals start `status: active`.
  Uniqueness is `File.exists?` on the target file. The write lands
  atomically (canonicalised via `FileSpec.Formatter`, then tmp+rename)
  inside a HomeHistory transaction with action `goal.create`.

  Goals are Director-only today (only caller is `GoalsLive`); pass
  `actor:` to override for a future MCP / agent-initiated flow.
  """
  @spec add_goal(Path.t(), goal, keyword()) :: :ok | {:error, term()}
  def add_goal(company_dir, goal, opts \\ []) when is_binary(company_dir) do
    id = String.trim(to_string(goal[:id] || ""))
    name = String.trim(to_string(goal[:name] || ""))
    description = String.trim(to_string(goal[:description] || ""))

    actor = Keyword.get(opts, :actor, "director")
    goal_path = Path.join([company_dir, "goals", "#{id}.md"])

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "goal.create",
      target: rel_path_for_history(goal_path, opts)
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        cond do
          id == "" -> {:error, :id_required}
          not Regex.match?(@id_regex, id) -> {:error, :invalid_id}
          name == "" -> {:error, :name_required}
          File.exists?(goal_path) -> {:error, :id_taken}
          true -> do_write_goal(tx_id, company_dir, goal_path, id, name, description)
        end
      end)

    case history_result do
      {:ok, :ok, _tx_id} -> :ok
      {:error, _} = err -> err
    end
  end

  defp do_write_goal(tx_id, company_dir, goal_path, id, name, description) do
    raw = build_goal_content(id, name, description)

    with :ok <- File.mkdir_p(Path.join(company_dir, "goals")),
         {:ok, _change, content} <- Glorbo.FileSpec.Formatter.format_content(goal_path, raw) do
      atomic_open_and_rename(tx_id, goal_path, content)
    end
  end

  # Build the goal/v1 frontmatter in canonical order; the Formatter
  # re-canonicalises it anyway, so order here is only for clarity.
  defp build_goal_content(id, name, description) do
    desc_line =
      if description == "", do: [], else: ["description: #{yaml_scalar(description)}"]

    lines =
      ["kind: goal/v1", "id: #{id}", "name: #{yaml_scalar(name)}"] ++
        desc_line ++ ["status: active"]

    "---\n" <> Enum.join(lines, "\n") <> "\n---\n"
  end

  # Wave 24: random suffix + `:file.open([:exclusive])` closes the
  # predictable-`<> ".tmp"` race.
  defp atomic_open_and_rename(tx_id, goal_path, new_content) do
    rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    tmp =
      "#{goal_path}.tmp-#{System.unique_integer([:positive, :monotonic])}-#{rand_suffix}"

    case :file.open(tmp, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} -> write_then_rename(fd, tmp, goal_path, new_content, tx_id)
      {:error, _} = err -> err
    end
  end

  defp write_then_rename(fd, tmp, goal_path, new_content, tx_id) do
    case :file.write(fd, new_content) do
      :ok ->
        :ok = :file.close(fd)
        finalize_rename(tmp, goal_path, tx_id)

      {:error, _} = err ->
        :ok = :file.close(fd)
        _ = File.rm(tmp)
        err
    end
  end

  defp finalize_rename(tmp, goal_path, tx_id) do
    case File.rename(tmp, goal_path) do
      :ok ->
        Tx.mark_path(tx_id, goal_path)

      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  # The history `target` field wants a relative-to-base path. Absent an
  # explicit `:base` opt we use the path as-is (Tx.with_tx handles
  # "history disabled" silently, so a non-relativised target only
  # affects the §4.3 trailer cosmetics).
  defp rel_path_for_history(goal_path, opts) do
    case Keyword.get(opts, :base) do
      nil ->
        goal_path

      base when is_binary(base) ->
        case Path.relative_to(goal_path, base) do
          ^goal_path -> goal_path
          rel -> rel
        end
    end
  end

  defp yaml_scalar(s), do: Glorbo.Filesystem.FrontmatterWriter.yaml_scalar(s)
end
