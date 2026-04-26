defmodule Glorbo.Shell.Views.Chat.DataTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Chat.Data
  alias Glorbo.Test.TmpGlorboHome

  defp write!(base, rel, body) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
    full
  end

  describe "load_messages/3" do
    test "missing channel file → empty list" do
      base = TmpGlorboHome.setup()
      assert Data.load_messages(base, "acme", "general") == []
    end

    test "single-message file decodes one row" do
      base = TmpGlorboHome.setup()

      write!(base, "companies/acme/channels/general.md", """
      # general

      ## 2026-04-26T10:00:00Z | director
      Hello, team.
      """)

      [msg] = Data.load_messages(base, "acme", "general")
      assert msg.ts == "2026-04-26T10:00:00Z"
      assert msg.author == "director"
      assert msg.body == "Hello, team."
    end

    test "multiple messages preserve append order" do
      base = TmpGlorboHome.setup()

      write!(base, "companies/acme/channels/general.md", """
      # general

      ## 2026-04-26T10:00:00Z | director
      First message.

      ## 2026-04-26T10:01:00Z | engineer
      Second message.

      ## 2026-04-26T10:02:00Z | ceo
      Third.
      """)

      msgs = Data.load_messages(base, "acme", "general")
      assert Enum.map(msgs, & &1.author) == ["director", "engineer", "ceo"]
      assert Enum.map(msgs, & &1.body) == ["First message.", "Second message.", "Third."]
    end

    test "multi-line message body is preserved end-to-end" do
      base = TmpGlorboHome.setup()

      write!(base, "companies/acme/channels/general.md", """
      ## 2026-04-26T10:00:00Z | director
      Line one.
      Line two.

      Line four after a blank.
      """)

      [msg] = Data.load_messages(base, "acme", "general")
      assert msg.body =~ "Line one."
      assert msg.body =~ "Line two."
      assert msg.body =~ "Line four"
    end

    test "sub-headers (## non-timestamp) inside a body don't terminate the message" do
      base = TmpGlorboHome.setup()

      write!(base, "companies/acme/channels/general.md", """
      ## 2026-04-26T10:00:00Z | director
      Outer body.

      ## Sub-heading inside the body
      Still part of the same message.

      ## 2026-04-26T10:01:00Z | engineer
      Next message.
      """)

      msgs = Data.load_messages(base, "acme", "general")
      assert length(msgs) == 2
      assert hd(msgs).body =~ "Sub-heading inside the body"
    end

    test "non-existent channel name → empty list" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join([base, "companies/acme/channels"]))
      assert Data.load_messages(base, "acme", "missing") == []
    end
  end

  describe "list_channels/2" do
    test "empty channels dir → empty list" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join([base, "companies/acme/channels"]))
      assert Data.list_channels(base, "acme") == []
    end

    test "lists *.md files alphabetically, dropping the .md suffix" do
      base = TmpGlorboHome.setup()
      write!(base, "companies/acme/channels/general.md", "")
      write!(base, "companies/acme/channels/incidents.md", "")
      write!(base, "companies/acme/channels/announcements.md", "")

      assert Data.list_channels(base, "acme") ==
               ["announcements", "general", "incidents"]
    end

    test "non-md files are ignored" do
      base = TmpGlorboHome.setup()
      write!(base, "companies/acme/channels/general.md", "")
      write!(base, "companies/acme/channels/notes.txt", "")

      assert Data.list_channels(base, "acme") == ["general"]
    end

    test ".archive/ + dotfile entries are filtered out" do
      base = TmpGlorboHome.setup()
      write!(base, "companies/acme/channels/general.md", "")
      write!(base, "companies/acme/channels/.archive.md", "")

      assert Data.list_channels(base, "acme") == ["general"]
    end

    test "missing channels/ dir → empty list" do
      base = TmpGlorboHome.setup()
      assert Data.list_channels(base, "acme") == []
    end
  end
end
