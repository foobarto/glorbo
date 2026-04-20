defmodule Glorbo.Inbox.ArchiveTest do
  @moduledoc """
  `Glorbo.Inbox.Archive` — persistent "I handled this" set for
  InboxLive (paperclip-ux-gaps §3 follow-up).
  """
  use ExUnit.Case, async: true

  alias Glorbo.Inbox.Archive

  setup do
    base = Path.join(System.tmp_dir!(), "archive-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  test "empty set for a new company", %{base: base} do
    assert MapSet.size(Archive.list(base, "acme")) == 0
  end

  test "add + list + member?", %{base: base} do
    :ok = Archive.add(base, "acme", "approval:foo")
    set = Archive.list(base, "acme")
    assert Archive.member?(set, "approval:foo")
    refute Archive.member?(set, "approval:bar")
  end

  test "remove round-trips", %{base: base} do
    :ok = Archive.add(base, "acme", "audit:x")
    :ok = Archive.remove(base, "acme", "audit:x")
    refute Archive.member?(Archive.list(base, "acme"), "audit:x")
  end

  test "add is idempotent (no duplicates)", %{base: base} do
    :ok = Archive.add(base, "acme", "k")
    :ok = Archive.add(base, "acme", "k")
    assert MapSet.size(Archive.list(base, "acme")) == 1
  end

  test "corrupt file → empty set", %{base: base} do
    File.mkdir_p!(Path.join([base, "companies", "acme", "audit"]))
    File.write!(Path.join([base, "companies", "acme", "audit", "_inbox_archive.json"]), "}")
    assert MapSet.size(Archive.list(base, "acme")) == 0
  end
end
