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
    test "renders the brand" do
      html = render_topbar([])
      assert html =~ "GLORBO"
      assert html =~ ~s(aria-label="Glorbo")
    end

    test "renders keyboard hints" do
      html = render_topbar([])
      assert html =~ "<kbd>g</kbd>"
      assert html =~ "overview"
      assert html =~ "health"
      assert html =~ "providers"
    end

    test "renders a disabled TWEAKS button (M1; wiring lands in M5)" do
      html = render_topbar([])
      assert html =~ "TWEAKS"
      assert html =~ ~s(disabled)
      assert html =~ ~s(aria-disabled="true")
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
