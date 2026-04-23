defmodule Glorbo.CLI.HarnessTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Harness
  alias Glorbo.CLI.Registry.Provider

  setup do
    root = Path.join(System.tmp_dir!(), "glorbo-harness-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    reply_path = Path.join(root, "reply.md")
    usage_path = Path.join(root, "usage.json")
    creds_path = Path.join(root, "openai.toml")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    env = %{
      "GLORBO_REPLY_PATH" => reply_path,
      "GLORBO_USAGE_PATH" => usage_path,
      "GLORBO_WORKSPACE" => workspace,
      "GLORBO_NATIVE_CREDENTIALS_PATH" => creds_path,
      "GLORBO_NATIVE_ENDPOINT" => "https://api.openai.com/v1",
      "GLORBO_NATIVE_AUTH" => "bearer"
    }

    {:ok,
     root: root,
     workspace: workspace,
     reply_path: reply_path,
     usage_path: usage_path,
     creds_path: creds_path,
     env: env}
  end

  defp env_fun(map), do: fn key -> Map.get(map, key) end

  defp native_provider(overrides \\ []) do
    struct!(
      %Provider{
        name: "openai",
        kind: :native,
        endpoint: "https://api.openai.com/v1",
        auth: :bearer,
        source: :builtin,
        source_file: "<test>"
      },
      overrides
    )
  end

  defp queued_chat_fun(responses) do
    fn request ->
      send(self(), {:request, request})

      Agent.get_and_update(responses, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, :no_more_responses}, []}
      end)
    end
  end

  test "writes reply + tracked usage for a direct assistant response", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))

    chat_fun = fn request ->
      send(self(), {:request, request})

      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [%{"message" => %{"content" => "hello from native"}}],
           "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 4},
           "model" => "gpt-4.1"
         }
       }}
    end

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-1",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "say hi" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: chat_fun
             )

    assert File.read!(ctx.reply_path) == "hello from native"

    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tracked"] == true
    assert usage["prompt_tokens"] == 3
    assert usage["completion_tokens"] == 4
    assert usage["model"] == "gpt-4.1"
    assert usage["duration_ms"] >= 0
    assert usage["tool_calls"] == %{}

    assert_received {:request, request}
    assert request.url == "https://api.openai.com/v1/chat/completions"
    assert {"authorization", "Bearer sk-test"} in request.headers

    assert Enum.map(request.body["tools"], & &1["function"]["name"]) == [
             "read_file",
             "write_file",
             "edit_file",
             "glob",
             "grep",
             "bash",
             "web_fetch"
           ]
  end

  test "retries transient provider responses before succeeding", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          {:ok,
           %{
             status: 429,
             headers: %{"retry-after" => "0"},
             body: %{"error" => %{"message" => "slow down"}}
           }},
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [%{"message" => %{"content" => "retried reply"}}],
               "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 3},
               "model" => "gpt-4.1"
             }
           }}
        ]
      end)

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-1b",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "say hi after retry" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: queued_chat_fun(responses),
               http_sleep_fun: fn _ -> :ok end
             )

    assert File.read!(ctx.reply_path) == "retried reply"
    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tracked"] == true
    assert usage["prompt_tokens"] == 2
    assert usage["completion_tokens"] == 3
    assert_received {:request, _first_request}
    assert_received {:request, _second_request}
  end

  test "executes read_file tool calls and records tool counts", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))
    File.write!(Path.join(ctx.workspace, "notes.md"), "workspace note")

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [
                 %{
                   "message" => %{
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "id" => "call-1",
                         "function" => %{
                           "name" => "read_file",
                           "arguments" => ~s({"path":"notes.md"})
                         }
                       }
                     ]
                   }
                 }
               ],
               "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2},
               "model" => "gpt-4.1"
             }
           }},
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [%{"message" => %{"content" => "tool result acknowledged"}}],
               "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 4},
               "model" => "gpt-4.1"
             }
           }}
        ]
      end)

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-2",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "inspect the workspace" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: queued_chat_fun(responses)
             )

    assert File.read!(ctx.reply_path) == "tool result acknowledged"

    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tracked"] == true
    assert usage["prompt_tokens"] == 4
    assert usage["completion_tokens"] == 6
    assert usage["tool_calls"] == %{"read_file" => 1}

    assert usage["audit_events"] == [
             %{
               "action" => "tool.read_file",
               "target" => "notes.md",
               "detail" => %{"ok" => true, "bytes" => 14}
             }
           ]

    assert_received {:request, first_request}
    assert_received {:request, second_request}

    first_body = first_request.body
    second_body = second_request.body

    assert Enum.count(first_body["messages"]) == 1
    assert Enum.count(second_body["messages"]) == 3

    [%{"content" => tool_content, "role" => "tool"}] =
      Enum.filter(second_body["messages"], &(&1["role"] == "tool"))

    decoded_tool = Jason.decode!(tool_content)
    assert decoded_tool["ok"] == true
    assert decoded_tool["contents"] == "workspace note"
  end

  test "executes write_file and edit_file tool calls with audit events", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [
                 %{
                   "message" => %{
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "id" => "call-1",
                         "function" => %{
                           "name" => "write_file",
                           "arguments" => ~s({"path":"draft.md","contents":"hello world"})
                         }
                       },
                       %{
                         "id" => "call-2",
                         "function" => %{
                           "name" => "edit_file",
                           "arguments" =>
                             ~s({"path":"draft.md","old_text":"world","new_text":"native"})
                         }
                       }
                     ]
                   }
                 }
               ],
               "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 3},
               "model" => "gpt-4.1"
             }
           }},
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [%{"message" => %{"content" => "file edits complete"}}],
               "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 5},
               "model" => "gpt-4.1"
             }
           }}
        ]
      end)

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-3a",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "create and update a draft" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: queued_chat_fun(responses)
             )

    assert File.read!(Path.join(ctx.workspace, "draft.md")) == "hello native"

    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tool_calls"] == %{"edit_file" => 1, "write_file" => 1}

    assert usage["audit_events"] == [
             %{
               "action" => "tool.write_file",
               "target" => "draft.md",
               "detail" => %{"ok" => true, "bytes_written" => 11}
             },
             %{
               "action" => "tool.edit_file",
               "target" => "draft.md",
               "detail" => %{"ok" => true, "replacements" => 1, "bytes_written" => 12}
             }
           ]
  end

  test "executes glob and grep tool calls with structured results", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))
    File.mkdir_p!(Path.join(ctx.workspace, "docs"))
    File.write!(Path.join(ctx.workspace, "docs/one.md"), "first needle\n")
    File.write!(Path.join(ctx.workspace, "docs/two.md"), "second NEEDLE\n")

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [
                 %{
                   "message" => %{
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "id" => "call-1",
                         "function" => %{
                           "name" => "glob",
                           "arguments" => ~s({"pattern":"docs/**/*.md"})
                         }
                       },
                       %{
                         "id" => "call-2",
                         "function" => %{
                           "name" => "grep",
                           "arguments" =>
                             ~s({"pattern":"needle","path":"docs/**/*.md","case_sensitive":false})
                         }
                       }
                     ]
                   }
                 }
               ],
               "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2},
               "model" => "gpt-4.1"
             }
           }},
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [%{"message" => %{"content" => "search complete"}}],
               "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1},
               "model" => "gpt-4.1"
             }
           }}
        ]
      end)

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-3b",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "search docs" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: queued_chat_fun(responses)
             )

    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tool_calls"] == %{"glob" => 1, "grep" => 1}

    assert usage["audit_events"] == [
             %{
               "action" => "tool.glob",
               "target" => "docs/**/*.md",
               "detail" => %{"ok" => true, "matches" => 2, "truncated" => false}
             },
             %{
               "action" => "tool.grep",
               "target" => "docs/**/*.md",
               "detail" => %{
                 "ok" => true,
                 "matches" => 2,
                 "searched_files" => 2,
                 "skipped_files" => 0,
                 "truncated" => false
               }
             }
           ]

    assert_received {:request, _first_request}
    assert_received {:request, second_request}

    tool_payloads =
      second_request.body["messages"]
      |> Enum.filter(&(&1["role"] == "tool"))
      |> Enum.map(&Jason.decode!(&1["content"]))

    assert Enum.any?(tool_payloads, fn payload ->
             payload["pattern"] == "docs/**/*.md" and
               payload["matches"] == ["docs/one.md", "docs/two.md"]
           end)

    assert Enum.any?(tool_payloads, fn payload ->
             payload["pattern"] == "needle" and payload["match_count"] == 2 and
               Enum.any?(
                 payload["matches"],
                 &(&1["line_number"] == 1 and &1["path"] == "docs/one.md")
               )
           end)
  end

  test "executes bash tool calls and records stdout plus exit status", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [
                 %{
                   "message" => %{
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "id" => "call-bash-1",
                         "function" => %{
                           "name" => "bash",
                           "arguments" => ~s({"command":"printf 'hello from bash'"})
                         }
                       }
                     ]
                   }
                 }
               ],
               "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 3},
               "model" => "gpt-4.1"
             }
           }},
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [%{"message" => %{"content" => "bash complete"}}],
               "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 5},
               "model" => "gpt-4.1"
             }
           }}
        ]
      end)

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-3c",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "inspect the shell" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: queued_chat_fun(responses)
             )

    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tool_calls"] == %{"bash" => 1}

    assert usage["audit_events"] == [
             %{
               "action" => "tool.bash",
               "target" => "printf 'hello from bash'",
               "detail" => %{
                 "ok" => true,
                 "exit_status" => 0,
                 "bytes" => 15,
                 "truncated" => false
               }
             }
           ]

    assert_received {:request, _first_request}
    assert_received {:request, second_request}

    [tool_payload] =
      second_request.body["messages"]
      |> Enum.filter(&(&1["role"] == "tool"))
      |> Enum.map(&Jason.decode!(&1["content"]))

    assert tool_payload["ok"] == true
    assert tool_payload["exit_status"] == 0
    assert tool_payload["stdout"] == "hello from bash"
    assert tool_payload["truncated"] == false
  end

  test "bash tool timeouts become structured tool errors", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [
                 %{
                   "message" => %{
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "id" => "call-bash-timeout",
                         "function" => %{
                           "name" => "bash",
                           "arguments" => ~s({"command":"sleep 1"})
                         }
                       }
                     ]
                   }
                 }
               ],
               "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1},
               "model" => "gpt-4.1"
             }
           }},
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [%{"message" => %{"content" => "timeout handled"}}],
               "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 2},
               "model" => "gpt-4.1"
             }
           }}
        ]
      end)

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-3d",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "try a slow command" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: queued_chat_fun(responses),
               bash_timeout_ms: 10
             )

    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tool_calls"] == %{"bash" => 1}

    assert usage["audit_events"] == [
             %{
               "action" => "tool.bash",
               "target" => "sleep 1",
               "detail" => %{
                 "ok" => false,
                 "error" => "timeout",
                 "bytes" => 0,
                 "truncated" => false
               }
             }
           ]

    assert_received {:request, _first_request}
    assert_received {:request, second_request}

    [tool_payload] =
      second_request.body["messages"]
      |> Enum.filter(&(&1["role"] == "tool"))
      |> Enum.map(&Jason.decode!(&1["content"]))

    assert tool_payload["ok"] == false
    assert tool_payload["error"] == "timeout"
    assert tool_payload["stdout"] == ""
  end

  test "executes web_fetch tool calls and records egress audit events", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [
                 %{
                   "message" => %{
                     "content" => nil,
                     "tool_calls" => [
                       %{
                         "id" => "call-web-1",
                         "function" => %{
                           "name" => "web_fetch",
                           "arguments" => ~s({"url":"https://example.test/docs"})
                         }
                       }
                     ]
                   }
                 }
               ],
               "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 2},
               "model" => "gpt-4.1"
             }
           }},
          {:ok,
           %{
             status: 200,
             body: %{
               "choices" => [%{"message" => %{"content" => "web fetch complete"}}],
               "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 3},
               "model" => "gpt-4.1"
             }
           }}
        ]
      end)

    web_fetch_fun = fn request ->
      send(self(), {:web_fetch_request, request})

      {:ok,
       %{
         status: 200,
         headers: %{"content-type" => "text/plain; charset=utf-8"},
         body: "fetched body"
       }}
    end

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-3e",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "fetch docs" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: queued_chat_fun(responses),
               web_fetch_fun: web_fetch_fun
             )

    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tool_calls"] == %{"web_fetch" => 1}

    assert usage["audit_events"] == [
             %{
               "action" => "egress.web_fetch",
               "target" => "example.test",
               "detail" => %{
                 "ok" => true,
                 "status" => 200,
                 "bytes" => 12,
                 "truncated" => false,
                 "url" => "https://example.test/docs"
               }
             }
           ]

    assert_received {:web_fetch_request, request}
    assert request.method == :get
    assert request.url == "https://example.test/docs"

    assert_received {:request, _first_request}
    assert_received {:request, second_request}

    [tool_payload] =
      second_request.body["messages"]
      |> Enum.filter(&(&1["role"] == "tool"))
      |> Enum.map(&Jason.decode!(&1["content"]))

    assert tool_payload["ok"] == true
    assert tool_payload["status"] == 200
    assert tool_payload["body"] == "fetched body"
    assert tool_payload["content_type"] == "text/plain; charset=utf-8"
    assert tool_payload["truncated"] == false
  end

  test "returns a clear error when bearer credentials are missing", ctx do
    chat_fun = fn _request -> flunk("chat_fun must not run without credentials") end

    assert {:harness, 2, output} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-3",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "say hi" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: chat_fun
             )

    assert output =~ "missing api_key"
    refute File.exists?(ctx.reply_path)
    refute File.exists?(ctx.usage_path)
  end

  test "missing provider usage marks the dispatch untracked", ctx do
    File.write!(ctx.creds_path, ~s(api_key = "sk-test"))

    chat_fun = fn _request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [%{"message" => %{"content" => "ok without usage"}}],
           "model" => "gpt-4.1"
         }
       }}
    end

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "openai",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-4",
                 "--model",
                 "gpt-4.1"
               ],
               prompt_fun: fn -> "say hi" end,
               env_fun: env_fun(ctx.env),
               provider_fun: fn _ -> native_provider() end,
               chat_fun: chat_fun
             )

    usage = Jason.decode!(File.read!(ctx.usage_path))
    assert usage["tracked"] == false
    assert usage["prompt_tokens"] == 0
    assert usage["completion_tokens"] == 0
  end

  test "falls back to runtime env for user-defined native providers", ctx do
    custom_env =
      Map.merge(ctx.env, %{
        "GLORBO_NATIVE_ENDPOINT" => "https://example.test/v1",
        "GLORBO_NATIVE_AUTH" => "bearer",
        "GLORBO_NATIVE_CREDENTIALS_PATH" => Path.join(ctx.root, "acme.toml")
      })

    File.write!(custom_env["GLORBO_NATIVE_CREDENTIALS_PATH"], ~s(api_key = "sk-custom"))

    chat_fun = fn request ->
      send(self(), {:request, request})

      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [%{"message" => %{"content" => "custom provider reply"}}],
           "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 5},
           "model" => "custom-model"
         }
       }}
    end

    assert {:harness, 0, ""} =
             Harness.run(
               [
                 "--provider",
                 "acme-native",
                 "--agent",
                 "engineer",
                 "--task",
                 "t-5",
                 "--model",
                 "custom-model"
               ],
               prompt_fun: fn -> "say hi" end,
               env_fun: env_fun(custom_env),
               provider_fun: fn _ -> nil end,
               chat_fun: chat_fun
             )

    assert File.read!(ctx.reply_path) == "custom provider reply"
    assert_received {:request, request}
    assert request.url == "https://example.test/v1/chat/completions"
    assert {"authorization", "Bearer sk-custom"} in request.headers
  end
end
