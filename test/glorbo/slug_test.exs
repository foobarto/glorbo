defmodule Glorbo.SlugTest do
  use ExUnit.Case, async: true

  alias Glorbo.Slug

  test "agent slugs use the parser's underscore-aware contract" do
    assert Slug.valid?("backend_engineer", :agent)
    assert Slug.valid?("a-1_b", :agent)
    refute Slug.valid?("1engineer", :agent)
    refute Slug.valid?("UPPER", :agent)
    refute Slug.valid?("agent/escape", :agent)
  end

  test "generic URL slugs retain the hyphen-only contract" do
    assert Slug.valid?("acme-inc")
    refute Slug.valid?("acme_inc")
  end
end
