defmodule Glorbo.Shell.Views.CommonTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Common
  alias TermUI.Event.Key

  describe "cursor_nav_event/1" do
    test "arrow keys → cursor motion msgs" do
      assert Common.cursor_nav_event(%Key{key: :up}) == {:msg, :cursor_up}
      assert Common.cursor_nav_event(%Key{key: :down}) == {:msg, :cursor_down}
    end

    test "j / k → cursor down / up" do
      assert Common.cursor_nav_event(%Key{key: :char, char: "j"}) == {:msg, :cursor_down}
      assert Common.cursor_nav_event(%Key{key: :char, char: "k"}) == {:msg, :cursor_up}
    end

    test "r → :refresh; q → :quit" do
      assert Common.cursor_nav_event(%Key{key: :char, char: "r"}) == {:msg, :refresh}
      assert Common.cursor_nav_event(%Key{key: :char, char: "q"}) == {:msg, :quit}
    end

    test "any other char → :ignore (so view-specific dispatch can chain)" do
      assert Common.cursor_nav_event(%Key{key: :char, char: "x"}) == :ignore
      assert Common.cursor_nav_event(%Key{key: :char, char: "a"}) == :ignore
    end

    test "non-Key events → :ignore" do
      assert Common.cursor_nav_event(%Key{key: :backspace}) == :ignore
      assert Common.cursor_nav_event(%Key{key: :enter}) == :ignore
      assert Common.cursor_nav_event(:not_a_key) == :ignore
    end
  end

  describe "cursor_down/2" do
    test "advances cursor by 1 within bounds" do
      assert {%{cursor: 1}, []} = Common.cursor_down(%{cursor: 0}, 3)
      assert {%{cursor: 2}, []} = Common.cursor_down(%{cursor: 1}, 3)
    end

    test "clamps at len - 1" do
      assert {%{cursor: 2}, []} = Common.cursor_down(%{cursor: 2}, 3)
    end

    test "clamps at 0 when list is empty" do
      assert {%{cursor: 0}, []} = Common.cursor_down(%{cursor: 0}, 0)
    end
  end

  describe "cursor_up/1" do
    test "decrements cursor by 1 within bounds" do
      assert {%{cursor: 0}, []} = Common.cursor_up(%{cursor: 1})
      assert {%{cursor: 1}, []} = Common.cursor_up(%{cursor: 2})
    end

    test "clamps at 0" do
      assert {%{cursor: 0}, []} = Common.cursor_up(%{cursor: 0})
    end
  end

  describe "clamp_cursor/2" do
    test "0-length list always returns 0" do
      assert Common.clamp_cursor(0, 0) == 0
      assert Common.clamp_cursor(5, 0) == 0
    end

    test "cursor in bounds is preserved" do
      assert Common.clamp_cursor(1, 3) == 1
      assert Common.clamp_cursor(2, 3) == 2
    end

    test "cursor past last index clamps to len - 1" do
      assert Common.clamp_cursor(5, 3) == 2
      assert Common.clamp_cursor(100, 1) == 0
    end
  end
end
