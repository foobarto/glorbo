defmodule Glorbo.TaskDefinition do
  @moduledoc """
  Parser for `projects/**/tasks/*.md` task definitions (Plan 03-04).

  Reads a task file, parses YAML frontmatter via `Glorbo.Filesystem.Frontmatter`
  (Phase 2 safe loader — `yamerl` + 10 MB size cap), and coerces the
  `requires_approval` field strictly into `:director | nil`.

  ## Strict vs lenient fields

  Intentional asymmetry:

    * **`requires_approval` is strict.** The only valid values are
      `"director" | :director | nil | false | "false"` (coerces to
      `:director | nil`). Anything else returns
      `{:error, {:invalid_requires_approval, raw}}`. `requires_approval`
      drives the approval gate; ambiguity would hide a security-relevant
      error.
    * **`status` is lenient.** Many values are legitimate across phases
      (`pending | in-progress | completed | blocked | pending-approval |
      approved | denied | reopened | ...`) and Directors may introduce
      custom states. Only `"approved"` and `"denied"` trigger Gate
      actions; everything else is opaque.

  ## Canonical identifiers

    * `task_id` — filename stem (`t-01.md` → `"t-01"`). Used as the
      sentinel filename suffix and the correlation key in audit payloads.
    * `task_path` — path relative to the company dir
      (`projects/foo/tasks/t-01.md`). This is the canonical identifier in
      SQLite's `tasks_approval_state.task_path` column, PubSub topics, and
      audit event payloads. Relative (not absolute) paths decouple the
      system from install location, keeping `glorbo backup` / `restore`
      portable across machines (company isolation is enforced upstream —
      the path always starts with `projects/...`).

  ## Defence-in-depth

    * `path_outside_company` check defends against a caller passing a
      file_path outside the specified company's directory (e.g. pointing
      at another company's task or a Glorbo-internal file). Strict prefix
      match is cheap and prevents action-at-a-distance bugs.
    * No `String.to_atom/1` on user input. `status`, `title`, `assigned_to`,
      `denial_reason` are kept as raw strings; `requires_approval` is
      pattern-matched against a fixed allowlist.
    * Phase 2's safe-loader contract (10 MB cap, yamerl safe mode) is
      inherited — billion-laughs / tag-based RCE gambits are blocked
      upstream.

  ## Usage

      iex> Glorbo.TaskDefinition.parse_file(
      ...>   "/tmp/glorbo/companies/acme/projects/foo/tasks/t-01.md",
      ...>   base: "/tmp/glorbo", company: "acme"
      ...> )
      {:ok, %Glorbo.TaskDefinition{...}}
  """

  alias Glorbo.Filesystem.Frontmatter

  @type approval_mode :: :director | nil

  @type t :: %__MODULE__{
          task_path: String.t(),
          task_id: String.t(),
          title: String.t() | nil,
          status: String.t() | nil,
          assigned_to: String.t() | nil,
          requires_approval: approval_mode(),
          denial_reason: String.t() | nil,
          prompt_body: String.t(),
          file_path: String.t()
        }

  defstruct [
    :task_path,
    :task_id,
    :title,
    :status,
    :assigned_to,
    :requires_approval,
    :denial_reason,
    :prompt_body,
    :file_path
  ]

  @type parse_error ::
          :no_frontmatter
          | :size_limit_exceeded
          | {:yaml_error, term()}
          | {:invalid_requires_approval, term()}
          | {:path_outside_company, String.t()}
          | {:read_error, term()}

  @doc """
  Read and parse a task.md file into a `TaskDefinition`.

  ## Required opts

    * `:base` — absolute path to the Glorbo root (e.g. `~/.glorbo`).
    * `:company` — company slug (e.g. `"acme"`).

  Both are required — `task_path` is derived by stripping
  `<base>/companies/<company>/` from `file_path`, so we need them both to
  compute the canonical relative path. A file_path outside the company
  directory returns `{:error, {:path_outside_company, file_path}}`.
  """
  @spec parse_file(Path.t(), keyword()) :: {:ok, t()} | {:error, parse_error()}
  def parse_file(file_path, opts) when is_binary(file_path) and is_list(opts) do
    base = Keyword.fetch!(opts, :base)
    company = Keyword.fetch!(opts, :company)

    with {:ok, task_path} <- relative_task_path(file_path, base, company),
         {:ok, content} <- read_file(file_path),
         {:ok, meta, body} <- load_frontmatter(content),
         {:ok, partial} <- parse_frontmatter(meta, file_path: file_path) do
      finalize(partial, task_path, body, file_path)
    end
  end

  @doc """
  Pure frontmatter validator — no IO. Useful when content has already
  been read (e.g. tests, or a caller that wants to reuse a parsed meta
  map).

  Returns a partial struct-shaped map (without `task_path`, `prompt_body`,
  `file_path` which are filled in by `parse_file/2`).
  """
  @spec parse_frontmatter(map(), keyword()) :: {:ok, map()} | {:error, parse_error()}
  def parse_frontmatter(meta, opts \\ []) when is_map(meta) do
    file_path = Keyword.get(opts, :file_path, "")

    with {:ok, requires_approval} <- coerce_requires_approval(meta["requires_approval"]) do
      {:ok,
       %{
         task_id: derive_task_id(file_path),
         title: as_string(meta["title"]),
         status: as_string(meta["status"]),
         assigned_to: as_string(meta["assigned_to"]),
         requires_approval: requires_approval,
         denial_reason: as_string(meta["denial_reason"])
       }}
    end
  end

  @doc """
  Whether the task requires Director approval before an agent may execute
  it.
  """
  @spec requires_approval?(t()) :: boolean()
  def requires_approval?(%__MODULE__{requires_approval: :director}), do: true
  def requires_approval?(%__MODULE__{}), do: false

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp relative_task_path(file_path, base, company) do
    prefix = Path.join([base, "companies", company]) <> "/"

    if String.starts_with?(file_path, prefix) do
      {:ok, String.replace_prefix(file_path, prefix, "")}
    else
      {:error, {:path_outside_company, file_path}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_error, reason}}
    end
  end

  # Adapter over `Glorbo.Filesystem.Frontmatter.parse/1`. Translates the
  # Phase 2 error taxonomy into Plan 03-04's locked error shapes:
  #
  #   * Frontmatter {:ok, %{}, body} when no `---` fence → :no_frontmatter
  #   * Frontmatter {:error, :too_large}                → :size_limit_exceeded
  #   * Frontmatter {:error, other}                     → {:yaml_error, other}
  defp load_frontmatter(content) do
    case Frontmatter.parse(content) do
      {:ok, meta, body} when map_size(meta) == 0 and not is_nil(meta) ->
        # Meta is empty. Distinguish "no fence at all" (source didn't
        # start with `---\n`) from "fence present with empty YAML" by
        # checking the body vs the original content — if the body
        # equals the input, there was no fence.
        if body == content do
          {:error, :no_frontmatter}
        else
          {:ok, meta, body}
        end

      {:ok, meta, body} ->
        {:ok, meta, body}

      {:error, :too_large} ->
        {:error, :size_limit_exceeded}

      {:error, reason} ->
        {:error, {:yaml_error, reason}}
    end
  end

  # Locked allowlist (per plan locked_decisions):
  #   "director" | :director       → :director
  #   nil | false | "false"        → nil
  #   anything else                → {:error, {:invalid_requires_approval, raw}}
  defp coerce_requires_approval(nil), do: {:ok, nil}
  defp coerce_requires_approval(false), do: {:ok, nil}
  defp coerce_requires_approval("false"), do: {:ok, nil}
  defp coerce_requires_approval("director"), do: {:ok, :director}
  defp coerce_requires_approval(:director), do: {:ok, :director}
  defp coerce_requires_approval(other), do: {:error, {:invalid_requires_approval, other}}

  defp derive_task_id(""), do: ""
  defp derive_task_id(file_path), do: Path.basename(file_path, ".md")

  defp as_string(nil), do: nil
  defp as_string(str) when is_binary(str), do: str
  # Keep status values lenient — if yaml coerced to integer/bool/etc., stringify.
  defp as_string(other), do: to_string(other)

  defp finalize(partial, task_path, body, file_path) do
    {:ok,
     %__MODULE__{
       task_path: task_path,
       task_id: partial.task_id,
       title: partial.title,
       status: partial.status,
       assigned_to: partial.assigned_to,
       requires_approval: partial.requires_approval,
       denial_reason: partial.denial_reason,
       prompt_body: body || "",
       file_path: file_path
     }}
  end
end
