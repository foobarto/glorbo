defmodule Glorbo.BrainDump do
  @moduledoc """
  Quick-capture daily log for directors (T1-E, queue item #230).

  On-disk format: `companies/<co>/braindump/YYYY-MM-DD.md`. Each capture
  appends a section to the day's file:

      ## 14:32:07 — <first line trimmed>

      <body as typed>

  The file is append-only from the app's perspective (the director can
  still edit by hand — we just never rewrite existing sections). Day
  files are plain markdown so they grep / diff like any other text.

  A capture produces one `braindump.capture` audit event. Conversion to
  a task produces `braindump.convert_to_task` with pointers to both the
  source entry and the created task file.
  """

  @type entry :: %{
          ts: String.t(),
          title: String.t(),
          body: String.t(),
          day: String.t()
        }

  @doc """
  Append a capture to today's brain-dump file.

  Returns `{:ok, entry}` where `entry.ts` is the ISO8601 UTC timestamp
  that uniquely identifies the section within the day file. Body is
  stored verbatim (leading/trailing whitespace trimmed).
  """
  @spec capture(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, entry()} | {:error, term()}
  def capture(base, company, body, opts \\ []) when is_binary(body) do
    body = String.trim(body)

    cond do
      not is_binary(company) or not Glorbo.Slug.valid?(company) ->
        # Gemini round-4 finding (PR #36, LOW defense-in-depth):
        # all live callers (BrainDumpLive, MCP CaptureBrainDump)
        # already gate on Slug.valid? — adding the guard here too
        # so a future caller that forgets the gate can't `..` into
        # `Path.join` via `company: "../../etc"`. Mirrors the
        # round-3 hardening on audit/query, harness/tools.
        {:error, :invalid_company}

      body == "" ->
        {:error, :empty}

      byte_size(body) > 64 * 1024 ->
        {:error, :too_large}

      true ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        do_capture(base, company, body, now)
    end
  end

  defp do_capture(base, company, body, now) do
    dir = dir(base, company)

    history_meta = %{
      actor: Glorbo.HomeHistory.actor_from_string("director"),
      action: "braindump.capture",
      target: "companies/#{company}/braindump"
    }

    history_result =
      Glorbo.HomeHistory.Tx.with_tx(history_meta, fn tx_id ->
        with :ok <- ensure_safe_dir(dir),
             day <- date_string(now),
             path <- Path.join(dir, "#{day}.md"),
             :ok <- ensure_regular_file(path),
             :ok <- File.mkdir_p(dir) do
          do_capture_append(tx_id, path, body, now, day)
        end
      end)

    case history_result do
      # `with_tx` unwraps one `:ok` layer: if the body returns
      # `{:ok, entry}` it produces `{:ok, entry, tx_id}`.
      {:ok, entry, _tx_id} when is_map(entry) -> {:ok, entry}
      {:error, _} = err -> err
    end
  end

  defp do_capture_append(tx_id, path, body, now, day) do
    title = derive_title(body)
    ts = time_string(now)

    section = "\n## #{ts} — #{title}\n\n#{body}\n"
    existing? = File.regular?(path)

    header =
      if existing? do
        ""
      else
        """
        ---
        kind: braindump/v1
        created_at: #{DateTime.to_iso8601(DateTime.truncate(now, :second))}
        ---
        # Brain dump · #{day}
        """
      end

    with :ok <- File.write(path, header <> section, [:append]),
         :ok <- Glorbo.HomeHistory.Tx.mark_path(tx_id, path) do
      {:ok,
       %{
         ts: DateTime.to_iso8601(DateTime.truncate(now, :second)),
         title: title,
         body: body,
         day: day
       }}
    end
  end

  @doc """
  List all captured entries for a company, newest first, optionally
  limited to the last N days.
  """
  @spec list(Path.t(), String.t(), keyword()) :: [entry()]
  def list(base, company, opts \\ [])

  def list(base, company, opts) when is_binary(company) do
    if Glorbo.Slug.valid?(company), do: do_list(base, company, opts), else: []
  end

  # Copilot review on PR #36: non-binary `company` used to raise
  # `FunctionClauseError`. Module is intentional fail-safe — return
  # an empty list rather than crashing callers.
  def list(_base, _company, _opts), do: []

  defp do_list(base, company, opts) do
    limit_days = Keyword.get(opts, :limit_days, 14)
    dir = dir(base, company)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort(:desc)
        |> Enum.take(limit_days)
        |> Enum.flat_map(&read_day(dir, &1))

      _ ->
        []
    end
  end

  @doc """
  Convert a captured entry to a task under `projects/inbox/tasks/`.
  The task is scaffolded with `source: braindump`, `braindump_ts`
  pointing back at the original section, and a status of `todo`.
  Returns the relative task path (e.g. `projects/inbox/tasks/t-…`).
  """
  @spec convert_to_task(Path.t(), String.t(), entry()) ::
          {:ok, String.t()} | {:error, term()}
  def convert_to_task(base, company, entry)

  def convert_to_task(base, company, entry) when is_binary(company) do
    if Glorbo.Slug.valid?(company) do
      do_convert_to_task(base, company, entry)
    else
      {:error, :invalid_company}
    end
  end

  # Copilot review on PR #36: non-binary `company` used to raise
  # `FunctionClauseError`. Return the same error shape as the
  # invalid-slug branch.
  def convert_to_task(_base, _company, _entry), do: {:error, :invalid_company}

  defp do_convert_to_task(base, company, entry) do
    co_dir = Path.join([base, "companies", company])
    project = "inbox"
    project_dir = Path.join([co_dir, "projects", project])
    tasks_dir = Path.join(project_dir, "tasks")

    with :ok <- ensure_safe_dir(project_dir),
         :ok <- ensure_safe_dir(tasks_dir),
         :ok <- File.mkdir_p(tasks_dir) do
      do_convert_to_task(tasks_dir, project, entry, base, company)
    end
  end

  defp do_convert_to_task(tasks_dir, project, entry, base, company) do
    task_id = task_id_for(tasks_dir, entry)
    filename = "#{task_id}.md"
    abs = Path.join(tasks_dir, filename)
    rel = Path.join(["projects", project, "tasks", filename])

    content = render_task(task_id, entry)

    case File.exists?(abs) do
      true ->
        {:error, :already_exists}

      false ->
        # Wave 24: drop the lstat on the predictable `<> ".tmp"` —
        # write_atomic now uses a crypto-random tmp + exclusive open
        # so the predictable-tmp lstat check is moot.
        with :ok <- ensure_regular_file(abs),
             {:ok, ^rel} <- write_atomic(abs, content, rel) do
          # Best-effort — a task was successfully written; leaving the
          # brain-dump note in place would let the user convert it a
          # second time and create a duplicate task. The failure mode
          # if the delete fails (permissions, racing editor) is
          # benign: the user sees the note and can delete it manually.
          _ = delete_entry(base, company, entry)
          {:ok, rel}
        end
    end
  end

  @doc """
  Remove a single captured section from its day file. No-ops if the
  file no longer exists or the section is not present.
  """
  @spec delete_entry(Path.t(), String.t(), entry()) :: :ok | {:error, term()}
  def delete_entry(base, company, entry) do
    dir = dir(base, company)
    filename = "#{entry.day}.md"
    path = Path.join(dir, filename)

    case File.read(path) do
      {:ok, content} -> apply_section_removal(path, content, entry)
      {:error, :enoent} -> :ok
      err -> err
    end
  end

  defp apply_section_removal(path, content, entry) do
    new_content = remove_section(content, entry)

    cond do
      new_content == content ->
        :ok

      String.trim(new_content) == "" ->
        File.rm(path)

      true ->
        # Threatmodel wave 24: random suffix + exclusive open.
        rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
        tmp = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}-#{rand_suffix}"

        with :ok <- ensure_regular_file(path) do
          case do_atomic_open(tmp, path, new_content, :ok) do
            {:ok, _} -> :ok
            err -> err
          end
        end
    end
  end

  # Strip the section whose header matches the entry's time + title.
  # Splits into (preamble, [header_line × body] sections) and filters
  # out the matching one. Boundaries come from the same regex the
  # reader uses so writer/reader/remover stay aligned.
  defp remove_section(content, entry) do
    time = String.slice(entry.ts, 11, 8)
    title = String.trim(entry.title)

    {preamble, sections} = split_sections(content)

    kept =
      Enum.reject(sections, fn {t, name, _body} ->
        t == time and String.trim(name) == title
      end)

    preamble <> Enum.map_join(kept, "", &render_section/1)
  end

  defp render_section({time, name, body}), do: "## #{time} — #{name}\n" <> body

  # Returns {preamble_text, [{time, title, body_incl_leading_newline}]}
  defp split_sections(content) do
    parts = Regex.split(~r/^## (\d{2}:\d{2}:\d{2})\s+—\s+(.+)$/m, content, include_captures: true)

    case parts do
      [preamble | rest] ->
        {preamble, group_sections(rest, [])}

      [] ->
        {content, []}
    end
  end

  defp group_sections([], acc), do: Enum.reverse(acc)

  defp group_sections([header_line, body | rest], acc) do
    case Regex.run(~r/^## (\d{2}:\d{2}:\d{2})\s+—\s+(.+)$/m, header_line) do
      [_full, time, name] -> group_sections(rest, [{time, name, body} | acc])
      _ -> group_sections(rest, acc)
    end
  end

  defp group_sections([_trailing], acc), do: Enum.reverse(acc)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp dir(base, company), do: Path.join([base, "companies", company, "braindump"])

  defp date_string(dt), do: Date.to_iso8601(DateTime.to_date(dt))

  defp time_string(dt) do
    dt
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_iso8601()
  end

  defp derive_title(body) do
    body
    |> String.split("\n", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> String.slice(0, 80)
  end

  # Codex round-6 finding (PR #38, MED): the previous shape used
  # bare `File.read` on each braindump day file. The braindump
  # dir is currently director-only-writable (no agent permission
  # tier maps to it), but a previous symlink-plant by some other
  # escape route would slurp through. `convert_to_task/3` already
  # proves the discipline via `ensure_safe_dir`; the list/read
  # path was unguarded. Cap the read AND require canonical
  # `YYYY-MM-DD.md` filename — anything else is a malformed leak
  # vector even via the legitimate write path.
  @brain_dump_file_byte_cap 1_048_576
  @brain_dump_day_re ~r/\A\d{4}-\d{2}-\d{2}\.md\z/

  defp read_day(dir, filename) do
    if Regex.match?(@brain_dump_day_re, filename) do
      day = Path.basename(filename, ".md")
      path = Path.join(dir, filename)

      case Glorbo.Filesystem.AgentWritableFile.read_bounded(
             path,
             @brain_dump_file_byte_cap
           ) do
        {:ok, content} -> parse_sections(content, day)
        _ -> []
      end
    else
      []
    end
  end

  defp parse_sections(content, day) do
    # Split on the header while keeping the matched line. Result shape:
    # [leading_text, header1, body1, header2, body2, ...] — we want the
    # (header, body) pairs. `Regex.scan` gives us the header captures,
    # `Regex.split` gives the bodies — zip them.
    headers = Regex.scan(~r/^## (\d{2}:\d{2}:\d{2})\s+—\s+(.+)$/m, content)
    bodies = Regex.split(~r/^## (\d{2}:\d{2}:\d{2})\s+—\s+(.+)$/m, content)

    # Drop the pre-first-header chunk. `split` without include_captures
    # yields N+1 parts where N is the number of headers.
    body_parts = Enum.drop(bodies, 1)

    headers
    |> Enum.zip(body_parts)
    |> Enum.map(fn {[_full, time, title], body} -> build_entry(day, time, title, body) end)
    |> Enum.reverse()
  end

  defp build_entry(day, time, title, body) do
    %{
      ts: "#{day}T#{time}Z",
      title: String.trim(title),
      body: String.trim(body),
      day: day
    }
  end

  # Task IDs follow GEP-13's `<project>-NN` convention so every
  # standard route that parses task IDs (TaskLive, Router,
  # assignment mentions) accepts them without a special case.
  # Provenance back to the original brain-dump entry is preserved in
  # the task's frontmatter (`source: braindump`, `braindump_ts`)
  # rather than the filename.
  defp task_id_for(tasks_dir, _entry) do
    project = "inbox"
    prefixed_re = ~r/\A#{Regex.escape(project)}-(\d+)\.md\z/
    legacy_re = ~r/\At-(\d+)\.md\z/

    max_n =
      case File.ls(tasks_dir) do
        {:ok, files} ->
          files
          |> Enum.map(fn f -> Regex.run(prefixed_re, f) || Regex.run(legacy_re, f) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn [_, n] -> String.to_integer(n) end)
          |> Enum.max(fn -> 0 end)

        _ ->
          0
      end

    next = max_n + 1

    n_str =
      if next <= 99,
        do: String.pad_leading(Integer.to_string(next), 2, "0"),
        else: Integer.to_string(next)

    "#{project}-#{n_str}"
  end

  defp render_task(_task_id, entry) do
    """
    ---
    kind: task/v1
    title: #{escape(entry.title)}
    status: todo
    source: braindump
    braindump_ts: #{entry.ts}
    ---

    #{entry.body}

    ## Context

    Converted from brain dump entry `#{entry.ts}` (#{entry.day}).
    """
  end

  defp escape(value) do
    if String.contains?(value, [":", "#", "\""]) do
      "\"" <> String.replace(value, "\"", "\\\"") <> "\""
    else
      value
    end
  end

  # Threatmodel wave 24: random suffix + exclusive open closes the
  # TOCTOU race the prior `<> ".tmp"` flow had in agent-RW dirs.
  defp write_atomic(abs, content, rel) do
    rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp = "#{abs}.tmp-#{System.unique_integer([:positive, :monotonic])}-#{rand_suffix}"
    do_atomic_open(tmp, abs, content, rel)
  end

  defp do_atomic_open(tmp, abs, content, rel) do
    case :file.open(tmp, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} -> finalize_atomic(fd, tmp, abs, content, rel)
      {:error, _} = err -> err
    end
  end

  defp finalize_atomic(fd, tmp, abs, content, rel) do
    case :file.write(fd, content) do
      :ok ->
        :ok = :file.close(fd)

        case File.rename(tmp, abs) do
          :ok ->
            {:ok, rel}

          {:error, _} = err ->
            _ = File.rm(tmp)
            err
        end

      {:error, _} = err ->
        :ok = :file.close(fd)
        _ = File.rm(tmp)
        err
    end
  end

  # threatmodel H7: delegate to the canonical AgentWritableFile seam.
  defp ensure_regular_file(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok -> :ok
      {:error, {:not_regular_file, _}} -> {:error, :not_a_regular_file}
      {:error, {:stat_failed, reason}} -> {:error, reason}
    end
  end

  # B-016: Refuse to operate inside a braindump/tasks directory that
  # was swapped for a symlink to somewhere else on disk. The old
  # leaf-only `File.lstat` caught `projects/inbox/tasks` itself being a
  # symlink, but a `projects:write:*` agent can plant a symlinked
  # *parent* (`projects/inbox -> ../../<other-co>/projects/evil`) which
  # the leaf lstat follows. Walk every ancestor segment via the
  # canonical `any_symlink_in_path?/1` seam (used by Router + Actions.Tasks).
  defp ensure_safe_dir(path) do
    if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(path) do
      {:error, :symlink_in_path}
    else
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, %File.Stat{}} -> {:error, :not_a_directory}
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
