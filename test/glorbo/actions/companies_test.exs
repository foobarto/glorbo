defmodule Glorbo.Actions.CompaniesTest do
  @moduledoc """
  Unit tests for `Glorbo.Actions.Companies` (GEP-36 Round M-1).
  Mirrors the shape of `Glorbo.Actions.TasksTest`: a tmp
  `~/.glorbo/`-shaped tree plus a `FakeAudit` sink.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Actions.Companies
  alias Glorbo.Test.TmpGlorboHome

  defmodule FakeAudit do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, []}

    @impl true
    def handle_call({:append, entry}, _from, state),
      do: {:reply, :ok, [entry | state]}

    def handle_call(:calls, _from, state),
      do: {:reply, Enum.reverse(state), state}
  end

  setup do
    base = TmpGlorboHome.setup()
    co_dir = Path.join([base, "companies", "acme"])
    File.mkdir_p!(co_dir)
    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit, co_dir: co_dir}
  end

  describe "update/3 happy path" do
    test "writes company.md atomically with canonical YAML and emits company.update audit",
         %{base: base, audit: audit, co_dir: co_dir} do
      params = %{
        "name" => "Acme Inc",
        "description" => "widgets",
        "icon" => "rocket",
        "monthly_usd" => "25",
        "body" => "About us.\n\nMore text."
      }

      assert {:ok, %{abs_path: abs, rel_path: "company.md"}} =
               Companies.update("acme", params,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert abs == Path.join(co_dir, "company.md")
      content = File.read!(abs)
      assert content =~ "kind: company/v1"
      assert content =~ "slug: acme"
      assert content =~ "name: Acme Inc"
      assert content =~ "description: widgets"
      assert content =~ "icon: rocket"
      assert content =~ "budget:\n  monthly_usd: 25.0"
      assert content =~ "About us."

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "company.update"
      assert event[:actor] == "director"
      assert event[:target] == "company.md"
      assert event[:company] == "acme"
      assert event[:name] == "Acme Inc"
      assert event["description"] == "widgets"
      assert event["icon"] == "rocket"
      assert event["monthly_usd"] == "25.0"
    end

    test "quotes YAML-unsafe name characters",
         %{base: base, audit: audit} do
      params = %{"name" => ~s(foo: bar #baz), "description" => "x"}

      assert {:ok, %{abs_path: abs}} =
               Companies.update("acme", params,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.read!(abs) =~ ~s(name: "foo: bar #baz")
    end

    test "omits budget block when monthly_usd is blank or unparseable",
         %{base: base, audit: audit, co_dir: co_dir} do
      params = %{"name" => "Acme", "monthly_usd" => ""}

      assert {:ok, _} =
               Companies.update("acme", params,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      content = File.read!(Path.join(co_dir, "company.md"))
      refute content =~ "budget:"

      params2 = %{"name" => "Acme", "monthly_usd" => "not-a-number"}

      assert {:ok, _} =
               Companies.update("acme", params2,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      content2 = File.read!(Path.join(co_dir, "company.md"))
      refute content2 =~ "budget:"
    end

    test "empty optional fields drop out of the YAML block",
         %{base: base, audit: audit, co_dir: co_dir} do
      params = %{"name" => "Acme"}

      assert {:ok, _} =
               Companies.update("acme", params,
                 actor: "director",
                 base: base,
                 audit: audit
               )

      content = File.read!(Path.join(co_dir, "company.md"))
      refute content =~ "description:"
      refute content =~ "icon:"
      refute content =~ "budget:"
    end
  end

  describe "update/3 validation" do
    test "returns :name_required when name is blank after trim",
         %{base: base, audit: audit} do
      assert {:error, :name_required} =
               Companies.update("acme", %{"name" => "   "},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects invalid company slugs",
         %{base: base, audit: audit} do
      assert {:error, {:invalid_slug, :company, "../etc"}} =
               Companies.update("../etc", %{"name" => "x"},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "raises when :actor is missing — matches Actions.Tasks boundary",
         %{base: base, audit: audit} do
      assert_raise KeyError, fn ->
        Companies.update("acme", %{"name" => "x"}, base: base, audit: audit)
      end
    end
  end

  describe "atomic_write semantics" do
    test "no .tmp sibling remains after a successful write",
         %{base: base, audit: audit, co_dir: co_dir} do
      assert {:ok, _} =
               Companies.update("acme", %{"name" => "Acme"},
                 actor: "director",
                 base: base,
                 audit: audit
               )

      assert File.exists?(Path.join(co_dir, "company.md"))
      refute File.exists?(Path.join(co_dir, "company.md.tmp"))
    end
  end
end
