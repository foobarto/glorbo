defmodule Glorbo.CLI.Harness.Tools do
  @moduledoc false

  @max_glob_matches 200
  @max_grep_matches 200
  @max_grep_file_bytes 512_000

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
          optional(:task) => String.t()
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
    [read_file_tool(), write_file_tool(), edit_file_tool(), glob_tool(), grep_tool()]
  end

  @spec execute(map(), runtime_config(), keyword()) :: execution_result()
  def execute(%{"function" => %{"name" => name, "arguments" => arguments}}, config, opts)
      when is_binary(name) and is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, args} when is_map(args) ->
        execute_decoded(name, args, config, opts)

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

  defp execute_decoded(name, _args, _config, _opts) do
    %{
      tool_name: name,
      payload: %{"ok" => false, "error" => "unknown_tool:#{name}"}
    }
  end

  defp read_file(%{"path" => raw_path}, config, opts)
       when is_binary(raw_path) and raw_path != "" do
    path = resolve_tool_path(raw_path, config.workspace)
    display_path = display_tool_path(path, config.workspace)
    read_fun = Keyword.get(opts, :file_read_fun, &File.read/1)

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

  defp resolve_tool_path(path, workspace) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path, workspace)
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
end
