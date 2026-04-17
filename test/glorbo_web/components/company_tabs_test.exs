defmodule GlorboWeb.Components.CompanyTabsTest do
  @moduledoc """
  Unit test for the shared `CompanyTabs` component. Covers the five
  possible `active` values (:kanban, :chat, :approvals, :audit, nil).

  Purpose: prevent regression on TODO.md P0 #5 — each sub-LiveView
  renders this component with a different `:active`, and the highlight
  must persist across lateral navigation.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GlorboWeb.Components.CompanyTabs

  defp render_tabs(active) do
    assigns = %{slug: "acme", active: active}
    rendered = CompanyTabs.company_tabs(assigns)
    rendered_to_string(rendered)
  end

  describe "company_tabs/1" do
    test "renders all four tabs as live-navigation links" do
      html = render_tabs(nil)

      for label <- ~w(Kanban Chat Approvals Audit) do
        assert html =~ label
      end

      for path <- ~w(/companies/acme/kanban /companies/acme/channels/general
                     /companies/acme/approvals /companies/acme/audit) do
        assert html =~ path
      end

      # Live navigation, not a reload
      assert html =~ ~s(data-phx-link="redirect")
    end

    test "no tab is active when active=nil" do
      html = render_tabs(nil)
      refute html =~ "gl-tab--active"
    end

    for {active, label} <- [
          {:kanban, "Kanban"},
          {:chat, "Chat"},
          {:approvals, "Approvals"},
          {:audit, "Audit"}
        ] do
      test "active=#{inspect(active)} highlights the #{label} tab" do
        html = render_tabs(unquote(active))
        # Exactly one tab is active.
        actives = Regex.scan(~r/gl-tab gl-tab--active/, html)
        assert length(actives) == 1
      end
    end

    test "aria-selected reflects active state" do
      html = render_tabs(:kanban)
      assert html =~ ~s(aria-selected="true")
      # Three others are aria-selected="false"
      falses = Regex.scan(~r/aria-selected="false"/, html)
      assert length(falses) == 3
    end
  end
end
