defmodule GlorboWeb.Components.StatusPillTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GlorboWeb.Components.StatusPill

  defp render_pill(overrides) do
    assigns = Enum.into(overrides, %{status: :idle, label: nil, __changed__: nil})
    StatusPill.status_pill(assigns) |> rendered_to_string()
  end

  describe "status_pill/1" do
    for status <- [:alive, :idle, :warn, :stop, :info] do
      test "renders the #{status} variant" do
        html = render_pill(status: unquote(status))
        assert html =~ "gl-pill--" <> Atom.to_string(unquote(status))
        assert html =~ "gl-pill__dot"
      end
    end

    test "falls back to the status name when no label or slot is provided" do
      html = render_pill(status: :alive)
      assert html =~ "alive"
    end

    test "uses explicit label when provided" do
      html = render_pill(status: :warn, label: "budget 92%")
      assert html =~ "budget 92%"
      refute html =~ ">warn<"
    end
  end
end
