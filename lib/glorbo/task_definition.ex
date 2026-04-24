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
    * No atom coercion on user input. `status`, `title`, `assigned_to`,
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

  @type priority :: :low | :medium | :high | nil
  @type severity :: :info | :minor | :major | :critical | nil

  @type handoff_entry :: %{
          required(:ts) => String.t(),
          required(:from) => String.t(),
          required(:to) => String.t(),
          required(:reason) => String.t()
        }

  @type t :: %__MODULE__{
          task_path: String.t(),
          task_id: String.t(),
          title: String.t() | nil,
          status: String.t() | nil,
          assigned_to: String.t() | nil,
          requested_by: String.t() | nil,
          requires_approval: approval_mode(),
          denial_reason: String.t() | nil,
          priority: priority(),
          severity: severity(),
          peer_review_required: boolean(),
          reviewer: String.t() | nil,
          done_when: String.t() | nil,
          handoff_chain: [handoff_entry()],
          project: String.t() | nil,
          goal: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | nil,
          schedule: String.t() | nil,
          budget_usd_cents: non_neg_integer() | nil,
          prompt_body: String.t(),
          file_path: String.t()
        }

  defstruct task_path: nil,
            task_id: nil,
            title: nil,
            status: nil,
            assigned_to: nil,
            requested_by: nil,
            requires_approval: nil,
            denial_reason: nil,
            priority: nil,
            severity: nil,
            peer_review_required: false,
            reviewer: nil,
            done_when: nil,
            handoff_chain: [],
            project: nil,
            goal: nil,
            model: nil,
            provider: nil,
            schedule: nil,
            budget_usd_cents: nil,
            prompt_body: nil,
            file_path: nil

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

    with :ok <- require_kind(meta),
         {:ok, requires_approval} <- coerce_requires_approval(meta["requires_approval"]) do
      {:ok,
       %{
         task_id: derive_task_id(file_path),
         title: as_string(meta["title"]),
         status: as_string(meta["status"]),
         # Accept `assignee:` as an alias for `assigned_to:` (UAT N8 —
         # users from Linear/GitHub projects instinctively type
         # `assignee`, and the parser used to silently drop those
         # tasks off the board). `assigned_to` takes precedence when
         # both are present.
         assigned_to: as_string(meta["assigned_to"]) || as_string(meta["assignee"]),
         requested_by: as_string(meta["requested_by"]),
         requires_approval: requires_approval,
         denial_reason: as_string(meta["denial_reason"]),
         priority: coerce_priority(meta["priority"]),
         severity: coerce_severity(meta["severity"]),
         peer_review_required: coerce_peer_review_required(meta["peer_review_required"]),
         reviewer: as_string(meta["reviewer"]),
         done_when: as_string(meta["done_when"]),
         handoff_chain: coerce_handoff_chain(meta["handoff_chain"]),
         goal: as_string(meta["goal"]),
         model: as_string(meta["model"]),
         provider: as_string(meta["provider"]),
         schedule: as_string(meta["schedule"]),
         budget_usd_cents: coerce_budget(meta["budget_usd_cents"])
       }}
    end
  end

  # GEP-25 R26.2b — require `kind: task/v1` in task frontmatter.
  # Pre-1.0 atomic cut. Missing or wrong `kind:` turns the file from
  # "silently unparsed task" into a loud rejection the Director sees
  # in the audit log — matches the Router's outbox boundary already
  # enforced since R26.2a.
  defp require_kind(meta) do
    case Map.get(meta, "kind") do
      "task/v1" -> :ok
      nil -> {:error, {:missing_kind, "task/v1"}}
      other -> {:error, {:wrong_kind, "task/v1", other}}
    end
  end

  defp coerce_severity("critical"), do: :critical
  defp coerce_severity("major"), do: :major
  defp coerce_severity("minor"), do: :minor
  defp coerce_severity("info"), do: :info
  defp coerce_severity(_), do: nil

  # GEP-41 peer-review trigger flag. Booleans only; never strings.
  # A bad value is coerced to the safe default (false) so a malformed
  # task doesn't accidentally escape the gate.
  defp coerce_peer_review_required(true), do: true
  defp coerce_peer_review_required(false), do: false
  defp coerce_peer_review_required(_), do: false

  # GEP-40 handoff_chain — append-only list of {ts, from, to, reason}
  # entries. Coerces a parsed YAML list into a normalised list of
  # maps with string keys for each entry. Entries missing required
  # keys are dropped (validator will flag in a separate pass).
  defp coerce_handoff_chain(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{} = entry ->
        ts = as_string(Map.get(entry, "ts"))
        from = as_string(Map.get(entry, "from"))
        to = as_string(Map.get(entry, "to"))
        reason = as_string(Map.get(entry, "reason")) || ""

        if is_binary(ts) and is_binary(from) and is_binary(to) do
          [%{ts: ts, from: from, to: to, reason: reason}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp coerce_handoff_chain(_), do: []

  defp coerce_priority("high"), do: :high
  defp coerce_priority("medium"), do: :medium
  defp coerce_priority("low"), do: :low
  defp coerce_priority(p) when p in [:high, :medium, :low], do: p
  defp coerce_priority(_), do: nil

  # #243 — per-task budget cap. Accepts int / numeric string. Missing
  # / non-numeric → nil (unlimited, same default as agent + company).
  defp coerce_budget(n) when is_integer(n) and n >= 0, do: n

  defp coerce_budget(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp coerce_budget(_), do: nil

  @doc """
  Whether the task requires Director approval before an agent may execute
  it.
  """
  @spec requires_approval?(t()) :: boolean()
  def requires_approval?(%__MODULE__{requires_approval: :director}), do: true
  def requires_approval?(%__MODULE__{}), do: false

  # ---------------------------------------------------------------------------
  # Phase 4 Wave 0 (Plan 04-01) — atomic frontmatter mutation
  # ---------------------------------------------------------------------------

  # Narrow allowlist. Both atom and string forms accepted so callers may
  # use either taxonomy (keep with Phase 2 convention of normalising).
  #
  # Editor-facing keys (`title`, `assigned_to`, `priority`) live alongside
  # the original status-machine keys (`status`, `denial_reason`). The
  # frontmatter rewriter still only touches lines that ALREADY exist in
  # the file — a caller that wants to add a brand-new key should handle
  # that upstream (see KanbanLive's `ensure_frontmatter_line/3`).
  @supported_keys [
    :status,
    :denial_reason,
    :title,
    :assigned_to,
    :requested_by,
    :priority,
    :severity,
    :goal,
    :peer_review_required,
    :reviewer,
    :done_when,
    "status",
    "denial_reason",
    "title",
    "assigned_to",
    "requested_by",
    "priority",
    "severity",
    "goal",
    "peer_review_required",
    "reviewer",
    "done_when"
  ]

  @doc """
  Atomically rewrite frontmatter keys in `file_path`.

  Only `:status` and `:denial_reason` are supported — any other key
  returns `{:error, {:unsupported_key, key}}` without touching the file.
  We deliberately do NOT claim to be a general-purpose YAML writer;
  keeping the scope narrow lets us line-level-substitute instead of
  round-tripping through the YAML serializer (which is lossy for
  comments, ordering, and non-scalar types).

  Atomicity: writes to `<path>.tmp` via `File.write(..., [:sync])`
  then `File.rename/2` onto the final path — same-filesystem rename is
  atomic on POSIX, so the Watcher sees exactly one `:modified` event
  and never a partial file. On any error the tmp is cleaned up.

  ## Examples

      TaskDefinition.write("/tmp/t-01.md", %{status: "approved"})
      #=> :ok

      TaskDefinition.write("/tmp/t-01.md", %{foo: "bar"})
      #=> {:error, {:unsupported_key, :foo}}

      TaskDefinition.write("/tmp/no-fence.md", %{status: "done"})
      #=> {:error, :no_frontmatter}
  """
  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(file_path, updates) when is_binary(file_path) and is_map(updates) do
    with :ok <- validate_keys(updates),
         :ok <- ensure_regular_file(file_path),
         {:ok, content} <- File.read(file_path),
         rewritten <- maybe_loop_back_recurring(content, updates),
         {:ok, new_content} <- substitute_frontmatter(content, rewritten) do
      atomic_write(file_path, new_content)
    end
  end

  # Threatmodel wave 5: an agent with `tasks:update` permission has
  # rwx on `projects/<scope>/tasks` inside its sandbox. Without a
  # regular-file check here, a malicious agent can replace its task
  # file (or pre-create `<task>.md.tmp`) with a symlink pointing at
  # `~/.glorbo/config.md` / audit logs / another company's task. When
  # a Director action then calls `TaskDefinition.write`, File.read +
  # atomic_write follow the symlink and read/overwrite the target.
  defp ensure_regular_file(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_regular(path) do
      :ok -> :ok
      {:error, {:not_regular_file, type}} -> {:error, {:not_regular_file, type}}
      {:error, :enoent} -> {:error, :enoent}
      {:error, {:stat_failed, reason}} -> {:error, reason}
    end
  end

  # #237: recurring tasks (frontmatter `schedule: <NL>`) loop back to
  # `todo` instead of `done`. Applied uniformly across every call site
  # (Kanban drag-to-done, agent self-report, director action) so
  # nobody has to remember this rule. Non-scheduled tasks behave
  # unchanged. Accepts both atom- and string-keyed updates maps
  # because callers use both shapes interchangeably.
  defp maybe_loop_back_recurring(content, updates) do
    cond do
      Map.get(updates, :status) == "done" and recurring?(content) ->
        Map.put(updates, :status, "todo")

      Map.get(updates, "status") == "done" and recurring?(content) ->
        Map.put(updates, "status", "todo")

      true ->
        updates
    end
  end

  defp recurring?(content) do
    case Frontmatter.parse(content) do
      {:ok, fm, _body} ->
        value = to_string(fm["schedule"] || "")
        value != ""

      _ ->
        false
    end
  end

  @doc """
  Atomically replace the task's body (everything after the frontmatter
  fence). Frontmatter is preserved verbatim — only the prose section
  changes. Used by the Director-facing editor in KanbanLive.
  """
  @spec write_body(Path.t(), String.t()) :: :ok | {:error, term()}
  def write_body(file_path, body) when is_binary(file_path) and is_binary(body) do
    with {:ok, content} <- File.read(file_path),
         {:ok, new_content} <- substitute_body(content, body) do
      atomic_write(file_path, new_content)
    end
  end

  @doc """
  Wholesale replace the frontmatter map. Unlike `write/2`'s line-level
  rewriter (which only touches existing keys), this one serialises the
  whole map as the new frontmatter — so it can add `priority:` or
  `assigned_to:` to a task file that didn't declare them originally.

  Only the editor-allowlisted keys (`title`, `status`, `assigned_to`,
  `priority`, `requires_approval`) are emitted; any other keys in the
  input map are dropped. Keys whose value is `nil` or `""` are omitted
  entirely so the file doesn't carry empty `key:` lines.
  """
  @spec write_frontmatter(Path.t(), map()) :: :ok | {:error, term()}
  def write_frontmatter(file_path, updates) when is_binary(file_path) and is_map(updates) do
    with {:ok, content} <- File.read(file_path),
         rewritten <- maybe_loop_back_recurring(content, updates),
         # GEP-40 — merge updates with existing frontmatter so scalar
         # fields the caller didn't touch (done_when, reviewer,
         # requested_by, title, priority, severity, etc.) survive
         # mutations that target only one field. Callers that want to
         # clear a field pass `nil` or `""` explicitly; the
         # Enum.reject in `replace_frontmatter/2` drops those. Agent
         # Server's explicit merge is still safe — Map.merge/2 is
         # idempotent under this pattern.
         merged <- merge_with_existing(content, rewritten),
         {:ok, new_content} <- replace_frontmatter(content, merged) do
      atomic_write(file_path, new_content)
    end
  end

  # Read + parse existing frontmatter, then merge caller's updates
  # (updates win). Returns a string-keyed map compatible with
  # replace_frontmatter's lookup path. Silently falls back to the
  # raw updates if the file has no frontmatter or fails to parse —
  # the subsequent replace_frontmatter will raise a clearer error
  # in that case.
  defp merge_with_existing(content, updates) do
    case Glorbo.Filesystem.Frontmatter.parse(content) do
      {:ok, meta, _body} when is_map(meta) ->
        existing = Map.new(meta, fn {k, v} -> {to_string(k), v} end)

        updates_str =
          Map.new(updates, fn
            {k, v} when is_atom(k) -> {Atom.to_string(k), v}
            {k, v} -> {to_string(k), v}
          end)

        Map.merge(existing, updates_str)

      _ ->
        updates
    end
  end

  @editor_keys ~w(
    title
    status
    assigned_to
    requested_by
    priority
    severity
    requires_approval
    peer_review_required
    reviewer
    denial_reason
    done_when
  )

  # Keys that carry structured (non-scalar) values in a task frontmatter.
  # `replace_frontmatter/2` preserves their raw text block from the
  # original rather than re-emitting — our `yaml_scalar/1` emitter is
  # scalar-only, and the canonical YAML shape for list-of-maps /
  # multi-line scalars is owned by `Glorbo.FileSpec.Formatter`.
  @structured_keys ~w(handoff_chain)

  defp replace_frontmatter(content, updates) do
    case String.split(content, ~r/\A---\r?\n|\r?\n---\r?\n/, parts: 3) do
      ["", old_fm, body] ->
        # Preserve kind: from original frontmatter (GEP-25 D9). Always
        # first line in canonical order. If the existing file predates
        # R26.2 and lacks kind:, inject the default.
        kind_line =
          case Regex.run(~r/^kind:\s*\S.*$/m, old_fm) do
            [line] -> line
            _ -> "kind: task/v1"
          end

        fm_lines =
          @editor_keys
          |> Enum.map(fn k -> {k, lookup_key(updates, k)} end)
          |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
          |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{yaml_scalar(v)}" end)

        # GEP-40 — structured keys (currently just `handoff_chain:`)
        # are either preserved verbatim from `old_fm` or re-emitted
        # from a list value in `updates`. The re-emit path is what
        # `Glorbo.Actions.Tasks.reassign/4` uses to append a new
        # chain entry; scalar-only callers (KanbanLive save form,
        # Agent.Server ack) pass no `handoff_chain` key and get the
        # preservation path — so the chain survives unrelated
        # mutations.
        preserved =
          @structured_keys
          |> Enum.map(fn key ->
            case lookup_key(updates, key) do
              list when is_list(list) -> emit_structured(key, list)
              _ -> extract_block(old_fm, key)
            end
          end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join()

        {:ok,
         "---\n" <>
           kind_line <>
           "\n" <>
           fm_lines <>
           "\n" <>
           preserved <>
           "---\n" <>
           body}

      _ ->
        {:error, :no_frontmatter}
    end
  end

  # Extract a structured-YAML block (`<key>:\n  ...indented lines...`)
  # from a frontmatter blob. Returns "" if the key is not present.
  # The returned string ends with a trailing newline so concatenation
  # in `replace_frontmatter/2` lines up cleanly.
  defp extract_block(old_fm, key) when is_binary(key) do
    # `String.split` on the closing-fence pattern consumes the newline
    # BEFORE `---`, so `old_fm`'s last line has no trailing `\n`. Append
    # one so the continuation-line regex (which requires `\n`) can
    # match a chain whose last entry lands on the fence-adjacent line.
    fm = old_fm <> "\n"

    # Match key line + every subsequent line that starts with
    # whitespace (continuation) OR is blank. Stop at the next
    # non-indented, non-blank line. Non-greedy so we don't eat the
    # whole remaining frontmatter.
    pattern =
      ~r/
        (?<block>
          ^#{Regex.escape(key)}:[^\n]*\n
          (?:[ \t][^\n]*\n|\n)*
        )
      /mx

    case Regex.named_captures(pattern, fm) do
      %{"block" => block} when is_binary(block) -> block
      _ -> ""
    end
  end

  # Canonical-form serializer for list-of-maps structured keys. Only
  # `handoff_chain:` uses this path today; the item shape is
  # `%{"from" => _, "to" => _, "reason" => _, "ts" => _}` — keys
  # alphabetized per Formatter's canonical order, values run through
  # `FrontmatterWriter.yaml_scalar/1` so string escapes match the
  # rest of the frontmatter.
  defp emit_structured(_key, []), do: ""

  defp emit_structured(key, list) when is_list(list) do
    items =
      Enum.map_join(list, "\n", fn item ->
        map =
          Map.new(item, fn
            {k, v} when is_atom(k) -> {Atom.to_string(k), v}
            {k, v} -> {to_string(k), v}
          end)

        pairs = Enum.sort_by(map, fn {k, _} -> k end)

        case pairs do
          [] ->
            "  - {}"

          [{first_k, first_v} | rest] ->
            first_line = "  - #{first_k}: #{yaml_scalar(first_v)}"

            rest_lines =
              Enum.map_join(rest, "\n", fn {k, v} ->
                "    #{k}: #{yaml_scalar(v)}"
              end)

            case rest_lines do
              "" -> first_line
              lines -> first_line <> "\n" <> lines
            end
        end
      end)

    "#{key}:\n#{items}\n"
  end

  defp atomic_write(file_path, new_content) do
    tmp = file_path <> ".tmp"
    # Threatmodel wave 5: don't let a pre-created `<file>.tmp` symlink
    # redirect the write. lstat both the target and the temp side; if
    # the temp file exists and isn't a regular file, refuse.
    with :ok <- ensure_regular_file_or_absent(tmp),
         :ok <- ensure_regular_file_or_absent(file_path) do
      do_atomic_write(tmp, file_path, new_content)
    end
  end

  defp ensure_regular_file_or_absent(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok -> :ok
      {:error, {:not_regular_file, type}} -> {:error, {:not_regular_file, type}}
      {:error, {:stat_failed, reason}} -> {:error, reason}
    end
  end

  defp do_atomic_write(tmp, file_path, new_content) do
    case File.write(tmp, new_content, [:sync]) do
      :ok ->
        case File.rename(tmp, file_path) do
          :ok ->
            :ok

          {:error, _} = err ->
            _ = File.rm(tmp)
            err
        end

      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp lookup_key(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, v} ->
        v

      :error ->
        case key do
          "title" -> Map.get(map, :title)
          "status" -> Map.get(map, :status)
          "assigned_to" -> Map.get(map, :assigned_to)
          "requested_by" -> Map.get(map, :requested_by)
          "priority" -> Map.get(map, :priority)
          "severity" -> Map.get(map, :severity)
          "requires_approval" -> Map.get(map, :requires_approval)
          "peer_review_required" -> Map.get(map, :peer_review_required)
          "reviewer" -> Map.get(map, :reviewer)
          "denial_reason" -> Map.get(map, :denial_reason)
          "done_when" -> Map.get(map, :done_when)
          _ -> nil
        end
    end
  end

  defp substitute_body(content, new_body) do
    case String.split(content, ~r/\A---\r?\n|\r?\n---\r?\n/, parts: 3) do
      ["", fm, _body] ->
        trimmed = String.trim_trailing(new_body) <> "\n"
        {:ok, "---\n" <> fm <> "\n---\n\n" <> trimmed}

      _ ->
        {:error, :no_frontmatter}
    end
  end

  defp validate_keys(updates) do
    case Enum.find(Map.keys(updates), fn k -> k not in @supported_keys end) do
      nil -> :ok
      bad -> {:error, {:unsupported_key, bad}}
    end
  end

  # Line-level substitution preserves order, comments, indentation,
  # and unknown keys. Splits on exactly two `---\n` fences (opening +
  # closing). The regex form captures the three parts in one pass.
  defp substitute_frontmatter(content, updates) do
    normalized_updates = Map.new(updates, fn {k, v} -> {to_string(k), v} end)

    # Accept both LF and CRLF line endings so Windows-authored task files
    # parse correctly (TODO.md Minor #3).
    case String.split(content, ~r/\A---\r?\n|\r?\n---\r?\n/, parts: 3) do
      ["", fm, body] ->
        new_fm =
          fm
          |> String.split("\n")
          |> Enum.map_join("\n", fn line -> rewrite_line(line, normalized_updates) end)

        {:ok, "---\n" <> new_fm <> "\n---\n" <> body}

      _ ->
        {:error, :no_frontmatter}
    end
  end

  # Rewrites `<indent><key>: <value>` when `key` is in `updates`; leaves
  # all other lines (comments, unknown keys, blanks) untouched.
  defp rewrite_line(line, updates) do
    case Regex.run(~r/\A(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)\z/, line) do
      [_full, indent, key, _value] when is_map_key(updates, key) ->
        "#{indent}#{key}: #{yaml_scalar(updates[key])}"

      _ ->
        line
    end
  end

  defp yaml_scalar(v), do: Glorbo.Filesystem.FrontmatterWriter.yaml_scalar(v)

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
       requested_by: partial[:requested_by],
       requires_approval: partial.requires_approval,
       denial_reason: partial.denial_reason,
       priority: partial.priority,
       severity: partial.severity,
       peer_review_required: partial[:peer_review_required] || false,
       reviewer: partial[:reviewer],
       done_when: partial[:done_when],
       handoff_chain: partial[:handoff_chain] || [],
       project: derive_project(task_path),
       goal: partial.goal,
       model: partial[:model],
       provider: partial[:provider],
       schedule: partial[:schedule],
       budget_usd_cents: partial[:budget_usd_cents],
       prompt_body: body || "",
       file_path: file_path
     }}
  end

  defp derive_project(task_path) when is_binary(task_path) do
    case Regex.run(~r{^projects/([^/]+)/tasks/}, task_path) do
      [_, project] -> project
      _ -> nil
    end
  end

  defp derive_project(_), do: nil

  # ---------------------------------------------------------------------------
  # GEP-13 — cross-shape reference resolution
  # ---------------------------------------------------------------------------

  @doc """
  Resolve a task reference (either legacy `t-NN` or the GEP-13
  `<project>-NN` shape) to the current on-disk relative path.

  Accepts:

    * `"t-01"` — scans every project under the company looking for
      `projects/*/tasks/t-01.md`. If exactly one project has that
      filename, returns `{:ok, "projects/<proj>/tasks/t-01.md"}`.
      Multiple matches → `{:error, :ambiguous}`.
    * `"<project>-NN"` — direct shape; `{:ok, path}` if the file
      exists, `{:error, :not_found}` otherwise.
    * A full `projects/<proj>/tasks/<id>.md` path — returned as-is
      after existence check (pass-through for callers that already
      have the canonical form).

  Callers that already have a `task_path` should use it directly; this
  helper is for audit-UI code that needs to follow an ambiguous `t-NN`
  reference from historical events to the file as it lives today.

  ## Options

    * `:base` (required) — absolute path to the Glorbo root.
    * `:company` (required) — company slug.
  """
  @spec canonicalize_ref(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_found | :ambiguous}
  def canonicalize_ref(ref, opts) when is_binary(ref) and is_list(opts) do
    base = Keyword.fetch!(opts, :base)
    company = Keyword.fetch!(opts, :company)
    company_dir = Path.join([base, "companies", company])

    cond do
      String.starts_with?(ref, "projects/") and String.ends_with?(ref, ".md") ->
        # threatmodel [40]: reject traversal in the pass-through
        # branch. A ref like `projects/../../config.md` would
        # otherwise resolve via File.exists? and leak secrets into
        # any caller that reads the returned path.
        if traversal?(ref) do
          {:error, :not_found}
        else
          if File.exists?(Path.join(company_dir, ref)),
            do: {:ok, ref},
            else: {:error, :not_found}
        end

      ref =~ ~r/\A[a-z0-9][a-z0-9-]*-\d+\z/ ->
        # Try the GEP-13 shape first: derive project from the ref itself.
        project = split_project(ref)
        rel = "projects/#{project}/tasks/#{ref}.md"

        if File.exists?(Path.join(company_dir, rel)) do
          {:ok, rel}
        else
          # Not where the prefix says — could be a legacy `t-NN` that
          # happens to match the shape, or the file just doesn't exist.
          # Fall back to a cross-project scan.
          scan_projects_for(company_dir, "#{ref}.md")
        end

      true ->
        # Arbitrary bare id — scan every project.
        scan_projects_for(company_dir, "#{ref}.md")
    end
  end

  # Split a `<slug>-<digits>` ref at the *last* hyphen-digit boundary so
  # hyphenated project slugs (`web-redesign-07`) resolve to the slug
  # `web-redesign`, not `web`.
  defp split_project(ref) do
    case Regex.run(~r/\A(.+)-\d+\z/, ref) do
      [_, project] -> project
      _ -> ref
    end
  end

  # Reject any ref that contains `..` segments, leading `/`, or
  # NUL. Belt-and-braces: the regexes in other branches only match
  # simple slug-integer pairs, but the `projects/...md` pass-through
  # accepts anything and is the one a caller might plausibly feed
  # from audit or URL input.
  defp traversal?(ref) do
    segments = Path.split(ref)
    String.contains?(ref, <<0>>) or Path.type(ref) != :relative or ".." in segments
  end

  defp scan_projects_for(company_dir, filename) do
    projects_dir = Path.join(company_dir, "projects")

    case File.ls(projects_dir) do
      {:ok, slugs} ->
        matches =
          for slug <- slugs,
              File.dir?(Path.join(projects_dir, slug)),
              File.exists?(Path.join([projects_dir, slug, "tasks", filename])),
              do: "projects/#{slug}/tasks/#{filename}"

        case matches do
          [path] -> {:ok, path}
          [] -> {:error, :not_found}
          _ -> {:error, :ambiguous}
        end

      _ ->
        {:error, :not_found}
    end
  end
end
