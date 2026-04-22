defmodule Glorbo.PathRequestGateTest do
  @moduledoc """
  Unit coverage for the cross-company mode downgrade
  (GEP-27 §151-161, threatmodel T4).

  The director-approved `:write` must become `:read` for any path
  under another company's tree, regardless of how the agent asked.
  """
  use ExUnit.Case, async: true

  alias Glorbo.PathRequestGate

  @base "/fake/home/.glorbo"

  describe "resolve_cross_company_mode/4 — T4 cross-company downgrade" do
    test "own-company :write stays :write" do
      own = Path.join([@base, "companies", "acme", "projects", "web", "notes.md"])
      assert :write == PathRequestGate.resolve_cross_company_mode(own, :write, @base, "acme")
    end

    test "own-company :read stays :read" do
      own = Path.join([@base, "companies", "acme", "projects", "web", "notes.md"])
      assert :read == PathRequestGate.resolve_cross_company_mode(own, :read, @base, "acme")
    end

    test "cross-company :write is downgraded to :read" do
      other = Path.join([@base, "companies", "other-co", "projects", "web", "secrets.md"])

      assert :read ==
               PathRequestGate.resolve_cross_company_mode(other, :write, @base, "acme")
    end

    test "cross-company :read stays :read" do
      other = Path.join([@base, "companies", "other-co", "projects", "web", "secrets.md"])

      assert :read ==
               PathRequestGate.resolve_cross_company_mode(other, :read, @base, "acme")
    end

    test "paths outside any company tree keep the requested mode" do
      host = "/tmp/scratch.md"
      assert :write == PathRequestGate.resolve_cross_company_mode(host, :write, @base, "acme")
      assert :read == PathRequestGate.resolve_cross_company_mode(host, :read, @base, "acme")
    end

    test "bare `companies/<own>` root without trailing slash is downgraded (defense in depth)" do
      # The bare company-root path isn't unambiguously inside the own
      # company's tree (no trailing separator), but it *is* under
      # `companies/` — treat it as cross-company to fail safe rather
      # than grant write access to the directory header.
      bare = Path.join([@base, "companies", "acme"])

      assert :read == PathRequestGate.resolve_cross_company_mode(bare, :write, @base, "acme")
    end

    test "sibling prefix match collision is not mishandled" do
      # "acme-2" starts with "acme" but is a different company; the
      # own_prefix built from `state.company` has a trailing `/` so
      # the prefix match shouldn't accidentally treat acme-2 as own.
      other = Path.join([@base, "companies", "acme-2", "projects", "web", "x.md"])

      assert :read ==
               PathRequestGate.resolve_cross_company_mode(other, :write, @base, "acme")
    end
  end
end
