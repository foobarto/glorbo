defmodule Glorbo.Chat.RotationTest do
  use ExUnit.Case, async: true

  alias Glorbo.Chat.Rotation

  setup do
    dir = Path.join(System.tmp_dir!(), "glorbo-rot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "general.md")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, path: path}
  end

  defp make_message(i, body \\ "hello"),
    do:
      "## 2026-04-21T10:#{String.pad_leading("#{rem(i, 60)}", 2, "0")}:00Z | agent-#{i}\n#{body}\n"

  defp build_channel(msgs) do
    "# general\n\n" <> Enum.map_join(1..msgs, "", &make_message/1)
  end

  describe "maybe_rotate/2" do
    test "returns :noop for a small file under thresholds", %{path: path} do
      File.write!(path, build_channel(10))
      assert :noop = Rotation.maybe_rotate(path)
    end

    test "returns :noop for a missing file", %{path: path} do
      assert :noop = Rotation.maybe_rotate(path)
    end

    test "returns :noop when over threshold but too few messages to trim",
         %{path: path} do
      # Many bytes, but only 5 messages — keep_tail defaults to 100, so
      # rotation has nothing to archive.
      big_body = String.duplicate("x", 800 * 1024)
      msg = "## 2026-04-21T10:00:00Z | agent-1\n#{big_body}\n"
      File.write!(path, "# general\n\n" <> msg)

      assert :noop = Rotation.maybe_rotate(path)
    end

    test "rotates when line threshold is exceeded", %{path: path, dir: dir} do
      File.write!(path, build_channel(200))

      assert {:rotated, archive_path, kept} =
               Rotation.maybe_rotate(path,
                 rotate_after_lines: 50,
                 keep_tail_messages: 10
               )

      assert kept == 10
      assert File.exists?(archive_path)
      assert String.starts_with?(archive_path, Path.join(dir, "archive/general/"))

      # Live file now has exactly 10 messages.
      {:ok, content} = File.read(path)
      assert Regex.scan(~r/^## /m, content) |> length() == 10

      # Archive contains the rest.
      archive = File.read!(archive_path)
      assert archive =~ "archive segment"
      assert Regex.scan(~r/^## /m, archive) |> length() == 190
    end

    test "preserves whole messages at the split boundary", %{path: path} do
      File.write!(path, build_channel(50))

      assert {:rotated, archive_path, _} =
               Rotation.maybe_rotate(path,
                 rotate_after_bytes: 100,
                 keep_tail_messages: 5
               )

      # Live file starts at a message header (not mid-message).
      {:ok, live} = File.read(path)
      assert String.starts_with?(live, "## ")

      # Archive contains messages 1..45 and is newline-terminated
      # (ends with the body of the final archived message).
      archive = File.read!(archive_path)
      assert archive =~ "## 2026-04-21T10:45:00Z"
      assert String.ends_with?(archive, "\n")

      # Live file is messages 46..50 — 5 headers, no more.
      assert Regex.scan(~r/^## /m, live) |> length() == 5
    end

    test "bytes threshold triggers rotation independently of lines",
         %{path: path} do
      # 120 messages, small enough per-message that line count alone
      # wouldn't trip 1500-line default — but 120 * ~50 bytes > our
      # 1 KB threshold.
      File.write!(path, build_channel(120))

      assert {:rotated, _, kept} =
               Rotation.maybe_rotate(path,
                 rotate_after_bytes: 1024,
                 rotate_after_lines: nil,
                 keep_tail_messages: 20
               )

      assert kept == 20
    end

    test "successive rotations create distinct archive files", %{path: path, dir: dir} do
      File.write!(path, build_channel(200))

      {:rotated, a1, _} =
        Rotation.maybe_rotate(path,
          rotate_after_lines: 50,
          keep_tail_messages: 10,
          now_fun: fn -> ~U[2026-04-21 10:00:00Z] end
        )

      # Append more messages to re-grow past threshold.
      File.write!(path, File.read!(path) <> build_channel(200), [:append])

      {:rotated, a2, _} =
        Rotation.maybe_rotate(path,
          rotate_after_lines: 50,
          keep_tail_messages: 10,
          now_fun: fn -> ~U[2026-04-21 11:00:00Z] end
        )

      refute a1 == a2
      assert File.exists?(a1)
      assert File.exists?(a2)
      assert length(Path.wildcard(Path.join(dir, "archive/general/*.md"))) == 2
    end

    test "swap is atomic — no .tmp leftover after success", %{path: path, dir: dir} do
      File.write!(path, build_channel(200))

      assert {:rotated, _, _} =
               Rotation.maybe_rotate(path,
                 rotate_after_lines: 50,
                 keep_tail_messages: 10
               )

      tmp = Path.join(dir, "general.md.rotate.tmp")
      refute File.exists?(tmp)
    end

    test "malformed file with no message headers is a no-op",
         %{path: path} do
      File.write!(path, String.duplicate("line\n", 2000))

      # Exceeds line threshold but has no `## ts | author` messages
      # to split on → no valid boundary → :noop.
      assert :noop =
               Rotation.maybe_rotate(path,
                 rotate_after_lines: 50,
                 keep_tail_messages: 10
               )
    end
  end
end
