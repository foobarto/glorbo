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

  @type goal :: %{
          required(:slug) => String.t(),
          required(:title) => String.t(),
          optional(:description) => String.t()
        }

  @spec add_goal(Path.t(), goal) :: :ok | {:error, term()}
  def add_goal(company_md_path, goal) do
    slug = String.trim(to_string(goal[:slug] || ""))
    title = String.trim(to_string(goal[:title] || ""))
    description = String.trim(to_string(goal[:description] || ""))

    cond do
      slug == "" ->
        {:error, :slug_required}

      not Regex.match?(~r/^[a-z][a-z0-9-]{0,63}$/, slug) ->
        {:error, :invalid_slug}

      title == "" ->
        {:error, :title_required}

      true ->
        with {:ok, content} <- File.read(company_md_path),
             :ok <- check_slug_unique(content, slug) do
          new_content = splice_goal(content, slug, title, description)
          tmp = company_md_path <> ".tmp"

          with :ok <- File.write(tmp, new_content) do
            File.rename(tmp, company_md_path)
          end
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

  defp yaml_scalar(s) do
    needs_quote? =
      String.contains?(s, [":", "#", "[", "]", "\"", "'", "\n"]) or
        String.starts_with?(s, " ") or String.ends_with?(s, " ")

    if needs_quote? do
      ~s("#{String.replace(s, "\"", "\\\"")}")
    else
      s
    end
  end
end
