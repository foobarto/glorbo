defmodule Glorbo.Agent.Memory do
  @moduledoc """
  Reader for per-agent file-based memory (GEP-21, #281).

  Memory lives at `agents/<slug>/memory/` under the company dir:

      MEMORY.md           — always-loaded index (≤150 chars per line)
      <type>_<topic>.md   — individual memory body files

  Where `<type>` ∈ `user | feedback | project | reference`.

  This module implements the **reading discipline only** (R17 / GEP-21
  first slice). The writing path (agent outbox → Router → atomic
  write → index upsert) ships in a follow-up so the MVP can
  validate prompt composition in production before the write
  contract is sealed.

  ## Compose budget

  Per GEP-21: total 20 KB per prompt. `MEMORY.md` always included
  (small by contract); body files fill the remaining budget
  newest-first by mtime. On overflow, later bodies are skipped and
  a trailing `[N older memories not shown]` line is appended so
  the agent knows truncation happened.

  ## API

      Memory.compose(base, company, agent_slug)
        → {:ok, binary} (may be `""` if no memory dir)

  Never raises — a missing directory, unreadable file, or malformed
  index returns `""` so the caller can splice into the prompt
  unconditionally. Filesystem-is-truth invariant preserved (GEP-3):
  no derived state, every read hits disk.
  """

  @max_total_bytes 20 * 1024
  @max_index_path_bytes 4 * 1024

  @doc """
  Compose the agent's memory section as a single string, capped at
  20 KB. Returns `""` when no `memory/` directory exists or
  everything inside it is unreadable — the caller splices blindly.
  """
  @spec compose(Path.t(), String.t(), String.t()) :: {:ok, binary}
  def compose(base, company, agent_slug)
      when is_binary(base) and is_binary(company) and is_binary(agent_slug) do
    memory_dir = Path.join([base, "companies", company, "agents", agent_slug, "memory"])

    case File.dir?(memory_dir) do
      true -> {:ok, do_compose(memory_dir)}
      false -> {:ok, ""}
    end
  rescue
    _ -> {:ok, ""}
  end

  defp do_compose(memory_dir) do
    index = read_index(memory_dir)
    index_bytes = byte_size(index)

    body_budget = max(@max_total_bytes - index_bytes, 0)
    {bodies, skipped} = collect_bodies(memory_dir, body_budget)

    [
      if(index == "", do: nil, else: "## Index\n\n" <> index),
      if(bodies == [], do: nil, else: Enum.join(bodies, "\n\n")),
      if(skipped > 0, do: "[#{skipped} older memories not shown]", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # Threatmodel: memory files are agent-controlled. The previous
  # `File.read/1` slurped the entire file into RAM before any cap,
  # so a 1 GB MEMORY.md or memory body could OOM the BEAM during a
  # single agent's compose. Pre-check size via lstat and skip
  # anything past `@max_file_bytes`; this caps RAM regardless of
  # what the file contains.
  @max_file_bytes 1_048_576

  defp read_index(memory_dir) do
    path = Path.join(memory_dir, "MEMORY.md")

    if oversize?(path) do
      ""
    else
      case File.read(path) do
        {:ok, content} ->
          content |> String.trim() |> cap(@max_index_path_bytes)

        _ ->
          ""
      end
    end
  end

  defp oversize?(path) do
    case :file.read_link_info(path) do
      {:ok, info} ->
        # info is a tuple-shaped record; size is index 1, type is 2.
        elem(info, 2) != :regular or elem(info, 1) > @max_file_bytes

      _ ->
        true
    end
  end

  defp cap(str, max) do
    case byte_size(str) > max do
      true -> binary_part(str, 0, max) <> "\n\n[index truncated]"
      false -> str
    end
  end

  defp collect_bodies(memory_dir, budget) do
    memory_dir
    |> list_memory_files()
    |> sort_newest_first()
    |> pack_under_budget(budget)
  end

  defp list_memory_files(memory_dir) do
    case File.ls(memory_dir) do
      {:ok, entries} ->
        for e <- entries,
            e != "MEMORY.md",
            String.ends_with?(e, ".md"),
            valid_memory_filename?(e),
            do: Path.join(memory_dir, e)

      _ ->
        []
    end
  end

  @filename_re ~r/^(user|feedback|project|reference)_[a-z][a-z0-9_-]{0,63}\.md$/

  defp valid_memory_filename?(name), do: Regex.match?(@filename_re, name)

  defp sort_newest_first(paths) do
    paths
    |> Enum.map(fn p ->
      case File.stat(p, time: :posix) do
        {:ok, %{mtime: mtime}} -> {mtime, p}
        _ -> {0, p}
      end
    end)
    |> Enum.sort_by(fn {mtime, _} -> -mtime end)
    |> Enum.map(fn {_, p} -> p end)
  end

  defp pack_under_budget(paths, budget) do
    paths
    |> Enum.reduce({[], 0, 0}, &add_path_to_bundle(&1, &2, budget))
    |> then(fn {bodies, _, skipped} -> {bodies, skipped} end)
  end

  # Skip oversized / non-regular files BEFORE reading so the 20 KB
  # output budget can't be subverted by uploading a 1 GB body that
  # gets read into RAM and then discarded.
  defp add_path_to_bundle(path, {acc_bodies, acc_bytes, skipped} = acc, budget) do
    if oversize?(path) do
      {acc_bodies, acc_bytes, skipped + 1}
    else
      append_under_budget(path, acc, budget)
    end
  end

  defp append_under_budget(path, {acc_bodies, acc_bytes, skipped}, budget) do
    case File.read(path) do
      {:ok, content} ->
        section = "### #{Path.basename(path)}\n\n#{String.trim(content)}"
        section_bytes = byte_size(section)
        added = if acc_bodies == [], do: section_bytes, else: section_bytes + 2

        if acc_bytes + added <= budget do
          {acc_bodies ++ [section], acc_bytes + added, skipped}
        else
          {acc_bodies, acc_bytes, skipped + 1}
        end

      _ ->
        {acc_bodies, acc_bytes, skipped + 1}
    end
  end
end
