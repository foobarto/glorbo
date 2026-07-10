defmodule Glorbo.ActionsTest do
  @moduledoc """
  Plan 04-01 Task 2: `Glorbo.Actions` Director write-actions.

  Each action is asserted on two dimensions:
    1. **Filesystem effect** — the correct file is appended/rewritten
       with the expected shape.
    2. **Audit emission** — after a successful write, exactly one
       audit event with the correct `action:` key is captured via a
       fake audit sink injected through `opts[:audit]`.

  A write failure (invalid slug, symlink target, oversize body) must
  produce NO audit event.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions
  alias Glorbo.Test.TmpGlorboHome

  # Fake audit sink — a registered GenServer that records every call it
  # receives from `AuditLog.append/2`. Because `AuditLog.append/2` calls
  # `GenServer.call(server, {:append, entry})`, the fake just needs to
  # handle `{:append, entry}` and stash the entry.
  defmodule FakeAudit do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, []}

    @impl true
    def handle_call({:append, entry}, _from, state),
      do: {:reply, :ok, [entry | state]}

    def handle_call(:calls, _from, state),
      do: {:reply, Enum.reverse(state), state}
  end

  setup do
    base = TmpGlorboHome.setup()
    co_dir = Path.join([base, "companies", "acme"])
    File.mkdir_p!(co_dir)
    File.mkdir_p!(Path.join(co_dir, "channels"))
    File.write!(Path.join([co_dir, "channels", "general.md"]), "# general\n")

    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, actor: "director"}
  end

  describe "ensure_dm_channel/3 (GEP-0053 D19 — lazy DM creation)" do
    test "creates the DM file with the canonical channel-log header", %{base: base} do
      assert :ok = Glorbo.Actions.ensure_dm_channel("acme", "ceo", base: base)

      path = Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"])
      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "kind: channel-log/v1"
      assert content =~ "channel: dm-director--ceo"
      assert content =~ "DM · director ↔ ceo"
    end

    test "supports the reserved DM channel for an underscore agent", %{
      base: base,
      audit: audit
    } do
      agent = "backend_engineer"
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", agent]))

      assert :ok = Glorbo.Actions.ensure_dm_channel("acme", agent, base: base)

      assert :ok =
               Actions.post_message("acme", "dm-director--#{agent}", "hello",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      path = Path.join([base, "companies", "acme", "channels", "dm-director--#{agent}.md"])
      assert File.read!(path) =~ "hello"
    end

    test "is idempotent — never clobbers an existing thread", %{base: base} do
      path = Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"])

      existing =
        "---\nkind: channel-log/v1\nchannel: dm-director--ceo\n---\n# DM · director ↔ ceo\n\n## 2026-01-01T00:00:00Z | director\nhi\n"

      File.write!(path, existing)

      assert :ok = Glorbo.Actions.ensure_dm_channel("acme", "ceo", base: base)
      assert File.read!(path) == existing
    end

    test "rejects an invalid agent slug (no traversal)", %{base: base} do
      assert {:error, _} = Glorbo.Actions.ensure_dm_channel("acme", "../etc", base: base)
    end

    test "refuses a pre-planted symlink at the DM path (M03 — no symlink follow)", %{base: base} do
      channels_dir = Path.join([base, "companies", "acme", "channels"])
      File.mkdir_p!(channels_dir)
      victim = Path.join(channels_dir, "victim.md")
      File.write!(victim, "untouched")

      path = Path.join(channels_dir, "dm-director--ceo.md")
      File.ln_s!(victim, path)

      assert {:error, {:path_not_regular, :symlink}} =
               Glorbo.Actions.ensure_dm_channel("acme", "ceo", base: base)

      # The symlink target was never written through.
      assert File.read!(victim) == "untouched"
    end

    test "concurrent first posts: exactly one creator wins, none clobber", %{base: base} do
      # Race N exclusive creates at the same path. The O_CREAT|O_EXCL
      # semantics mean every caller returns :ok (create or :eexist→ok)
      # and the file holds exactly one canonical header — the old
      # exists?-then-write shape could interleave and reset a thread.
      results =
        1..8
        |> Task.async_stream(
          fn _ -> Glorbo.Actions.ensure_dm_channel("acme", "ceo", base: base) end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, &(&1 == :ok))

      path = Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"])
      content = File.read!(path)
      assert content =~ "kind: channel-log/v1"
      # Exactly one header, not several concatenated/torn copies.
      assert length(String.split(content, "channel: dm-director--ceo")) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # post_message/4
  # ---------------------------------------------------------------------------

  describe "post_message/4" do
    test "appends Director message with ISO timestamp + writes chat.post audit", %{
      base: base,
      audit: audit,
      actor: "director"
    } do
      assert :ok =
               Actions.post_message("acme", "general", "hello world",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      content = File.read!(Path.join([base, "companies", "acme", "channels", "general.md"]))
      assert content =~ "# general\n"
      assert content =~ "| director"
      assert content =~ "hello world"
      # ISO 8601 timestamp shape
      assert content =~ ~r/## \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "chat.post"
      assert event[:actor] == "director"
      assert event[:company] == "acme"
      assert event[:target] == "channels/general.md"
      assert event[:channel] == "general"
    end

    test "rejects invalid channel slug (T-04-08 path traversal)", %{
      base: base,
      audit: audit,
      actor: "director"
    } do
      assert {:error, :invalid_slug} =
               Actions.post_message("acme", "../evil", "x",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      # No audit event emitted on validation failure.
      assert FakeAudit.calls(audit) == []
    end

    test "rejects empty body", %{base: base, audit: audit, actor: "director"} do
      assert {:error, :empty_body} =
               Actions.post_message("acme", "general", "",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects oversize body (> 10 KiB)", %{base: base, audit: audit, actor: "director"} do
      huge = String.duplicate("x", 10_241)

      assert {:error, :body_too_large} =
               Actions.post_message("acme", "general", huge,
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects symlink target (T-04-01 symlink attack defense)", %{
      base: base,
      audit: audit,
      actor: "director"
    } do
      # Replace general.md with a symlink pointing elsewhere.
      chan = Path.join([base, "companies", "acme", "channels", "general.md"])
      File.rm!(chan)
      decoy = Path.join(base, "decoy.md")
      File.write!(decoy, "# decoy\n")
      :ok = File.ln_s(decoy, chan)

      assert {:error, :not_a_regular_file} =
               Actions.post_message("acme", "general", "hi",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end

    test "@mention of an existing agent writes inbox/mentions file + agent.wake audit",
         %{base: base, audit: audit, actor: "director"} do
      # Create the target agent directory so the Director mention has
      # somewhere to land.
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      assert :ok =
               Actions.post_message(
                 "acme",
                 "general",
                 "@ceo can you take a look?",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])
      assert File.dir?(mentions_dir)
      files = File.ls!(mentions_dir)
      assert Enum.any?(files, &String.ends_with?(&1, "-general.md"))

      [content] =
        files
        |> Enum.map(&File.read!(Path.join(mentions_dir, &1)))
        |> Enum.take(1)

      assert content =~ ~s(channel: "general")
      assert content =~ ~s(from: "director")
      assert content =~ "can you take a look?"

      # Expect both chat.post and agent.wake audit events.
      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "chat.post" in actions
      assert "agent.wake" in actions
    end

    # C-077: an overlong MCP actor must NOT collapse to the trusted
    # "director" provenance. Pre-fix, `safe_actor_tag/1` returned
    # "director" for any actor over 128 bytes; an MCP caller with an
    # unbounded `Mcp-Client-Name` could thereby forge director-authored
    # mention frontmatter. The written `from:` must stay MCP-flavoured.
    test "overlong mcp actor does NOT forge director provenance in mention",
         %{base: base, audit: audit, actor: "director"} do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      long_client = String.duplicate("a", 200)
      actor = "mcp:" <> long_client

      assert :ok =
               Actions.post_message(
                 "acme",
                 "general",
                 "@ceo please look",
                 base: base,
                 audit: audit,
                 actor: actor
               )

      mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])

      [content] =
        mentions_dir
        |> File.ls!()
        |> Enum.map(&File.read!(Path.join(mentions_dir, &1)))
        |> Enum.take(1)

      refute content =~ ~s(from: "director")
      # Provenance stays MCP-flavoured and bounded.
      assert content =~ ~r/from: "mcp:/
    end

    # C-077: an empty/whitespace actor must not collapse to "director"
    # either — it's untrusted input, not the legitimate default (which
    # passes the literal "director" string through unchanged).
    test "empty actor does NOT forge director provenance in mention",
         %{base: base, audit: audit, actor: "director"} do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      assert :ok =
               Actions.post_message(
                 "acme",
                 "general",
                 "@ceo please look",
                 base: base,
                 audit: audit,
                 actor: "   "
               )

      mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])

      [content] =
        mentions_dir
        |> File.ls!()
        |> Enum.map(&File.read!(Path.join(mentions_dir, &1)))
        |> Enum.take(1)

      refute content =~ ~s(from: "director")
      assert content =~ ~s(from: "mcp:unknown")
    end

    # C-077 regression guard: the legitimate Director default (actor
    # literal "director") must still stamp `from: "director"`.
    test "explicit director actor stamps director provenance",
         %{base: base, audit: audit, actor: "director"} do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      assert :ok =
               Actions.post_message("acme", "general", "@ceo hi",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])

      [content] =
        mentions_dir
        |> File.ls!()
        |> Enum.map(&File.read!(Path.join(mentions_dir, &1)))
        |> Enum.take(1)

      assert content =~ ~s(from: "director")
    end

    test "missing actor raises instead of silently impersonating the director", %{
      base: base,
      audit: audit
    } do
      assert_raise KeyError, fn ->
        Actions.post_message("acme", "general", "hello", base: base, audit: audit)
      end
    end

    test "@mention of unknown agent is a no-op", %{base: base, audit: audit, actor: "director"} do
      assert :ok =
               Actions.post_message(
                 "acme",
                 "general",
                 "@ghostagent you there?",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      # chat.post still fires; agent.wake does NOT.
      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "chat.post" in actions
      refute "agent.wake" in actions
    end

    test "director DM wakes the counterparty without requiring an explicit @mention",
         %{base: base, audit: audit, actor: "director"} do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      File.write!(
        Path.join([base, "companies", "acme", "channels", "dm-director--ceo.md"]),
        "# DM\n"
      )

      assert :ok =
               Actions.post_message(
                 "acme",
                 "dm-director--ceo",
                 "Can you check this?",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])
      assert File.dir?(mentions_dir)

      [file] = File.ls!(mentions_dir)
      assert String.ends_with?(file, "-dm-director--ceo.md")

      content = File.read!(Path.join(mentions_dir, file))
      assert content =~ ~s(channel: "dm-director--ceo")
      assert content =~ ~s(from: "director")
      assert content =~ "Can you check this?"

      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "chat.post" in actions
      assert "agent.wake" in actions
    end

    # T6 — MCP-originated @mention must stamp the actual actor (`mcp:<client>`)
    # in the mention file frontmatter, not a hardcoded "director". A
    # remote MCP client previously could make inbox mentions claim
    # `from: "director"`, spoofing director provenance to downstream
    # agents that read the frontmatter.
    test "T6: @mention preserves the caller's actor in the mention frontmatter",
         %{base: base, audit: audit, actor: "director"} do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      assert :ok =
               Actions.post_message(
                 "acme",
                 "general",
                 "@ceo kick the tires please",
                 base: base,
                 audit: audit,
                 actor: "mcp:claude-code"
               )

      mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])
      [file] = File.ls!(mentions_dir)
      content = File.read!(Path.join(mentions_dir, file))

      assert content =~ ~s(from: "mcp:claude-code")
      refute content =~ ~s(from: "director")
    end

    test "T6: actor with embedded newline/quote is sanitised before frontmatter",
         %{base: base, audit: audit, actor: "director"} do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      assert :ok =
               Actions.post_message(
                 "acme",
                 "general",
                 "@ceo ping",
                 base: base,
                 audit: audit,
                 actor: "mcp:evil\nwake_flag: true\n\""
               )

      mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])
      [file] = File.ls!(mentions_dir)
      content = File.read!(Path.join(mentions_dir, file))

      # The injection attempt collapses back to a single-line scalar;
      # no extra `wake_flag:` line makes it into the frontmatter.
      refute content =~ ~r/^wake_flag:/m
      # And the sanitised actor sits on the correct YAML line.
      assert content =~ ~r/^from: "mcp:evilwake_flag: true"$/m
    end
  end

  # ---------------------------------------------------------------------------
  # post_task_comment/4
  # ---------------------------------------------------------------------------

  describe "post_task_comment/4" do
    setup %{base: base} do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      tasks_dir = Path.join([base, "companies", "acme", "projects", "web", "tasks"])
      File.mkdir_p!(tasks_dir)

      File.write!(Path.join(tasks_dir, "t-01.md"), """
      ---
      kind: task/v1
      title: "Ship v2"
      status: todo
      assigned_to: ceo
      ---

      Initial prompt.
      """)

      %{task_path: "projects/web/tasks/t-01.md"}
    end

    test "appends `## <ts> | director\\n<body>` to the sibling comments file (GEP-30 D8)",
         %{
           base: base,
           audit: audit,
           actor: "director",
           task_path: tp
         } do
      assert :ok =
               Actions.post_task_comment("acme", tp, "Looks good.",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      # The task file itself stays diff-clean — only the prompt + frontmatter.
      abs_task = Path.join([base, "companies", "acme", tp])
      task_content = File.read!(abs_task)
      assert task_content =~ "Initial prompt."
      refute task_content =~ "Looks good."

      # The comment lands in the sibling `.comments.md` file with the
      # expected `## <ts> | director` header.
      abs_comments = Glorbo.TaskComments.path_for(abs_task)
      comments_content = File.read!(abs_comments)
      assert comments_content =~ "kind: task-comments/v1"
      assert comments_content =~ "task_id: t-01"
      assert comments_content =~ ~r/## \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \| director/
      assert comments_content =~ "Looks good."
    end

    test "wakes the assignee even without an @mention", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: tp
    } do
      assert :ok =
               Actions.post_task_comment("acme", tp, "Please review.",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      mentions_dir =
        Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])

      assert File.dir?(mentions_dir)
      assert File.ls!(mentions_dir) != []

      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "task.comment" in actions
      assert "agent.wake" in actions
    end

    test "wakes an underscore-bearing assignee without an @mention", %{
      base: base,
      audit: audit,
      task_path: tp
    } do
      agent = "backend_engineer"
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", agent, "inbox"]))

      abs_task = Path.join([base, "companies", "acme", tp])

      File.write!(
        abs_task,
        String.replace(File.read!(abs_task), "assigned_to: ceo", "assigned_to: #{agent}")
      )

      assert :ok =
               Actions.post_task_comment("acme", tp, "Please review.",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      mentions = Path.join([base, "companies", "acme", "agents", agent, "inbox", "mentions"])
      assert File.ls!(mentions) != []
    end

    test "automatic assignee wake preserves an MCP comment actor", %{
      base: base,
      audit: audit,
      task_path: tp
    } do
      assert :ok =
               Actions.post_task_comment("acme", tp, "Please review.",
                 base: base,
                 audit: audit,
                 actor: "mcp:claude-code"
               )

      mentions = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])
      [file] = File.ls!(mentions)
      content = File.read!(Path.join(mentions, file))
      assert content =~ ~s(from: "mcp:claude-code")
      refute content =~ ~s(from: "director")
    end

    test "@mention in comment wakes that agent too", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: tp
    } do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "cto", "inbox"]))

      assert :ok =
               Actions.post_task_comment("acme", tp, "@cto can you weigh in?",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      cto_mentions =
        Path.join([base, "companies", "acme", "agents", "cto", "inbox", "mentions"])

      assert File.dir?(cto_mentions)
      assert File.ls!(cto_mentions) != []
    end

    test "rejects a traversal task_path", %{base: base, audit: audit, actor: "director"} do
      assert {:error, :invalid_task_path} =
               Actions.post_task_comment(
                 "acme",
                 "../../etc/passwd",
                 "x",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects empty body", %{base: base, audit: audit, actor: "director", task_path: tp} do
      assert {:error, :empty_body} =
               Actions.post_task_comment("acme", tp, "   ",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  # ---------------------------------------------------------------------------
  # set_approval/4
  # ---------------------------------------------------------------------------

  describe "set_approval/4" do
    setup %{base: base} do
      tasks_dir = Path.join([base, "companies", "acme", "projects", "web", "tasks"])
      File.mkdir_p!(tasks_dir)
      task = Path.join(tasks_dir, "t-01.md")

      File.write!(task, """
      ---
      kind: task/v1
      title: "Deploy"
      status: pending
      assigned_to: ceo
      requires_approval: director
      ---

      Ship it.
      """)

      %{task_path: "projects/web/tasks/t-01.md"}
    end

    test ":approved rewrites status: approved + writes approval.approved audit", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: task_path
    } do
      assert :ok =
               Actions.set_approval("acme", task_path, :approved,
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: approved"
      assert content =~ "title: \"Deploy\""

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "approval.approved"
      assert event[:actor] == "director"
      assert event[:target] == task_path
    end

    test ":denied rewrites status: denied + writes approval.denied audit", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: task_path
    } do
      assert :ok =
               Actions.set_approval("acme", task_path, :denied,
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: denied"

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "approval.denied"
    end

    test "rejects task path with .. segments", %{base: base, audit: audit, actor: "director"} do
      assert {:error, :invalid_task_path} =
               Actions.set_approval(
                 "acme",
                 "projects/../../etc/passwd.md",
                 :approved,
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects task path not starting with projects/", %{
      base: base,
      audit: audit,
      actor: "director"
    } do
      assert {:error, :invalid_task_path} =
               Actions.set_approval("acme", "agents/ceo/inbox/evil.md", :approved,
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end

    test "approved restores assigned_to from matching sentinel", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: task_path
    } do
      # Task was reassigned to director by the request-flow; sentinel
      # preserves the original agent. Approve should swap it back.
      File.write!(Path.join([base, "companies", "acme", task_path]), """
      ---
      kind: task/v1
      title: "Deploy"
      status: pending
      assigned_to: director
      requires_approval: director
      ---

      Ship it.
      """)

      sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(sentinel_dir)

      File.write!(Path.join(sentinel_dir, "awaiting-approval-t-01.md"), """
      ---
      agent: ceo
      task_id: t-01
      ---

      awaiting
      """)

      assert :ok =
               Actions.set_approval("acme", task_path, :approved,
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: approved"
      assert content =~ "assigned_to: ceo"
      refute content =~ "assigned_to: director"
    end

    test "denied carries requesting agent in audit entry", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: task_path
    } do
      sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(sentinel_dir)

      File.write!(Path.join(sentinel_dir, "awaiting-approval-t-01.md"), """
      ---
      agent: ceo
      task_id: t-01
      ---

      awaiting
      """)

      assert :ok =
               Actions.set_approval("acme", task_path, :denied,
                 base: base,
                 audit: audit,
                 actor: "director",
                 denial_reason: "scope creep"
               )

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "approval.denied"
      assert event[:agent] == "ceo"
      assert event[:denial_reason] == "scope creep"
    end

    test "denied restores assigned_to from sentinel (with reason)", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: task_path
    } do
      # Task was reassigned to director by request-flow; on deny the
      # task stays in the live tree (UI path), so assigned_to should
      # swap back to the requester so they see the denial on their lane.
      File.write!(Path.join([base, "companies", "acme", task_path]), """
      ---
      kind: task/v1
      title: "Deploy"
      status: pending-approval
      assigned_to: director
      requires_approval: director
      ---

      Ship it.
      """)

      sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(sentinel_dir)

      File.write!(Path.join(sentinel_dir, "awaiting-approval-t-01.md"), """
      ---
      agent: ceo
      task_id: t-01
      ---

      awaiting
      """)

      assert :ok =
               Actions.set_approval("acme", task_path, :denied,
                 base: base,
                 audit: audit,
                 actor: "director",
                 denial_reason: "too risky"
               )

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: denied"
      assert content =~ "assigned_to: ceo"
      refute content =~ "assigned_to: director"
      assert content =~ "denial_reason:"
    end

    test "denied without reason restores assigned_to from sentinel", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: task_path
    } do
      File.write!(Path.join([base, "companies", "acme", task_path]), """
      ---
      kind: task/v1
      title: "Deploy"
      status: pending-approval
      assigned_to: director
      requires_approval: director
      ---

      Ship it.
      """)

      sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(sentinel_dir)

      File.write!(Path.join(sentinel_dir, "awaiting-approval-t-01.md"), """
      ---
      agent: ceo
      task_id: t-01
      ---

      awaiting
      """)

      assert :ok =
               Actions.set_approval("acme", task_path, :denied,
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: denied"
      assert content =~ "assigned_to: ceo"
    end
  end

  # ---------------------------------------------------------------------------
  # wake_agent/3
  # ---------------------------------------------------------------------------

  describe "wake_agent/3" do
    test "writes state/wake-request.md with frontmatter + audit agent.wake_request", %{
      base: base,
      audit: audit,
      actor: "director"
    } do
      assert :ok =
               Actions.wake_agent("acme", "ceo", "deploy ready",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      path = Path.join([base, "companies", "acme", "agents", "ceo", "state", "wake-request.md"])
      assert File.exists?(path)

      body = File.read!(path)
      assert body =~ "---\n"
      assert body =~ "requested_at: "
      assert body =~ "reason: \"deploy ready\""
      assert body =~ "Director wake request."

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.wake_request"
      assert event[:actor] == "director"
      assert event[:target] == "agents/ceo"
      assert event[:reason] == "deploy ready"
    end

    test "nil reason writes empty reason string", %{base: base, audit: audit, actor: "director"} do
      assert :ok =
               Actions.wake_agent("acme", "ceo", nil, base: base, audit: audit, actor: "director")

      path = Path.join([base, "companies", "acme", "agents", "ceo", "state", "wake-request.md"])
      assert File.read!(path) =~ ~s(reason: "")
    end

    test "accepts underscore-bearing agent slugs", %{base: base, audit: audit} do
      agent = "backend_engineer"

      assert :ok =
               Actions.wake_agent("acme", agent, "review",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert File.exists?(
               Path.join([base, "companies", "acme", "agents", agent, "state", "wake-request.md"])
             )
    end

    test "rejects invalid agent slug", %{base: base, audit: audit, actor: "director"} do
      assert {:error, :invalid_slug} =
               Actions.wake_agent("acme", "../evil", "oops",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end

    # threatmodel M03 (host-write side). `state/` is agent-writable;
    # a malicious agent can plant a symlink at `wake-request.md` before
    # the Director's wake fires. Without an lstat guard the Director's
    # write follows the symlink to any host file the user can reach.
    test "refuses to write through an agent-planted symlink at state/wake-request.md",
         %{base: base, audit: audit, actor: "director"} do
      secret = Path.join(base, "director-secret.txt")
      File.write!(secret, "sensitive director-only content\n")

      state_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(state_dir)
      wake_path = Path.join(state_dir, "wake-request.md")
      :ok = File.ln_s(secret, wake_path)

      assert {:error, {:path_not_regular, :symlink}} =
               Actions.wake_agent("acme", "ceo", "deploy",
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      # Secret file stays untouched.
      assert File.read!(secret) == "sensitive director-only content\n"
      assert FakeAudit.calls(audit) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Write-first / audit-second ordering
  # ---------------------------------------------------------------------------

  describe "audit-after-write ordering" do
    test "set_approval on a missing task file emits NO audit event", %{
      base: base,
      audit: audit,
      actor: "director"
    } do
      # Task path is valid shape but the file doesn't exist — TaskDefinition.write
      # should fail first, and no audit event may be emitted.
      assert {:error, _reason} =
               Actions.set_approval("acme", "projects/ghost/tasks/t-00.md", :approved,
                 base: base,
                 audit: audit,
                 actor: "director"
               )

      assert FakeAudit.calls(audit) == []
    end
  end

  # Scaffold-on-approve — director approves a hire-request task, Glorbo
  # runs the agent scaffold automatically. Director remains the authority
  # (AGT-05 P15 preserved); Glorbo just automates the CLI step.
  describe "set_approval/4 scaffold-on-approve" do
    setup %{base: base} do
      tasks_dir = Path.join([base, "companies", "acme", "projects", "web", "tasks"])
      File.mkdir_p!(tasks_dir)
      task = Path.join(tasks_dir, "hire-01.md")

      File.write!(task, """
      ---
      title: hire researcher
      status: pending
      kind: hire
      agent_slug: researcher
      role: Researcher
      provider: opencode
      model: lmstudio/qwen/qwen3.6-35b-a3b
      ---

      Please hire a Researcher.
      """)

      %{task_path: "projects/web/tasks/hire-01.md"}
    end

    test "kind:hire + :approved fires scaffold_fun with the right argv", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: task_path
    } do
      me = self()
      ref = make_ref()

      scaffold_fun = fn argv ->
        send(me, {ref, :scaffolded, argv})
        {:new_agent, 0, "✓ created agent: /tmp/test/companies/acme/agents/researcher"}
      end

      assert :ok =
               Actions.set_approval("acme", task_path, :approved,
                 base: base,
                 audit: audit,
                 actor: "director",
                 scaffold_fun: scaffold_fun
               )

      assert_receive {^ref, :scaffolded,
                      ["acme/researcher", "--role", "Researcher", "--provider", "opencode"]}

      # Both the approval AND the scaffold are audited.
      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "approval.approved" in actions
      assert "agent.scaffold" in actions
    end

    test "scaffold audit preserves an MCP approval actor", %{
      base: base,
      audit: audit,
      task_path: task_path
    } do
      assert :ok =
               Actions.set_approval("acme", task_path, :approved,
                 base: base,
                 audit: audit,
                 actor: "mcp:claude-code",
                 scaffold_fun: fn _ -> {:new_agent, 0, "created"} end
               )

      event = FakeAudit.calls(audit) |> Enum.find(&(&1[:action] == "agent.scaffold"))
      assert event[:actor] == "mcp:claude-code"
    end

    test "non-hire task does NOT invoke scaffold_fun", %{
      base: base,
      audit: audit,
      actor: "director"
    } do
      # Regular pending task (no `kind: hire`).
      me = self()
      ref = make_ref()

      scaffold_fun = fn _argv ->
        send(me, {ref, :called})
        {:new_agent, 0, ""}
      end

      tasks_dir = Path.join([base, "companies", "acme", "projects", "web", "tasks"])
      File.mkdir_p!(tasks_dir)

      File.write!(Path.join(tasks_dir, "t-regular.md"), """
      ---
      kind: task/v1
      title: "Deploy"
      status: pending
      assigned_to: ceo
      requires_approval: director
      ---

      Ship it.
      """)

      assert :ok =
               Actions.set_approval("acme", "projects/web/tasks/t-regular.md", :approved,
                 base: base,
                 audit: audit,
                 actor: "director",
                 scaffold_fun: scaffold_fun
               )

      refute_receive {^ref, :called}, 50
    end

    test ":denied on a hire task does NOT scaffold", %{
      base: base,
      audit: audit,
      actor: "director",
      task_path: task_path
    } do
      me = self()
      ref = make_ref()

      scaffold_fun = fn _argv ->
        send(me, {ref, :called})
        {:new_agent, 0, ""}
      end

      assert :ok =
               Actions.set_approval("acme", task_path, :denied,
                 base: base,
                 audit: audit,
                 actor: "director",
                 scaffold_fun: scaffold_fun,
                 denial_reason: "budget hold"
               )

      refute_receive {^ref, :called}, 50
    end

    test "hire task missing required frontmatter does NOT scaffold", %{
      base: base,
      audit: audit,
      actor: "director"
    } do
      me = self()
      ref = make_ref()

      scaffold_fun = fn _argv ->
        send(me, {ref, :called})
        {:new_agent, 0, ""}
      end

      tasks_dir = Path.join([base, "companies", "acme", "projects", "web", "tasks"])
      File.mkdir_p!(tasks_dir)

      # `kind: hire` but no `agent_slug` / `role` / `provider`.
      File.write!(Path.join(tasks_dir, "hire-partial.md"), """
      ---
      title: hire something
      status: pending
      kind: hire
      ---

      incomplete.
      """)

      assert :ok =
               Actions.set_approval("acme", "projects/web/tasks/hire-partial.md", :approved,
                 base: base,
                 audit: audit,
                 actor: "director",
                 scaffold_fun: scaffold_fun
               )

      refute_receive {^ref, :called}, 50
    end

    test "scaffold failure is captured via agent.scaffold_failed audit",
         %{base: base, audit: audit, actor: "director", task_path: task_path} do
      scaffold_fun = fn _argv -> {:new_agent, 1, "slug already exists"} end

      assert :ok =
               Actions.set_approval("acme", task_path, :approved,
                 base: base,
                 audit: audit,
                 actor: "director",
                 scaffold_fun: scaffold_fun
               )

      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "agent.scaffold_failed" in actions
    end
  end
end
