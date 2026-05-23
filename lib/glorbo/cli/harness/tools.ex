defmodule Glorbo.CLI.Harness.Tools do
  @moduledoc false

  alias Glorbo.CLI.Harness.HTTP

  @max_glob_matches 200
  @max_grep_matches 200
  @max_grep_file_bytes 512_000
  @default_bash_timeout_ms 30_000
  @default_web_fetch_timeout_ms 30_000
  @max_bash_output_bytes 64_000
  @max_web_fetch_body_bytes 64_000

  @known_audit_actions [
    "tool.read_file",
    "tool.write_file",
    "tool.edit_file",
    "tool.glob",
    "tool.grep",
    "tool.bash",
    "egress.web_fetch"
  ]

  @type runtime_config :: %{
          required(:workspace) => String.t(),
          optional(:agent) => String.t(),
          optional(:task) => String.t(),
          optional(:http_max_retries) => non_neg_integer(),
          optional(:web_fetch_timeout_ms) => pos_integer()
        }

  @type audit_event :: %{
          required(:action) => String.t(),
          optional(:target) => String.t(),
          optional(:detail) => map()
        }

  @type execution_result :: %{
          required(:tool_name) => String.t(),
          required(:payload) => map(),
          optional(:audit_event) => audit_event() | nil
        }

  @spec known_audit_actions() :: [String.t()]
  def known_audit_actions, do: @known_audit_actions

  @spec known_tool_names() :: [String.t()]
  def known_tool_names,
    do: ["read_file", "write_file", "edit_file", "glob", "grep", "bash", "web_fetch"]

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      read_file_tool(),
      write_file_tool(),
      edit_file_tool(),
      glob_tool(),
      grep_tool(),
      bash_tool(),
      web_fetch_tool()
    ]
  end

  @spec execute(map(), runtime_config(), keyword()) :: execution_result()
  def execute(%{"function" => %{"name" => name, "arguments" => arguments}}, config, opts)
      when is_binary(name) and is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, args} when is_map(args) ->
        try do
          execute_decoded(name, args, config, opts)
        rescue
          # `resolve_tool_path/2` raises `ArgumentError` for two policy
          # violations: lexical workspace-escape, and ancestor-symlink
          # crossings (codex deep-dive F3/F4). Both surface as
          # structured tool error payloads rather than bringing down
          # the harness.
          e in ArgumentError ->
            cond do
              String.starts_with?(Exception.message(e), "tool path escapes workspace") ->
                %{
                  tool_name: name,
                  payload: %{"ok" => false, "error" => "path_escapes_workspace"}
                }

              String.starts_with?(Exception.message(e), "tool path crosses a symlinked") ->
                %{
                  tool_name: name,
                  payload: %{"ok" => false, "error" => "path_crosses_symlink"}
                }

              true ->
                reraise e, __STACKTRACE__
            end
        end

      {:ok, _bad_args} ->
        invalid_arguments_result(name)

      {:error, _reason} ->
        invalid_arguments_result(name)
    end
  end

  def execute(%{"function" => %{"name" => name}}, _config, _opts) when is_binary(name) do
    %{
      tool_name: name,
      payload: %{"ok" => false, "error" => "invalid_arguments"}
    }
  end

  def execute(%{"function" => %{"name" => name}}, _config, _opts) do
    %{
      tool_name: "unknown",
      payload: %{"ok" => false, "error" => "unknown_tool:#{inspect(name)}"}
    }
  end

  def execute(_call, _config, _opts) do
    %{
      tool_name: "unknown",
      payload: %{"ok" => false, "error" => "invalid_tool_call"}
    }
  end

  defp execute_decoded("read_file", args, config, opts), do: read_file(args, config, opts)
  defp execute_decoded("write_file", args, config, opts), do: write_file(args, config, opts)
  defp execute_decoded("edit_file", args, config, opts), do: edit_file(args, config, opts)
  defp execute_decoded("glob", args, config, opts), do: glob(args, config, opts)
  defp execute_decoded("grep", args, config, opts), do: grep(args, config, opts)
  defp execute_decoded("bash", args, config, opts), do: bash(args, config, opts)
  defp execute_decoded("web_fetch", args, config, opts), do: web_fetch(args, config, opts)

  defp execute_decoded(name, _args, _config, _opts) do
    %{
      tool_name: name,
      payload: %{"ok" => false, "error" => "unknown_tool:#{name}"}
    }
  end

  # Threatmodel wave 24: model-authored `read_file` tool. Lstat-gate
  # + 1 MiB cap before the read so a model can't trick the harness
  # into reading a huge file or following a sandbox-visible symlink
  # into a host path. The `read_fun` opt is preserved as a test seam
  # but defaults to the bounded helper.
  defp read_file(%{"path" => raw_path}, config, opts)
       when is_binary(raw_path) and raw_path != "" do
    path = resolve_tool_path(raw_path, config.workspace)
    display_path = display_tool_path(path, config.workspace)
    read_fun = Keyword.get(opts, :file_read_fun, &bounded_read/1)

    case read_fun.(path) do
      {:ok, contents} ->
        %{
          tool_name: "read_file",
          payload: %{"ok" => true, "path" => display_path, "contents" => contents},
          audit_event:
            audit_event("tool.read_file", display_path, %{
              "ok" => true,
              "bytes" => byte_size(contents)
            })
        }

      {:error, reason} ->
        error = inspect(reason)

        %{
          tool_name: "read_file",
          payload: %{"ok" => false, "path" => display_path, "error" => error},
          audit_event:
            audit_event("tool.read_file", display_path, %{
              "ok" => false,
              "error" => error
            })
        }
    end
  end

  defp read_file(_args, _config, _opts), do: missing_arg_result("read_file", "path")

  defp write_file(%{"path" => raw_path, "contents" => contents}, config, opts)
       when is_binary(raw_path) and raw_path != "" and is_binary(contents) do
    path = resolve_tool_path(raw_path, config.workspace)
    display_path = display_tool_path(path, config.workspace)

    mkdir_p_fun = Keyword.get(opts, :file_mkdir_p_fun, &File.mkdir_p/1)
    write_fun = Keyword.get(opts, :file_write_fun, &File.write/2)
    bytes = byte_size(contents)

    result =
      with :ok <- mkdir_p_fun.(Path.dirname(path)),
           :ok <- write_fun.(path, contents) do
        {:ok, %{"ok" => true, "path" => display_path, "bytes_written" => bytes}}
      end

    case result do
      {:ok, payload} ->
        %{
          tool_name: "write_file",
          payload: payload,
          audit_event:
            audit_event("tool.write_file", display_path, %{
              "ok" => true,
              "bytes_written" => bytes
            })
        }

      {:error, reason} ->
        error = inspect(reason)

        %{
          tool_name: "write_file",
          payload: %{"ok" => false, "path" => display_path, "error" => error},
          audit_event:
            audit_event("tool.write_file", display_path, %{
              "ok" => false,
              "error" => error
            })
        }
    end
  end

  defp write_file(_args, _config, _opts), do: missing_arg_result("write_file", "path_or_contents")

  defp edit_file(
         %{"path" => raw_path, "old_text" => old_text, "new_text" => new_text} = args,
         config,
         opts
       )
       when is_binary(raw_path) and raw_path != "" and is_binary(old_text) and is_binary(new_text) do
    replace_all = Map.get(args, "replace_all", false) == true

    if old_text == "" do
      %{
        tool_name: "edit_file",
        payload: %{"ok" => false, "error" => "missing_old_text"}
      }
    else
      path = resolve_tool_path(raw_path, config.workspace)
      display_path = display_tool_path(path, config.workspace)
      read_fun = Keyword.get(opts, :file_read_fun, &File.read/1)
      write_fun = Keyword.get(opts, :file_write_fun, &File.write/2)
      occurrences = occurrence_count(read_fun, path, old_text)

      case occurrences do
        {:error, reason} ->
          error = inspect(reason)

          %{
            tool_name: "edit_file",
            payload: %{"ok" => false, "path" => display_path, "error" => error},
            audit_event:
              audit_event("tool.edit_file", display_path, %{
                "ok" => false,
                "error" => error
              })
          }

        0 ->
          %{
            tool_name: "edit_file",
            payload: %{"ok" => false, "path" => display_path, "error" => "old_text_not_found"},
            audit_event:
              audit_event("tool.edit_file", display_path, %{
                "ok" => false,
                "error" => "old_text_not_found"
              })
          }

        count when count > 1 and not replace_all ->
          %{
            tool_name: "edit_file",
            payload: %{"ok" => false, "path" => display_path, "error" => "old_text_not_unique"},
            audit_event:
              audit_event("tool.edit_file", display_path, %{
                "ok" => false,
                "error" => "old_text_not_unique",
                "occurrences" => count
              })
          }

        count ->
          {:ok, contents} = read_fun.(path)
          updated = replace_contents(contents, old_text, new_text, replace_all)

          case write_fun.(path, updated) do
            :ok ->
              %{
                tool_name: "edit_file",
                payload: %{
                  "ok" => true,
                  "path" => display_path,
                  "replacements" => count,
                  "bytes_written" => byte_size(updated)
                },
                audit_event:
                  audit_event("tool.edit_file", display_path, %{
                    "ok" => true,
                    "replacements" => count,
                    "bytes_written" => byte_size(updated)
                  })
              }

            {:error, reason} ->
              error = inspect(reason)

              %{
                tool_name: "edit_file",
                payload: %{"ok" => false, "path" => display_path, "error" => error},
                audit_event:
                  audit_event("tool.edit_file", display_path, %{
                    "ok" => false,
                    "error" => error
                  })
              }
          end
      end
    end
  end

  defp edit_file(_args, _config, _opts),
    do: missing_arg_result("edit_file", "path_old_text_new_text")

  defp glob(%{"pattern" => pattern}, config, opts) when is_binary(pattern) and pattern != "" do
    wildcard_fun = Keyword.get(opts, :path_wildcard_fun, &Path.wildcard/2)
    resolved_pattern = resolve_tool_path(pattern, config.workspace)
    matches = wildcard_fun.(resolved_pattern, match_dot: false) |> Enum.sort()
    total_matches = length(matches)
    truncated = total_matches > @max_glob_matches

    display_matches =
      matches
      |> Enum.take(@max_glob_matches)
      |> Enum.map(&display_tool_path(&1, config.workspace))

    %{
      tool_name: "glob",
      payload: %{
        "ok" => true,
        "pattern" => pattern,
        "matches" => display_matches,
        "total_matches" => total_matches,
        "truncated" => truncated
      },
      audit_event:
        audit_event("tool.glob", pattern, %{
          "ok" => true,
          "matches" => total_matches,
          "truncated" => truncated
        })
    }
  end

  defp glob(_args, _config, _opts), do: missing_arg_result("glob", "pattern")

  defp grep(%{"pattern" => pattern} = args, config, opts)
       when is_binary(pattern) and pattern != "" do
    path_pattern = Map.get(args, "path", "**/*")
    case_sensitive = Map.get(args, "case_sensitive", false) == true
    resolved_pattern = resolve_tool_path(path_pattern, config.workspace)
    wildcard_fun = Keyword.get(opts, :path_wildcard_fun, &Path.wildcard/2)
    stat_fun = Keyword.get(opts, :file_stat_fun, &File.stat/1)
    lstat_fun = Keyword.get(opts, :file_lstat_fun, &File.lstat/1)
    read_fun = Keyword.get(opts, :file_read_fun, &File.read/1)

    {matches, searched_files, skipped_files, truncated} =
      wildcard_fun.(resolved_pattern, match_dot: false)
      |> Enum.sort()
      |> Enum.reduce_while({[], 0, 0, false}, fn path, {acc, searched, skipped, _truncated} ->
        case grep_file(
               path,
               pattern,
               case_sensitive,
               config.workspace,
               stat_fun,
               lstat_fun,
               read_fun
             ) do
          {:ok, file_matches} ->
            next_matches = acc ++ file_matches
            next_truncated = length(next_matches) > @max_grep_matches

            if next_truncated do
              {:halt, {Enum.take(next_matches, @max_grep_matches), searched + 1, skipped, true}}
            else
              {:cont, {next_matches, searched + 1, skipped, false}}
            end

          :skip ->
            {:cont, {acc, searched, skipped + 1, false}}
        end
      end)

    match_count = length(matches)

    %{
      tool_name: "grep",
      payload: %{
        "ok" => true,
        "pattern" => pattern,
        "path" => path_pattern,
        "case_sensitive" => case_sensitive,
        "matches" => matches,
        "match_count" => match_count,
        "searched_files" => searched_files,
        "skipped_files" => skipped_files,
        "truncated" => truncated
      },
      audit_event:
        audit_event("tool.grep", path_pattern, %{
          "ok" => true,
          "matches" => match_count,
          "searched_files" => searched_files,
          "skipped_files" => skipped_files,
          "truncated" => truncated
        })
    }
  end

  defp grep(_args, _config, _opts), do: missing_arg_result("grep", "pattern")

  defp bash(%{"command" => command}, config, opts) when is_binary(command) and command != "" do
    shell_path = Keyword.get(opts, :bash_shell_path, System.find_executable("sh") || "/bin/sh")
    timeout_ms = Keyword.get(opts, :bash_timeout_ms, @default_bash_timeout_ms)
    output_cap = Keyword.get(opts, :bash_output_cap_bytes, @max_bash_output_bytes)

    case run_shell_command(shell_path, command, config.workspace, timeout_ms, output_cap) do
      {:ok, exit_status, output, truncated} ->
        ok = exit_status == 0
        output_fields = encoded_text_fields("stdout", output)

        %{
          tool_name: "bash",
          payload:
            %{
              "ok" => ok,
              "command" => command,
              "exit_status" => exit_status,
              "truncated" => truncated
            }
            |> Map.merge(output_fields),
          audit_event:
            audit_event("tool.bash", command, %{
              "ok" => ok,
              "exit_status" => exit_status,
              "bytes" => byte_size(output),
              "truncated" => truncated
            })
        }

      {:timeout, output, truncated} ->
        output_fields = encoded_text_fields("stdout", output)

        %{
          tool_name: "bash",
          payload:
            %{
              "ok" => false,
              "command" => command,
              "error" => "timeout",
              "truncated" => truncated
            }
            |> Map.merge(output_fields),
          audit_event:
            audit_event("tool.bash", command, %{
              "ok" => false,
              "error" => "timeout",
              "bytes" => byte_size(output),
              "truncated" => truncated
            })
        }

      {:error, reason} ->
        error = inspect(reason)

        %{
          tool_name: "bash",
          payload: %{"ok" => false, "command" => command, "error" => error},
          audit_event:
            audit_event("tool.bash", command, %{
              "ok" => false,
              "error" => error
            })
        }
    end
  end

  defp bash(_args, _config, _opts), do: missing_arg_result("bash", "command")

  defp web_fetch(%{"url" => raw_url}, config, opts) when is_binary(raw_url) and raw_url != "" do
    case parse_fetch_uri(raw_url) do
      {:ok, uri} ->
        timeout_ms = Map.get(config, :web_fetch_timeout_ms, @default_web_fetch_timeout_ms)
        max_retries = Map.get(config, :http_max_retries, 0)

        request = %{
          method: :get,
          url: raw_url,
          headers: [{"accept", "text/plain, text/html, application/json, */*"}],
          timeout_ms: timeout_ms,
          # C-034: web_fetch targets are attacker-influenced (a prompt-injected
          # task can point this anywhere), so cap the streamed body hard at
          # 1 MiB. This is per-callsite — chat completions use the module's
          # generous default since the model endpoint's own response can be
          # legitimately large (tool-call payloads).
          max_response_bytes: 1_048_576
        }

        request_opts = [
          request_fun: Keyword.get(opts, :web_fetch_fun, &HTTP.request/1),
          max_retries: max_retries,
          sleep_fun: Keyword.get(opts, :http_sleep_fun, &Process.sleep/1),
          jitter_fun: Keyword.get(opts, :http_jitter_fun, &default_http_jitter/1)
        ]

        case HTTP.request_with_retries(request, request_opts) do
          {:ok, %{status: status, headers: headers, body: body}} ->
            {response_body, truncated} = capped_binary(body, @max_web_fetch_body_bytes)
            body_fields = encoded_text_fields("body", response_body)
            content_type = Map.get(headers, "content-type")
            ok = status >= 200 and status < 300

            %{
              tool_name: "web_fetch",
              payload:
                %{
                  "ok" => ok,
                  "url" => raw_url,
                  "status" => status,
                  "content_type" => content_type,
                  "truncated" => truncated
                }
                |> Map.merge(body_fields),
              audit_event:
                audit_event("egress.web_fetch", fetch_audit_target(uri), %{
                  "ok" => ok,
                  "status" => status,
                  "bytes" => byte_size(response_body),
                  "truncated" => truncated,
                  "url" => raw_url
                })
            }

          {:error, reason} ->
            error = inspect(reason)

            %{
              tool_name: "web_fetch",
              payload: %{"ok" => false, "url" => raw_url, "error" => error},
              audit_event:
                audit_event("egress.web_fetch", fetch_audit_target(uri), %{
                  "ok" => false,
                  "error" => error,
                  "url" => raw_url
                })
            }
        end

      {:error, reason} ->
        %{
          tool_name: "web_fetch",
          payload: %{"ok" => false, "url" => raw_url, "error" => to_string(reason)},
          audit_event:
            audit_event("egress.web_fetch", raw_url, %{
              "ok" => false,
              "error" => to_string(reason),
              "url" => raw_url
            })
        }
    end
  end

  defp web_fetch(_args, _config, _opts), do: missing_arg_result("web_fetch", "url")

  defp run_shell_command(nil, _command, _workspace, _timeout_ms, _output_cap),
    do: {:error, :shell_unavailable}

  defp run_shell_command(shell_path, command, workspace, timeout_ms, output_cap) do
    sh_script = ~s/w="$1"; s="$2"; c="$3"; cd "$w" || exit 1; exec "$s" -c "$c"/

    port =
      Port.open({:spawn_executable, shell_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, ["-c", sh_script, "glorbo-harness-bash", workspace, shell_path, command]}
      ])

    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    case drain_shell_port(port, deadline_ms, <<>>, output_cap, false) do
      {:ok, _status, _output, _truncated} = ok ->
        ok

      {:timeout, _output, _truncated} = timeout ->
        safe_port_close(port)
        timeout
    end
  end

  defp drain_shell_port(port, deadline_ms, acc, output_cap, truncated) do
    timeout_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        {next_acc, next_truncated} = append_capped_output(acc, chunk, output_cap, truncated)
        drain_shell_port(port, deadline_ms, next_acc, output_cap, next_truncated)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc, truncated}
    after
      timeout_ms ->
        {:timeout, acc, truncated}
    end
  end

  defp append_capped_output(acc, _chunk, _output_cap, true), do: {acc, true}

  defp append_capped_output(acc, chunk, output_cap, false) do
    remaining = max(output_cap - byte_size(acc), 0)

    cond do
      remaining == 0 ->
        {acc, true}

      byte_size(chunk) <= remaining ->
        {acc <> chunk, false}

      true ->
        {acc <> binary_part(chunk, 0, remaining), true}
    end
  end

  defp capped_binary(binary, output_cap) when is_binary(binary) do
    append_capped_output(<<>>, binary, output_cap, false)
  end

  defp safe_port_close(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end

  defp grep_file(path, pattern, case_sensitive, workspace, stat_fun, lstat_fun, read_fun) do
    with {:ok, %File.Stat{type: :regular}} <- lstat_fun.(path),
         {:ok, %File.Stat{size: size}} <- stat_fun.(path),
         true <- size <= @max_grep_file_bytes,
         {:ok, contents} <- read_fun.(path),
         true <- String.valid?(contents) do
      matches =
        contents
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {line, line_number}, acc ->
          if line_matches?(line, pattern, case_sensitive) do
            acc ++
              [
                %{
                  "path" => display_tool_path(path, workspace),
                  "line_number" => line_number,
                  "line" => String.slice(line, 0, 500)
                }
              ]
          else
            acc
          end
        end)

      {:ok, matches}
    else
      _ -> :skip
    end
  end

  defp line_matches?(line, pattern, true), do: String.contains?(line, pattern)

  defp line_matches?(line, pattern, false) do
    String.contains?(String.downcase(line), String.downcase(pattern))
  end

  defp occurrence_count(read_fun, path, old_text) do
    case read_fun.(path) do
      {:ok, contents} ->
        parts = String.split(contents, old_text)
        length(parts) - 1

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_contents(contents, old_text, new_text, true),
    do: String.replace(contents, old_text, new_text)

  defp replace_contents(contents, old_text, new_text, false),
    do: String.replace(contents, old_text, new_text, global: false)

  # Workspace-contained resolver. The harness runs INSIDE a bwrap
  # sandbox, so kernel mount scope is the primary boundary — but
  # relying solely on that leaves a TOCTOU hole if a future
  # `approved_paths` grant is wired up (the tool resolver runs
  # pre-bwrap on some paths during unsandboxed-fallback execution).
  # Belt-and-braces: refuse any path that expands outside the
  # workspace directory. Absolute paths are only allowed if they
  # start with `workspace`. Opencode round-3 flagged the previous
  # "absolute paths pass through" shape.
  defp resolve_tool_path(path, workspace) do
    workspace_abs = Path.expand(workspace)

    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, workspace_abs)
      end

    cond do
      not lexically_inside?(expanded, workspace_abs) ->
        raise ArgumentError,
              "tool path escapes workspace: #{inspect(path)} → #{expanded} " <>
                "(workspace=#{workspace_abs})"

      # Codex deep-dive F3/F4: lexical containment is not enough. If
      # any ancestor of `expanded` (BELOW workspace_abs) is a symlink,
      # `File.write` / `File.read` will follow it OUT of the workspace
      # at I/O time. Under bwrap the bind mounts narrow what's
      # reachable, but the unsandboxed fallback (`Glorbo.Sandbox.
      # Unsandboxed`, macOS, `--no-sandbox`) hits the host FS directly
      # — and the agent controls `raw_path`. Scope the scan to
      # workspace-RELATIVE segments only — Copilot review on PR #28
      # flagged that walking from filesystem root would refuse all
      # tool paths whenever a system ancestor is a symlink (macOS
      # `/tmp -> /private/tmp`, symlinked checkout paths, etc.).
      symlink_in_workspace_relative_path?(expanded, workspace_abs) ->
        raise ArgumentError,
              "tool path crosses a symlinked component: #{inspect(path)} → " <>
                "#{expanded} (workspace=#{workspace_abs})"

      true ->
        expanded
    end
  end

  defp lexically_inside?(expanded, workspace_abs) do
    expanded == workspace_abs or
      String.starts_with?(expanded, workspace_abs <> "/")
  end

  # Walk only the segments BETWEEN `workspace_abs` and `expanded` — the
  # workspace itself is trusted (operators may legitimately host it
  # under a symlinked path; macOS `/tmp` is itself a symlink). Each
  # interior segment gets an lstat; any symlink along that path means
  # the tool I/O would follow it out of the workspace at write/read
  # time, so refuse.
  defp symlink_in_workspace_relative_path?(expanded, workspace_abs) do
    case Path.relative_to(expanded, workspace_abs) do
      ^expanded ->
        # Not actually under workspace (shouldn't reach here — the
        # lexical check above gates this). Fail-safe to "no symlink"
        # so the caller's existing escape error wins.
        false

      relative ->
        relative
        |> Path.split()
        |> Enum.reduce_while(workspace_abs, fn seg, prefix ->
          new_path = Path.join(prefix, seg)

          case File.lstat(new_path) do
            {:ok, %File.Stat{type: :symlink}} -> {:halt, true}
            _ -> {:cont, new_path}
          end
        end)
        |> case do
          true -> true
          _ -> false
        end
    end
  end

  defp display_tool_path(path, workspace) do
    relative = Path.relative_to(path, workspace)

    cond do
      relative == "." -> "."
      relative == ".." -> path
      String.starts_with?(relative, "../") -> path
      true -> relative
    end
  end

  defp audit_event(action, target, detail) do
    %{
      action: action,
      target: target,
      detail: detail
    }
  end

  defp missing_arg_result(tool_name, missing) do
    %{
      tool_name: tool_name,
      payload: %{"ok" => false, "error" => "missing_#{missing}"}
    }
  end

  defp invalid_arguments_result(tool_name) do
    %{
      tool_name: tool_name,
      payload: %{"ok" => false, "error" => "invalid_arguments"}
    }
  end

  defp encoded_text_fields(key, value) when is_binary(value) do
    if String.valid?(value) do
      %{key => value}
    else
      %{"#{key}_base64" => Base.encode64(value), "#{key}_encoding" => "base64"}
    end
  end

  defp parse_fetch_uri(raw_url) do
    uri = URI.parse(raw_url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_url}

      is_nil(uri.host) ->
        {:error, :invalid_url}

      true ->
        {:ok, uri}
    end
  end

  defp fetch_audit_target(%URI{host: host, port: nil}), do: host

  defp fetch_audit_target(%URI{host: host, scheme: "http", port: 80}), do: host
  defp fetch_audit_target(%URI{host: host, scheme: "https", port: 443}), do: host

  defp fetch_audit_target(%URI{host: host, port: port}) when is_integer(port),
    do: "#{host}:#{port}"

  defp default_http_jitter(_attempt), do: 0

  # Threatmodel wave 24: lstat + 1 MiB cap. Refuses symlinks and
  # oversized files; preserves the `{:ok, contents}` / `{:error,
  # reason}` shape so callers + the test seam don't change.
  defp bounded_read(path) do
    case Glorbo.Filesystem.AgentWritableFile.read_bounded(path, 1_048_576) do
      {:ok, _} = ok -> ok
      {:error, {:read_failed, reason}} -> {:error, reason}
      {:error, other} -> {:error, other}
    end
  end

  defp read_file_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "read_file",
        "description" => "Read a file visible inside the current sandbox.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Absolute sandbox path or path relative to the workspace."
            }
          },
          "required" => ["path"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp write_file_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "write_file",
        "description" => "Create or overwrite a file visible inside the current sandbox.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Absolute sandbox path or path relative to the workspace."
            },
            "contents" => %{
              "type" => "string",
              "description" => "Full file contents to write."
            }
          },
          "required" => ["path", "contents"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp edit_file_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "edit_file",
        "description" =>
          "Replace exact text in an existing file visible inside the current sandbox.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Absolute sandbox path or path relative to the workspace."
            },
            "old_text" => %{
              "type" => "string",
              "description" => "Exact text to replace."
            },
            "new_text" => %{
              "type" => "string",
              "description" => "Replacement text."
            },
            "replace_all" => %{
              "type" => "boolean",
              "description" => "Replace every occurrence instead of requiring a unique match."
            }
          },
          "required" => ["path", "old_text", "new_text"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp glob_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "glob",
        "description" => "List paths matching a glob pattern inside the current sandbox.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "pattern" => %{
              "type" => "string",
              "description" => "Absolute sandbox glob or a glob relative to the workspace."
            }
          },
          "required" => ["pattern"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp grep_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "grep",
        "description" =>
          "Search file contents for a literal string across sandbox-visible files.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "pattern" => %{
              "type" => "string",
              "description" => "Literal string to search for."
            },
            "path" => %{
              "type" => "string",
              "description" =>
                "Optional glob of files to search; defaults to **/* under the workspace."
            },
            "case_sensitive" => %{
              "type" => "boolean",
              "description" => "When true, match case exactly. Defaults to false."
            }
          },
          "required" => ["pattern"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp bash_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "bash",
        "description" =>
          "Run a shell command inside the current sandbox workspace and return stdout plus the exit status.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" =>
                "Shell command to execute with the workspace as the current directory."
            }
          },
          "required" => ["command"],
          "additionalProperties" => false
        }
      }
    }
  end

  defp web_fetch_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "web_fetch",
        "description" =>
          "Fetch an HTTP or HTTPS URL through the current sandbox network policy and return the response body.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{
              "type" => "string",
              "description" => "Absolute HTTP or HTTPS URL to fetch with a GET request."
            }
          },
          "required" => ["url"],
          "additionalProperties" => false
        }
      }
    }
  end
end
