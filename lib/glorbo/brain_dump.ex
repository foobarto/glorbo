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
    File.mkdir_p!(dir)

    day = date_string(now)
    path = Path.join(dir, "#{day}.md")
    title = derive_title(body)
    ts = time_string(now)

    section = "\n## #{ts} — #{title}\n\n#{body}\n"
    existing? = File.exists?(path)
    header = if existing?, do: "", else: "# Brain dump · #{day}\n"
    :ok = File.write!(path, header <> section, [:append])

    {:ok,
     %{
       ts: DateTime.to_iso8601(DateTime.truncate(now, :second)),
       title: title,
       body: body,
       day: day
     }}
  end

  @doc """
  List all captured entries for a company, newest first, optionally
  limited to the last N days.
  """
  @spec list(Path.t(), String.t(), keyword()) :: [entry()]
  def list(base, company, opts \\ []) do
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
  def convert_to_task(base, company, entry) do
    co_dir = Path.join([base, "companies", company])
    project = "inbox"
    project_dir = Path.join([co_dir, "projects", project])
    tasks_dir = Path.join(project_dir, "tasks")
    File.mkdir_p!(tasks_dir)

    task_id = task_id_for(tasks_dir, entry)
    filename = "#{task_id}.md"
    abs = Path.join(tasks_dir, filename)
    rel = Path.join(["projects", project, "tasks", filename])

    content = render_task(task_id, entry)

    case File.exists?(abs) do
      true -> {:error, :already_exists}
      false -> write_atomic(abs, content, rel)
    end
  end

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

  defp read_day(dir, filename) do
    day = Path.basename(filename, ".md")
    path = Path.join(dir, filename)

    case File.read(path) do
      {:ok, content} -> parse_sections(content, day)
      _ -> []
    end
  end

  @section_regex ~r/^## (\d{2}:\d{2}:\d{2})\s+—\s+(.+)$/m

  defp parse_sections(content, day) do
    # Split on the header while keeping the matched line. Result shape:
    # [leading_text, header1, body1, header2, body2, ...] — we want the
    # (header, body) pairs. `Regex.scan` gives us the header captures,
    # `Regex.split` gives the bodies — zip them.
    headers = Regex.scan(@section_regex, content)
    bodies = Regex.split(@section_regex, content)

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

  defp task_id_for(tasks_dir, entry) do
    slug_part = slugify(entry.title)
    base_id = "t-bd-#{entry.day}-#{slug_part}"
    uniqify(tasks_dir, base_id, 0)
  end

  defp uniqify(tasks_dir, base_id, suffix) do
    candidate =
      case suffix do
        0 -> base_id
        n -> "#{base_id}-#{n}"
      end

    if File.exists?(Path.join(tasks_dir, "#{candidate}.md")) do
      uniqify(tasks_dir, base_id, suffix + 1)
    else
      candidate
    end
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "entry"
      s -> s
    end
  end

  defp render_task(_task_id, entry) do
    """
    ---
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

  defp write_atomic(abs, content, rel) do
    tmp = abs <> ".tmp"
    :ok = File.write!(tmp, content)
    :ok = File.rename(tmp, abs)
    {:ok, rel}
  rescue
    e -> {:error, e}
  end
end
