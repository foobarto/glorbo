defmodule Glorbo.Company.Goals do
  @moduledoc """
  Append a new goal to `company.md` without disturbing the rest of
  its frontmatter.

  `add_goal/2` does a textual splice rather than a full YAML round-trip
  so comments, key order, and unknown-to-us fields are preserved. The
  frontmatter must already be delimited with `---` on its own lines,
  which is the convention `mix glorbo.init` and every user-visible
  write path produces.
  """

  alias Glorbo.Filesystem.Frontmatter
  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx

  @type goal :: %{
          required(:slug) => String.t(),
          required(:title) => String.t(),
          optional(:description) => String.t()
        }

  @spec add_goal(Path.t(), goal, keyword()) :: :ok | {:error, term()}
  def add_goal(company_md_path, goal, opts \\ []) do
    slug = String.trim(to_string(goal[:slug] || ""))
    title = String.trim(to_string(goal[:title] || ""))
    description = String.trim(to_string(goal[:description] || ""))

    # Goals are Director-only today (only caller is GoalsLive); the
    # actor opt is a future seam for non-Director callers (e.g., MCP
    # tool, agent-initiated proposal flow). Pass `actor:` to override.
    actor = Keyword.get(opts, :actor, "director")

    history_meta = %{
      actor: HomeHistory.actor_from_string(actor),
      action: "company.add_goal",
      target: rel_path_for_history(company_md_path, opts)
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        cond do
          slug == "" ->
            {:error, :slug_required}

          not Regex.match?(~r/^[a-z][a-z0-9-]{0,63}$/, slug) ->
            {:error, :invalid_slug}

          title == "" ->
            {:error, :title_required}

          true ->
            do_add_goal_write(
              tx_id,
              company_md_path,
              slug,
              title,
              description
            )
        end
      end)

    case history_result do
      {:ok, :ok, _tx_id} -> :ok
      {:error, _} = err -> err
    end
  end

  defp do_add_goal_write(tx_id, company_md_path, slug, title, description) do
    with {:ok, content} <- File.read(company_md_path),
         :ok <- check_slug_unique(content, slug) do
      new_content = splice_goal(content, slug, title, description)
      atomic_open_and_rename(tx_id, company_md_path, new_content)
    end
  end

  # Wave 24: random suffix + `:file.open([:exclusive])` closes the
  # predictable-`<> ".tmp"` race.
  defp atomic_open_and_rename(tx_id, company_md_path, new_content) do
    rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    tmp =
      "#{company_md_path}.tmp-#{System.unique_integer([:positive, :monotonic])}-#{rand_suffix}"

    case :file.open(tmp, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} -> write_then_rename(fd, tmp, company_md_path, new_content, tx_id)
      {:error, _} = err -> err
    end
  end

  defp write_then_rename(fd, tmp, company_md_path, new_content, tx_id) do
    case :file.write(fd, new_content) do
      :ok ->
        :ok = :file.close(fd)
        finalize_rename(tmp, company_md_path, tx_id)

      {:error, _} = err ->
        :ok = :file.close(fd)
        _ = File.rm(tmp)
        err
    end
  end

  defp finalize_rename(tmp, company_md_path, tx_id) do
    case File.rename(tmp, company_md_path) do
      :ok ->
        Tx.mark_path(tx_id, company_md_path)

      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  # The history `target` field wants a relative-to-base path. The
  # caller hands us the absolute company_md_path; absent an explicit
  # `:base` opt we use the path as-is (Tx.with_tx handles "history
  # disabled" silently anyway, so a non-relativised target only
  # matters for the §4.3 trailer cosmetics).
  defp rel_path_for_history(company_md_path, opts) do
    case Keyword.get(opts, :base) do
      nil ->
        company_md_path

      base when is_binary(base) ->
        case Path.relative_to(company_md_path, base) do
          ^company_md_path -> company_md_path
          rel -> rel
        end
    end
  end

  defp check_slug_unique(content, slug) do
    case Frontmatter.parse(content) do
      {:ok, %{"goals" => goals}, _} when is_list(goals) ->
        taken? =
          Enum.any?(goals, fn g ->
            is_map(g) and to_string(Map.get(g, "slug", "")) == slug
          end)

        if taken?, do: {:error, :slug_taken}, else: :ok

      _ ->
        :ok
    end
  end

  defp splice_goal(content, slug, title, description) do
    item_lines = render_item_lines(slug, title, description)

    case split_frontmatter(content) do
      {:ok, pre_fence, fm_body, post_fence} ->
        new_fm_body = insert_into_fm(fm_body, item_lines)
        pre_fence <> new_fm_body <> post_fence

      :error ->
        ("---\ngoals:\n" <> Enum.join(item_lines, "\n") <> "\n---\n\n") <> content
    end
  end

  # fm_body is the frontmatter between the fences, without the fences
  # themselves. It ends with a newline (or is empty).
  defp insert_into_fm(fm_body, item_lines) do
    lines = String.split(fm_body, "\n")
    # split_frontmatter keeps a trailing empty element from the final \n;
    # drop it so we don't accidentally land an item after a blank line.
    {body_lines, trailing_empty} =
      case List.last(lines) do
        "" -> {Enum.drop(lines, -1), true}
        _ -> {lines, false}
      end

    new_body_lines = splice_lines(body_lines, item_lines)

    joined = Enum.join(new_body_lines, "\n")
    if trailing_empty, do: joined <> "\n", else: joined
  end

  defp splice_lines(lines, item_lines) do
    case Enum.find_index(lines, &String.match?(&1, ~r/^goals:\s*$/)) do
      nil ->
        lines ++ ["goals:"] ++ item_lines

      idx ->
        {before, [goals_head | rest]} = Enum.split(lines, idx)

        {items, after_block} =
          Enum.split_while(rest, fn line ->
            line == "" or String.starts_with?(line, " ") or String.starts_with?(line, "\t")
          end)

        before ++ [goals_head] ++ items ++ item_lines ++ after_block
    end
  end

  defp split_frontmatter(content) do
    case Regex.run(~r/\A(---\r?\n)(.*?)(^---\r?\n)/ms, content, return: :index) do
      [{0, open_len}, {body_start, body_len}, {close_start, _close_len}] ->
        pre = binary_part(content, 0, open_len)
        fm_body = binary_part(content, body_start, body_len)
        post = binary_part(content, close_start, byte_size(content) - close_start)
        {:ok, pre, fm_body, post}

      _ ->
        :error
    end
  end

  defp render_item_lines(slug, title, description) do
    [
      "  - slug: #{yaml_scalar(slug)}",
      "    title: #{yaml_scalar(title)}"
    ] ++
      if description == "", do: [], else: ["    description: #{yaml_scalar(description)}"]
  end

  defp yaml_scalar(s), do: Glorbo.Filesystem.FrontmatterWriter.yaml_scalar(s)
end
