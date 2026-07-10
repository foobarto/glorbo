defmodule Glorbo.SlugTest do
  use ExUnit.Case, async: true

  alias Glorbo.Slug

  test "agent slugs use the parser's underscore-aware contract" do
    assert Slug.valid?("backend_engineer", :agent)
    assert Slug.valid?("a-1_b", :agent)
    refute Slug.valid?("1engineer", :agent)
    refute Slug.valid?("UPPER", :agent)
    refute Slug.valid?("agent/escape", :agent)
    assert Slug.valid?("a" <> String.duplicate("b", 63), :agent)
    refute Slug.valid?("a" <> String.duplicate("b", 64), :agent)
  end

  test "generic URL slugs retain the hyphen-only contract" do
    assert Slug.valid?("acme-inc")
    refute Slug.valid?("acme_inc")
  end

  test "channel slugs accept underscore agents only in the reserved DM form" do
    assert Slug.valid?("general", :channel)
    assert Slug.valid?("dm-director--backend_engineer", :channel)
    refute Slug.valid?("backend_engineer", :channel)
    refute Slug.valid?("dm-director--../escape", :channel)
  end
end
