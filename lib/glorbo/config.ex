defmodule Glorbo.Config do
  @moduledoc """
  Parser for `~/.glorbo/config.md` — Director-owned runtime config.

  Read once at boot (via `config/runtime.exs`), written on first boot
  when missing. Supplies `secret_key_base`, `dashboard_token`,
  `host`, `port` to the Phoenix endpoint per D-06 / D-07.

  ## File shape

      ---
      secret_key_base: <base-64 string, 64+ bytes of entropy>
      dashboard_token: <url-safe base-64, 32 bytes entropy>   # always required
      director_password_hash: "$pbkdf2-sha512$..."            # GEP-0053, optional
      host: "127.0.0.1"                # loopback-only by default
      port: 4000
      ---

  `director_password_hash` (GEP-0053) gates the *browser* dashboard with a
  director passphrase. Absent ⇒ BOOTSTRAP (the token URL leads to
  `/setup`); a valid `$pbkdf2-sha512$…` hash ⇒ CONFIGURED (browser
  requires the passphrase, token is MCP/CLI-only). Set via the `/setup`
  wizard, cleared via `glorbo reset-password`. The `dashboard_token`
  continues to gate MCP/CLI regardless.

      # Glorbo configuration
      (free-form markdown notes here; the frontmatter is the contract)

  ## Security

  * The file is written with mode `0600` (Director-only read) on first
    boot. On a fresh Fedora/Debian host this means no other local user
    can read the dashboard token (threat T-04-05).
  * Errors NEVER include field values in messages or logs; `load/1`
    returns opaque `{:error, :config_parse}` on any parse / read issue.
  * `dashboard_token` is auto-generated on first boot (or patched in on
    upgrade from a `null` value) and is always required. MCP clients pass
    it via `Authorization: Bearer <token>`; browsers via `?token=<token>`.
    The token is never written to logs (T-04-05).
  """

  alias Glorbo.Filesystem.Frontmatter

  @type config :: %{
          secret_key_base: String.t(),
          dashboard_token: String.t(),
          host: String.t(),
          port: pos_integer(),
          director_password_hash: String.t() | nil | :malformed
        }

  @default_host "127.0.0.1"
  @default_port 4000

  # GEP-0053: a `director_password_hash` value is one of three states:
  #   * key ABSENT            → `nil`        (BOOTSTRAP — no passphrase set)
  #   * a full `$pbkdf2-…$rounds$salt$hash` → kept (CONFIGURED)
  #   * present but blank / null / structurally invalid → `:malformed`
  #                                            (DEGRADED — fail closed)
  # The third case is the load-bearing one (D9): a torn write or hand-edit
  # that leaves a corrupt OR EMPTY value must NOT silently degrade to
  # BOOTSTRAP and re-open `/setup` to a token holder. Only an entirely
  # absent key is bootstrap; a present-but-empty key is treated as
  # tampering. DirectorAuth treats `:malformed` as a hard deny.
  #
  # Validation is STRUCTURAL, not prefix-only: `$pbkdf2-sha512$garbage`
  # must be `:malformed`, not a "valid" hash that later makes
  # `Pbkdf2.verify_pass/2` raise on a broken envelope. Shape:
  # `$pbkdf2-{sha256|sha512}$<rounds>$<salt>$<hash>` (segments are the
  # crypt-base64 alphabet — no `$` or whitespace within a segment).
  # Rounds must be a POSITIVE integer with no leading zero: pbkdf2's
  # verifier iterates `rounds - 1` and a stored `$0$` never reaches
  # its base case, so a hand-edited/torn zero-rounds value must be
  # DEGRADED (fail-closed), not CONFIGURED. (Codex PR-42 P2 finding.)
  @pbkdf2_hash_regex ~r/^\$pbkdf2-sha(?:256|512)\$[1-9]\d*\$[^$\s]+\$[^$\s]+$/

  @doc """
  Load the config map from `<base>/config.md`, creating the file with a
  freshly generated `secret_key_base` when absent.

  Returns `{:ok, %{...}}` on success or `{:error, :config_parse}` on any
  failure. The error tuple is value-free to prevent secret leakage into
  logs or process dictionaries (T-04-05).
  """
  @spec load(Path.t()) :: {:ok, config()} | {:error, :config_parse}
  def load(base \\ Glorbo.Filesystem.Hierarchy.default_root()) do
    path = Path.join(base, "config.md")
    unless File.exists?(path), do: write_default!(path)

    with {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Frontmatter.parse(content),
         {:ok, cfg} <- coerce(meta),
         {:ok, cfg} <- ensure_dashboard_token(path, cfg) do
      {:ok, cfg}
    else
      _ -> {:error, :config_parse}
    end
  end

  # Private — coerce parsed frontmatter to the typed config map. Fills
  # in a generated secret_key_base for frontmatter that lost it (should
  # only happen if the Director hand-edited the file).
  defp coerce(meta) when is_map(meta) do
    secret =
      case meta["secret_key_base"] do
        b when is_binary(b) and byte_size(b) >= 32 -> b
        _ -> generate_secret()
      end

    host =
      case meta["host"] do
        h when is_binary(h) and byte_size(h) > 0 -> h
        _ -> @default_host
      end

    port =
      case meta["port"] do
        p when is_integer(p) and p > 0 and p < 65_536 -> p
        p when is_binary(p) -> parse_port(p)
        _ -> @default_port
      end

    {:ok,
     %{
       secret_key_base: secret,
       dashboard_token: maybe_string(meta["dashboard_token"]),
       host: host,
       port: port,
       director_password_hash: coerce_password_hash(meta)
     }}
  end

  # GEP-0053 D9 — fail-closed coercion of the director passphrase hash.
  # Takes the whole frontmatter map so it can distinguish an ABSENT key
  # (legitimate bootstrap → nil) from a PRESENT-but-empty/null one
  # (tampering / torn write → :malformed, NOT bootstrap).
  defp coerce_password_hash(meta) do
    case Map.fetch(meta, "director_password_hash") do
      :error ->
        nil

      {:ok, val} ->
        case maybe_string(val) do
          nil -> :malformed
          s -> if Regex.match?(@pbkdf2_hash_regex, s), do: s, else: :malformed
        end
    end
  end

  defp parse_port(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 and n < 65_536 -> n
      _ -> @default_port
    end
  end

  defp write_default!(path) do
    File.mkdir_p!(Path.dirname(path))
    secret = generate_secret()
    cookie = generate_cookie()
    token = generate_token()

    body = """
    ---
    kind: config/v1
    secret_key_base: #{secret}
    dashboard_token: #{token}
    erl_cookie: #{cookie}
    host: "127.0.0.1"
    port: 4000
    ---

    # Glorbo configuration

    Generated by Glorbo on first boot. Edit `host:` to `0.0.0.0` to accept
    LAN connections. Keep this file readable only by the Director.
    Set `dashboard_token:` to a fresh value to rotate the auth token.
    MCP clients: use `Authorization: Bearer <token>` on every request.
    """

    atomic_write_secret!(path, body)
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(64) |> Base.encode64()
  end

  # Plan 05-01 (D-25): 24-byte url-safe cookie for Erlang distribution.
  # Url-safe encoding avoids quoting hassles when written to config.md or
  # passed as a `-setcookie` argument via `RELEASE_COOKIE`. 24 bytes
  # (> 128-bit security) exceeds the 16-byte minimum enforced by
  # `erl_cookie/1`.
  defp generate_cookie do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp maybe_string(nil), do: nil
  defp maybe_string(""), do: nil
  defp maybe_string(s) when is_binary(s), do: s
  defp maybe_string(other), do: to_string(other)

  # Auto-generate dashboard_token when nil/empty. Patches config.md in-place
  # using the same line-level rewrite as write_cookie!/5 (T-04-05: token
  # value never appears in log messages).
  defp ensure_dashboard_token(_path, %{dashboard_token: t} = cfg)
       when is_binary(t) and t != "" do
    {:ok, cfg}
  end

  defp ensure_dashboard_token(path, cfg) do
    token = generate_token()

    case patch_dashboard_token(path, token) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Failed to persist dashboard_token to config.md: #{inspect(reason)} " <>
            "(token is in-memory only — will change on restart)"
        )
    end

    {:ok, %{cfg | dashboard_token: token}}
  end

  defp patch_dashboard_token(path, token) do
    case File.read(path) do
      {:ok, content} ->
        new_content =
          if Regex.match?(~r/^dashboard_token:/m, content) do
            String.replace(content, ~r/^dashboard_token:.*$/m, "dashboard_token: #{token}")
          else
            # Key entirely absent — inject after the opening fence.
            String.replace(content, "---\n", "---\ndashboard_token: #{token}\n", global: false)
          end

        atomic_write_secret!(path, new_content)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Persist the director passphrase hash to `<base>/config.md` (GEP-0053).

  Called from the in-daemon `/setup` POST handler once the director sets
  their passphrase. The hash is written as a **double-quoted** YAML scalar
  (D16) so its leading `$` and any future envelope bytes can never corrupt
  the frontmatter into an unparseable file. Preserves every other key +
  the body, and reasserts mode 0600 via the atomic tmp-write.

  The caller is responsible for `Application.put_env(:glorbo,
  :director_password_hash, hash)` so the running node flips to CONFIGURED
  immediately (D3) — this function only touches disk.

  The `hash` value is opaque and MUST NOT be logged.
  """
  @spec put_password_hash(Path.t(), String.t()) :: :ok | {:error, term()}
  def put_password_hash(base \\ Glorbo.Filesystem.Hierarchy.default_root(), hash)
      when is_binary(hash) and hash != "" do
    patch_password_hash(Path.join(base, "config.md"), hash)
  end

  @doc """
  Atomically set the director passphrase hash IFF none is currently on disk
  (GEP-0053 D7 single-shot). The reload→check→write runs under a node-global
  lock, so two concurrent `/setup` POSTs can't both pass the "no hash yet"
  check and double-write — the loser sees the freshly-written hash and gets
  `:already_set`.

    * `:ok`          — written (disk had no hash);
    * `:already_set` — a valid hash already on disk (lost the race / already
      configured);
    * `:degraded`    — disk hash is `:malformed`; NEVER overwrite it from
      here (fail closed — D9);
    * `{:error, reason}`.

  `{:glorbo_director_setup, self()}` is the standard `:global` mutex idiom:
  the lock is on the resource term, and each request process is a distinct
  LockRequesterId, so different requesters contend (serialize) on it — the
  concurrency is covered by a test in `config_test.exs`.
  """
  @spec put_password_hash_if_absent(Path.t(), String.t()) ::
          :ok | :already_set | :degraded | {:error, term()}
  def put_password_hash_if_absent(base \\ Glorbo.Filesystem.Hierarchy.default_root(), hash)
      when is_binary(hash) and hash != "" do
    :global.trans({:glorbo_director_setup, self()}, fn ->
      case load(base) do
        {:ok, %{director_password_hash: nil}} -> put_password_hash(base, hash)
        {:ok, %{director_password_hash: :malformed}} -> :degraded
        {:ok, %{director_password_hash: existing}} when is_binary(existing) -> :already_set
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp patch_password_hash(path, hash) do
    case File.read(path) do
      {:ok, content} ->
        line = ~s(director_password_hash: "#{hash}")

        case put_frontmatter_line(content, "director_password_hash", line) do
          {:ok, new_content} ->
            atomic_write_secret!(path, new_content)
            :ok

          :error ->
            # No parseable frontmatter — refuse rather than scribble the
            # credential into the body (where it wouldn't be read back, so
            # the next boot would silently revert to BOOTSTRAP). Codex r-C1
            # finding 2.
            {:error, :no_frontmatter}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Frontmatter-scoped key write. Operates ONLY on the lines between the
  # opening fence and the first closing fence, so a key replace/insert can
  # never touch (or be confused by) a body line that happens to start with
  # the same key (codex r-C1 #2). Returns `:error` if `content` isn't
  # fenced frontmatter. Line-based (not regex-replace) so the value's
  # `$`/`\` bytes are always literal. CRLF input is normalised to LF — the
  # whole codebase assumes LF frontmatter (`Frontmatter.parse/1`, the
  # formatter) and `atomic_write_secret!` rewrites the file anyway, so this
  # matches what `mix glorbo fmt` would do (codex r-C1 re-review #2).
  defp put_frontmatter_line(content, key, new_line) do
    case split_frontmatter(normalize_lf(content)) do
      {:ok, inner, body} ->
        prefix = key <> ":"
        # Drop any existing occurrence (key line + its indented
        # continuation lines), then append the fresh single-line value.
        # `fmt` reorders to the canonical slot later. Append-after-drop
        # avoids leaving orphaned block-scalar continuation lines that
        # would corrupt the YAML (codex r-C1 round-3).
        {kept, _found?} = drop_key_span(String.split(inner, "\n"), prefix)
        new_inner = Enum.join(kept ++ [new_line], "\n")
        {:ok, "---\n" <> new_inner <> "\n---\n" <> body}

      :error ->
        :error
    end
  end

  # Frontmatter-scoped key removal (body lines untouched).
  defp delete_frontmatter_line(content, key) do
    case split_frontmatter(normalize_lf(content)) do
      {:ok, inner, body} ->
        prefix = key <> ":"
        {kept, _found?} = drop_key_span(String.split(inner, "\n"), prefix)
        {:ok, "---\n" <> Enum.join(kept, "\n") <> "\n---\n" <> body}

      :error ->
        :error
    end
  end

  # Remove every line beginning `<key>:` AND its following indented
  # continuation lines (YAML block/folded scalar bodies). Frontmatter keys
  # live at column 0, so any subsequent space/tab-led line belongs to the
  # preceding key's value. This keeps a (pathological, hand-authored)
  # multiline secret value from leaving orphaned lines that would fold
  # into a neighbouring key or break parsing. Returns `{kept_lines,
  # found?}`.
  defp drop_key_span(lines, prefix), do: drop_key_span(lines, prefix, [], false)

  defp drop_key_span([], _prefix, acc, found?), do: {Enum.reverse(acc), found?}

  defp drop_key_span([line | rest], prefix, acc, found?) do
    if String.starts_with?(line, prefix) do
      rest = Enum.drop_while(rest, &String.starts_with?(&1, [" ", "\t"]))
      drop_key_span(rest, prefix, acc, true)
    else
      drop_key_span(rest, prefix, [line | acc], found?)
    end
  end

  defp normalize_lf(content), do: String.replace(content, "\r\n", "\n")

  # Split LF-normalised fenced frontmatter into `{inner, body}` where
  # `inner` is the trimmed text between the opening `---` fence and the
  # first closing `---` line (no surrounding newlines), and `body` is
  # everything after the closing fence. Tolerates trailing spaces on the
  # closing fence and a body that itself contains `---` (non-greedy).
  # `:error` if `content` is not fenced frontmatter.
  defp split_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---[ \t]*\n(.*)\z/s, content, capture: :all_but_first) do
      [inner, body] -> {:ok, inner, body}
      _ -> :error
    end
  end

  @doc """
  Remove the director passphrase hash from `<base>/config.md` (GEP-0053).

  Backs the `glorbo reset-password` recovery path: deleting the key drops
  the instance to BOOTSTRAP on next boot so the token URL reaches `/setup`
  again. A missing file is treated as already-bootstrap (`:ok`).
  """
  @spec clear_password_hash(Path.t()) :: :ok | {:error, term()}
  def clear_password_hash(base \\ Glorbo.Filesystem.Hierarchy.default_root()) do
    path = Path.join(base, "config.md")

    case File.read(path) do
      {:ok, content} ->
        case delete_frontmatter_line(content, "director_password_hash") do
          {:ok, new_content} -> atomic_write_secret!(path, new_content)
          # No frontmatter ⇒ nothing to clear ⇒ already bootstrap.
          :error -> :ok
        end

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Return the Erlang distribution cookie for this Glorbo install.

  Ensures the key is present (and ≥ 16 bytes) in `<base>/config.md`; if
  absent or too short, generates a fresh 24-byte url-safe cookie, persists
  it to disk (preserving other frontmatter lines + body), and reasserts
  mode 0600.

  The returned value is opaque — callers MUST treat it as a secret and
  MUST NEVER emit it to logs or audit (threat T-05-02).
  """
  @spec erl_cookie(Path.t()) :: {:ok, String.t()} | {:error, :config_parse}
  def erl_cookie(base \\ Glorbo.Filesystem.Hierarchy.default_root()),
    do: erl_cookie(base, _retried? = false)

  # WR-08: classic TOCTOU — the previous implementation did
  # `unless File.exists?(path), do: write_default!(path)` followed by
  # File.read(path). A concurrent `glorbo init --force` that removed the
  # file in that window landed us in the `:enoent` branch and fell out
  # to {:error, :config_parse}. Handle :enoent explicitly by writing
  # defaults and recursing once (guarded by retried? to prevent loops on
  # unrelated failures).
  defp erl_cookie(base, retried?) do
    path = Path.join(base, "config.md")

    case File.read(path) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, body} -> handle_cookie(path, content, meta, body)
          _ -> {:error, :config_parse}
        end

      {:error, :enoent} when not retried? ->
        write_default!(path)
        erl_cookie(base, true)

      {:error, _} ->
        {:error, :config_parse}
    end
  end

  defp handle_cookie(path, content, meta, body) do
    case meta["erl_cookie"] do
      c when is_binary(c) and byte_size(c) >= 16 ->
        {:ok, c}

      _ ->
        cookie = generate_cookie()
        write_cookie!(path, content, meta, body, cookie)
        {:ok, cookie}
    end
  rescue
    _ -> {:error, :config_parse}
  end

  # Line-level rewrite so we preserve other frontmatter keys, comments
  # (if any sneak past yamerl), and the body verbatim. `:sync` gives us a
  # durable write so a crash mid-write leaves either the old or the new
  # file — never a torn middle.
  defp write_cookie!(path, content, meta, _body, cookie) do
    new_content =
      if Map.has_key?(meta, "erl_cookie") do
        # Replace the single `erl_cookie:` line wherever it sits in the
        # frontmatter — multi-line flag `m` anchors `^`/`$` per line.
        String.replace(content, ~r/^erl_cookie:.*$/m, "erl_cookie: #{cookie}")
      else
        # Inject the key immediately after the opening `---\n` fence
        # (global: false to only touch the first occurrence — the body
        # may contain markdown horizontal rules that look like fences).
        String.replace(content, "---\n", "---\nerl_cookie: #{cookie}\n", global: false)
      end

    atomic_write_secret!(path, new_content)
  end

  # WR-07: write-then-chmod leaves a window where the file is
  # world-readable under the default umask (0644/0664), exposing
  # secret_key_base and erl_cookie to any concurrent local user. Use
  # the same pattern as Pidfile.write!/2: tmp-file write, chmod the
  # tmp, then atomic rename into place. The rename preserves the
  # tmp's mode, so the final path is 0600 from the moment it exists.
  defp atomic_write_secret!(path, content) do
    # Wave 24: random suffix + `:file.open([:exclusive])` closes the
    # predictable-tmpfile-symlink-redirect race that the `path <>
    # ".tmp"` flow had.
    #
    # GEP-0053 codex r-C1 (re-review): `:file.open/2` does NOT honour a
    # mode — the tmp is created at the umask default (0644). chmod-after-
    # open is NOT enough on its own: a local user who opens the empty tmp
    # during that 0644 instant keeps a readable fd (Unix checks perms at
    # open, not per-read) and can then read the secret bytes we write.
    # The robust defence is at the CONTAINING DIRECTORY: force the parent
    # to 0700 so no other user can traverse in to open the tmp at all
    # (the `~/.ssh` model). We still chmod the tmp 0600 as belt-and-braces
    # in case the dir perms ever regress.
    dir = Path.dirname(path)
    File.chmod!(dir, 0o700)

    rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}-#{rand_suffix}"

    {:ok, fd} = :file.open(tmp, [:write, :raw, :exclusive, :binary])
    File.chmod!(tmp, 0o600)

    try do
      :ok = :file.write(fd, content)
    after
      :ok = :file.close(fd)
    end

    File.rename!(tmp, path)
  end
end
