defmodule Mix.Tasks.Glorbo.PrivacyCheck do
  @moduledoc """
  Fails when tracked files contain likely privacy leaks.

  The check is intentionally narrow and deterministic. It catches the
  leak classes that are easy to introduce during agent-assisted work:

    * raw chat/session transcript phrasing instead of editorial notes,
    * maintainer-local workstation paths or shell prompts,
    * common API key / token / private-key patterns.

  It scans `git ls-files`, so generated build output, dependencies,
  and untracked local notes stay out of the precommit gate.

      mix glorbo.privacy_check
  """

  use Mix.Task

  @shortdoc "Scan tracked files for raw chats, local paths, and secret-looking tokens"

  @placeholder_words ~w(
    changeme dummy example fake placeholder redacted test token your
  )

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.config")

    findings =
      tracked_files()
      |> Enum.flat_map(&scan_file/1)

    case findings do
      [] ->
        Mix.shell().info("mix glorbo.privacy_check — clean")

      findings ->
        Mix.shell().error("""
        mix glorbo.privacy_check — possible privacy leaks found:
        #{format_findings(findings)}

        Rewrite raw chat notes as editorial prose, replace workstation-specific
        paths with placeholders like /path/to/tool, and remove/rotate any real
        keys before committing.
        """)

        exit({:shutdown, 1})
    end
  end

  defp tracked_files do
    case System.cmd("git", ["ls-files", "-z"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.reject(&skip_path?/1)

      {out, status} ->
        Mix.raise("git ls-files failed with exit #{status}: #{out}")
    end
  end

  defp skip_path?(path) do
    path in [
      "lib/mix/tasks/glorbo.privacy_check.ex",
      "test/mix/tasks/glorbo.privacy_check_test.exs"
    ] or
      String.starts_with?(path, [
        "_build/",
        "deps/",
        ".git/",
        "burrito_out/",
        ".claude/worktrees/"
      ])
  end

  defp scan_file(path) do
    case File.read(path) do
      {:ok, body} ->
        if String.valid?(body), do: scan_text(path, body), else: []

      {:error, _} ->
        []
    end
  end

  defp scan_text(path, body) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      scan_patterns(path, line_no, line) ++ scan_assignments(path, line_no, line)
    end)
  end

  defp scan_patterns(path, line_no, line) do
    (conversation_patterns() ++ local_patterns() ++ secret_patterns())
    |> Enum.filter(fn {_kind, regex} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {kind, _regex} -> finding(path, line_no, kind, line) end)
  end

  defp scan_assignments(path, line_no, line) do
    case Regex.run(assignment_pattern(), line, capture: :all_but_first) do
      [value] ->
        if placeholder?(value) do
          []
        else
          [finding(path, line_no, :secret_assignment, line)]
        end

      _ ->
        []
    end
  end

  defp placeholder?(value) do
    normalized = String.downcase(value)

    String.contains?(value, ["$", "{", "<"]) or
      Enum.any?(@placeholder_words, &String.contains?(normalized, &1))
  end

  defp finding(path, line_no, kind, line) do
    %{
      path: path,
      line_no: line_no,
      kind: kind,
      excerpt: String.trim(line)
    }
  end

  defp format_findings(findings) do
    findings
    |> Enum.map_join("\n", fn %{path: path, line_no: line_no, kind: kind, excerpt: excerpt} ->
      "  * #{path}:#{line_no} #{kind}: #{excerpt}"
    end)
  end

  defp conversation_patterns do
    [
      {:raw_chat_role, ~r/\b(User|Assistant|Human|Claude)\s*:/},
      {:raw_user_asked, rx(["\\buser ", "asked\\b"], "i")},
      {:raw_user_correction, rx(["\\buser ", "correction\\b"], "i")},
      {:raw_user_said, rx(["\\buser ", "said\\b"], "i")},
      {:raw_assistant_said, rx(["\\bassistant ", "said\\b"], "i")},
      {:raw_followed_with, rx(["\\bfollowed ", "with\\b"], "i")},
      {:raw_first_pass, rx(["\\bmy first ", "pass\\b"], "i")},
      {:raw_they_noted, rx(["\\bthey ", "noted\\b"], "i")},
      {:raw_conversation_ref, rx(["\\bfrom earlier this ", "conversation\\b"], "i")},
      {:raw_transcript_ref, rx(["\\bchat ", "transcript\\b"], "i")}
    ]
  end

  defp local_patterns do
    [
      {:local_home_path, rx(["/home/", "foo", "barto\\b"])},
      {:local_documents_path,
       rx(["(?:~|/home/[^[:space:])\"`]+)/(?:", "Dok", "umenty|Documents)/"])},
      {:local_shell_prompt, rx(["(^|[<\\s])", "foo", "barto@[A-Za-z0-9_-]+(?=\\s|<|$)"])}
    ]
  end

  defp secret_patterns do
    [
      {:aws_access_key_id, ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/},
      {:openai_api_key, ~r/\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/},
      {:anthropic_api_key, ~r/\bsk-ant-[A-Za-z0-9_-]{20,}\b/},
      {:google_api_key, ~r/\bAIza[0-9A-Za-z_-]{35}\b/},
      {:github_token, ~r/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/},
      {:slack_token, ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/},
      {:bearer_token, ~r/\bBearer\s+[A-Za-z0-9._=+-]{30,}\b/},
      {:private_key, ~r/-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY-----/}
    ]
  end

  defp assignment_pattern do
    ~r/\b(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY|GITHUB_TOKEN|HOMEBREW_TAP_TOKEN|API_KEY|ACCESS_TOKEN|SECRET_KEY|PASSWORD)\b\s*[:=]\s*["']?([^"'\s#]{20,})/i
  end

  defp rx(parts, opts \\ "") do
    parts
    |> IO.iodata_to_binary()
    |> Regex.compile!(opts)
  end
end
