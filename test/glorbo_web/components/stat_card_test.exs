defmodule GlorboWeb.Components.StatCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GlorboWeb.Components.Spark
  alias GlorboWeb.Components.StatCard

  defp render_card(overrides) do
    base = %{
      label: "agents running",
      value: 3,
      unit: "/ 6",
      sub: "2 idle · 0 crashed",
      spark: [1, 2, 3, 2, 4, 3],
      spark_color: "var(--gl-accent-dim)",
      tone: :accent,
      __changed__: nil
    }

    StatCard.stat_card(Map.merge(base, overrides)) |> rendered_to_string()
  end

  defp render_spark(overrides) do
    base = %{
      data: [],
      color: "var(--gl-accent-dim)",
      label: nil,
      __changed__: nil
    }

    Spark.spark(Map.merge(base, overrides)) |> rendered_to_string()
  end

  describe "stat_card/1" do
    test "renders label/value/unit/sub" do
      html = render_card(%{})
      assert html =~ "agents running"
      assert html =~ "3"
      assert html =~ "/ 6"
      assert html =~ "2 idle"
    end

    test "tone applies modifier class" do
      assert render_card(%{tone: :accent}) =~ "gl-stat-card--accent"
      assert render_card(%{tone: :amber}) =~ "gl-stat-card--amber"
      assert render_card(%{tone: :rose}) =~ "gl-stat-card--rose"
    end

    test "omits unit when not provided" do
      html = render_card(%{unit: nil})
      refute html =~ "gl-stat-card__unit"
    end
  end

  describe "spark/1" do
    test "empty data renders nothing (no gl-spark container)" do
      html = render_spark(%{data: []})
      refute html =~ "gl-spark"
    end

    test "all-zero data renders nothing" do
      html = render_spark(%{data: [0, 0, 0]})
      refute html =~ "gl-spark"
    end

    test "renders one bar per value" do
      html = render_spark(%{data: [1, 2, 3]})
      assert html =~ ~s(class="gl-spark")
      # Three bars
      assert Regex.scan(~r/gl-spark__bar/, html) |> length() == 3
    end

    test "label makes it role=img" do
      html = render_spark(%{data: [1, 2], label: "last 24h"})
      assert html =~ ~s(role="img")
      assert html =~ ~s(aria-label="last 24h")
    end
  end
end
