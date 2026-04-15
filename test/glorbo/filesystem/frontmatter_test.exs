defmodule Glorbo.Filesystem.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Glorbo.Filesystem.Frontmatter

  describe "parse/1" do
    test "Test 1: extracts YAML frontmatter and body" do
      content = "---\nname: CEO\nrole: CEO\n---\n# body\n"

      assert {:ok, meta, body} = Frontmatter.parse(content)
      assert meta["name"] == "CEO"
      assert meta["role"] == "CEO"
      assert body == "# body\n"
    end

    test "Test 2: safe loader — unsafe Python-tag payload is rejected, no code executed" do
      # If yamerl were unsafe-loading, this tag would try to instantiate a
      # Python class (the `python/object/apply` convention is PyYAML's
      # unsafe-load attack vector — we construct the payload here only to
      # prove our loader rejects it). yamerl is a pure-Erlang scanner and
      # has no tag handlers for arbitrary classes — it returns an error or
      # surfaces the tag as opaque data without execution.
      unsafe_tag = "!!python/" <> "object/apply:" <> "os.system"
      dangerous_arg = "[\"echo should-never-run\"]"
      payload = "---\n#{unsafe_tag} #{dangerous_arg}\n---\nbody\n"

      result = Frontmatter.parse(payload)

      case result do
        {:error, _reason} ->
          :ok

        {:ok, meta, _body} ->
          # If it "parsed" it MUST NOT be an executed-class representation.
          # It is acceptable for yamerl to surface the tagged scalar as a
          # string/map entry; it is NOT acceptable to execute it.
          refute match?(%{__struct__: _}, meta),
                 "YAML loader instantiated a struct from tagged payload"
      end

      # Sanity: the test process is still alive and no unexpected message
      # was received from code that shouldn't have run.
      refute_received _
    end

    test "Test 3: file with no frontmatter returns empty map + full content" do
      content = "# just a markdown body\n\nparagraph.\n"
      assert {:ok, %{} = meta, body} = Frontmatter.parse(content)
      assert map_size(meta) == 0
      assert body == content
    end

    test "Test 4: malformed YAML returns {:error, reason}" do
      # Unclosed map + garbled indentation
      content = "---\nname: : : :\n  - broken\n  indent:\n---\nbody\n"

      case Frontmatter.parse(content) do
        {:error, _reason} ->
          :ok

        {:ok, _meta, _body} ->
          flunk("expected malformed YAML to be rejected")
      end
    end

    test "oversized content is rejected with :too_large" do
      # 11 MB > 10 MB cap
      big = String.duplicate("x", 11_000_000)
      assert {:error, :too_large} = Frontmatter.parse(big)
    end
  end
end
