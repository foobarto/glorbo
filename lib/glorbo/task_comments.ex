defmodule Glorbo.TaskComments do
  @moduledoc """
  Reader + writer for a task's sibling comment thread file
  (GEP-30 D8).

  A task at `companies/<co>/projects/<p>/tasks/<task-id>.md` has
  a sibling thread file at
  `companies/<co>/projects/<p>/tasks/<task-id>.comments.md`.
  The thread file is append-only and uses the same on-disk
  shape as channel logs:

      ---
      kind: task-comments/v1
      task_id: blog-2
      created_at: 2026-04-22T10:00:00Z
      ---
      ## 2026-04-22T10:00:00Z | director
      body…

      ## 2026-04-22T10:12:00Z | ceo
      reply…

  Classification is handled by `Glorbo.FileSpec.TaskCommentsMd`.

  ## Invariants

  * **Elixir is sole writer.** Agents request writes via the
    same Router-relayed path their inbox/mentions flow uses; no
    in-process shortcut.
  * **Append-only.** `append/3` never rewrites history.
  * **No rotation.** Per GEP-30 D14, comment threads are
    bounded by the task lifecycle and stay in one file.
  """

  # Same anchor as ChannelLive — body section between two `## <iso>`
  # headers. Matches `Glorbo.Filesystem.Frontmatter`-style parsing.
  @message_re ~r/^## (?<ts>\d{4}-\d{2}-\d{2}[^|]*?)\s*\|\s*(?<author>.+?)\s*\n(?<body>.*?)(?=\n## \d{4}-|\z)/ms

  @type entry :: %{author: binary(), timestamp: binary(), body: binary()}

  @doc """
  Derive the sibling comments file path from a task file path.

  Accepts absolute paths (`/base/companies/.../tasks/blog-2.md`) or
  relative (`projects/blog/tasks/blog-2.md`). The task must end in
  `.md`.
  """
  @spec path_for(Path.t()) :: Path.t()
  def path_for(task_path) when is_binary(task_path) do
    Path.rootname(task_path) <> ".comments.md"
  end

  @doc """
  Read and parse every entry from a comment thread file.

  Returns `{:ok, [entry]}` even when the file doesn't exist —
  "no thread" is a valid state for a task nobody has commented
  on yet. Returns `{:error, reason}` only for unexpected IO
  failures (permissions, corruption).

  Entries are returned in on-disk (chronological) order.
  """
  @spec read(Path.t()) :: {:ok, [entry]} | {:error, term()}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse(content)}
      {:error, :enoent} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  @doc """
  Append one entry to the thread file, bootstrapping frontmatter
  + a blank-line separator if the file doesn't exist yet.

  The write uses `[:append, :sync]` so crashes don't leave a
  partial entry on disk. Returns `:ok` on success or
  `{:error, reason}` on IO failure.
  """
  @spec append(Path.t(), binary(), binary(), keyword()) :: :ok | {:error, term()}
  def append(path, author, body, opts \\ [])
      when is_binary(path) and is_binary(author) and is_binary(body) do
    ts = Keyword.get_lazy(opts, :ts, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
    task_id = Keyword.get_lazy(opts, :task_id, fn -> derive_task_id(path) end)

    with :ok <- ensure_file(path, task_id) do
      entry = "\n## #{ts} | #{author}\n#{String.trim_trailing(body)}\n"
      File.write(path, entry, [:append, :sync])
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp parse(content) do
    @message_re
    |> Regex.scan(content, capture: :all_names)
    |> Enum.map(fn [author, body, ts] ->
      %{
        author: String.trim(author),
        timestamp: String.trim(ts),
        body: String.trim_trailing(body)
      }
    end)
  end

  # Bootstrap the file with a minimal frontmatter block on first write.
  # If the file already exists we leave it alone — the caller only
  # appends a new entry.
  defp ensure_file(path, task_id) do
    if File.exists?(path) do
      :ok
    else
      ts = DateTime.utc_now() |> DateTime.to_iso8601()

      header = """
      ---
      kind: task-comments/v1
      task_id: #{task_id}
      created_at: #{ts}
      ---
      """

      with :ok <- File.mkdir_p(Path.dirname(path)) do
        File.write(path, header)
      end
    end
  end

  defp derive_task_id(path) do
    path
    |> Path.basename()
    |> String.replace_suffix(".comments.md", "")
  end
end
