defmodule Glorbo.Company.ProposalsTest do
  @moduledoc """
  Targeted regression tests for `Glorbo.Company.Proposals` — the
  agent-controlled proposal frontmatter surface.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Company.Proposals

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-proposals-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([base, "companies", "acme", "proposals"]))
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp write_proposal!(base, id, frontmatter, body \\ "body\n") do
    path = Path.join([base, "companies", "acme", "proposals", "#{id}.md"])
    File.write!(path, "---\n#{frontmatter}\n---\n\n#{body}")
    path
  end

  # Codex pre-push review of 7e750cd (PR #38): `scalar_cap/1`
  # initially routed non-binary, non-nil values through
  # `to_string/1`, which raises `Protocol.UndefinedError` for
  # maps, tuples, and nested lists. YamlElixir parses a YAML
  # mapping in a scalar slot as a `%{}`, so a malicious agent
  # writing `subtype:\n  key: value` in proposal frontmatter
  # crashed the proposal-list render (the `with ... else _ -> nil`
  # in `read_one/1` does NOT catch raises from inside the body).
  describe "list/2 — frontmatter scalar safety (codex pre-push review)" do
    test "non-binary scalar values do not crash the list path", %{base: base} do
      # Each of these is a forged shape codex flagged:
      # YAML mapping (parses to %{}), YAML sequence (list),
      # bare atom-ish token, integer (already YAML-native).
      shapes = [
        # YAML inline mapping
        ~s|id: forged-1
subtype:
  key: value
status: pending-approval
proposed_by: agent_a
proposed_at: 2026-05-25T10:00:00Z|,
        # YAML sequence
        ~s|id: forged-2
subtype:
  - item-a
  - item-b
status: pending-approval
proposed_by: agent_a
proposed_at: 2026-05-25T10:00:00Z|,
        # Integer scalar
        ~s|id: forged-3
subtype: 42
status: pending-approval
proposed_by: agent_a
proposed_at: 2026-05-25T10:00:00Z|
      ]

      for {fm, idx} <- Enum.with_index(shapes) do
        write_proposal!(base, "forged-#{idx + 1}", fm)
      end

      # `list/2` must NOT raise — the previous shape crashed on the
      # first forged frontmatter.
      proposals = Proposals.list("acme", base: base)
      assert is_list(proposals)
      # All three forged proposals should appear (the scalar_cap
      # falls back to inspect/2 + safe-byte-slice; non-binary values
      # become bounded strings, not crashes).
      assert length(proposals) == 3
    end

    test "binary scalars pass through capped at 240 bytes", %{base: base} do
      big = String.duplicate("x", 1_000)

      write_proposal!(base, "binary-cap", """
      id: binary-cap
      subtype: #{big}
      status: pending-approval
      proposed_by: agent_a
      proposed_at: 2026-05-25T10:00:00Z
      """)

      [%{subtype: capped} | _] = Proposals.list("acme", base: base)
      assert byte_size(capped) <= 240
    end
  end
end
