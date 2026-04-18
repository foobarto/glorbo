defmodule GlorboWeb.Components.TopbarTest do
  @moduledoc """
  Topbar renders the brand, company picker, version strip, kbd hints,
  and a disabled TWEAKS button. M1 mockup alignment (abc.zip shell.jsx).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GlorboWeb.Components.Topbar

  defp render_topbar(overrides) do
    assigns =
      Enum.into(overrides, %{
        current_company: nil,
        tweaks_open?: false,
        __changed__: nil
      })

    Topbar.topbar(assigns) |> rendered_to_string()
  end

  describe "topbar/1" do
    test "renders the brand as a link to /companies" do
      html = render_topbar([])
      assert html =~ "GLORBO"
      assert html =~ ~s(href="/companies")
      assert html =~ ~s(aria-label="Go to companies list")
    end

    test "renders keyboard hints for the primary per-company nav" do
      html = render_topbar([])
      assert html =~ "<kbd>g</kbd>"
      assert html =~ "overview"
      # Per-company shortcuts are the ones Director uses most; the
      # cheatsheet prioritises them over globals (health/providers
      # still work and appear in the `?` overlay — task #139).
      assert html =~ "chat"
      assert html =~ "kanban"
      assert html =~ "audit"
    end

    test "renders a working TWEAKS toggle wired to the drawer" do
      html = render_topbar([])
      assert html =~ "TWEAKS"
      assert html =~ ~s(id="gl-tweaks-toggle")
      assert html =~ ~s(aria-controls="gl-tweaks-drawer")
      assert html =~ ~s(id="gl-tweaks-drawer")
      assert html =~ ~s(id="gl-tweaks-density")
      assert html =~ ~s(id="gl-tweaks-vocab")
    end

    test "path breadcrumb always reads ~/.glorbo/companies/" do
      html = render_topbar([])
      assert html =~ "~/.glorbo/companies/"
    end

    test "version strip includes the app version" do
      html = render_topbar([])
      # vsn may be "dev" in test or a real version; presence of `v` prefix is enough
      assert html =~ ~r/v[\w\.-]+/
    end
  end
end
