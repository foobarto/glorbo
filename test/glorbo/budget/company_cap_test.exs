defmodule Glorbo.Budget.CompanyCapTest do
  use ExUnit.Case, async: false

  alias Glorbo.Budget
  alias Glorbo.Budget.CompanyCap
  alias Glorbo.Budget.Ledger
  alias Glorbo.Repo

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo-ccap-#{System.unique_integer([:positive])}")
    co = "acme"
    File.mkdir_p!(Path.join([base, "companies", co, "agents", "eng"]))
    File.mkdir_p!(Path.join([base, "companies", co, "agents", "sales"]))

    # We run these tests inside the sandbox so we can insert Budget rows.
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn ->
      File.rm_rf!(base)
    end)

    {:ok, base: base, company: co}
  end

  defp seed_ledger(slug, cents) do
    Repo.insert!(%Budget{
      agent_slug: slug,
      year_month: Ledger.month_bucket(DateTime.utc_now()),
      cost_usd_cents: cents
    })
  end

  defp write_company_md(base, co, body) do
    File.write!(Path.join([base, "companies", co, "company.md"]), body)
  end

  test "returns :ok when no cap is declared", %{base: base, company: co} do
    write_company_md(base, co, "---\nslug: acme\n---\n")
    seed_ledger("eng", 10_000)

    assert :ok = CompanyCap.check(co, base: base)
  end

  test "returns :ok when cap is configured but usage is low",
       %{base: base, company: co} do
    write_company_md(base, co, """
    ---
    slug: acme
    budget_usd_cents_month: 10000
    ---
    """)

    seed_ledger("eng", 1_000)
    seed_ledger("sales", 2_000)

    assert :ok = CompanyCap.check(co, base: base)
  end

  test "returns {:alert, used, cap} between 80% and 100%",
       %{base: base, company: co} do
    write_company_md(base, co, """
    ---
    slug: acme
    budget_usd_cents_month: 10000
    ---
    """)

    seed_ledger("eng", 4_000)
    seed_ledger("sales", 5_000)

    assert {:alert, 9_000, 10_000} = CompanyCap.check(co, base: base)
  end

  test "returns {:stop, used, cap} at or over 100%",
       %{base: base, company: co} do
    write_company_md(base, co, """
    ---
    slug: acme
    budget_usd_cents_month: 10000
    ---
    """)

    seed_ledger("eng", 6_000)
    seed_ledger("sales", 5_000)

    assert {:stop, 11_000, 10_000} = CompanyCap.check(co, base: base)
  end

  test "ignores usage by other companies' agents", %{base: base, company: co} do
    write_company_md(base, co, """
    ---
    budget_usd_cents_month: 5000
    ---
    """)

    seed_ledger("ghost-agent", 99_999)
    seed_ledger("eng", 100)

    assert :ok = CompanyCap.check(co, base: base)
  end

  test "read_cap parses integer and string values", %{base: base, company: co} do
    write_company_md(base, co, "---\nbudget_usd_cents_month: 12345\n---\n")
    assert 12_345 == CompanyCap.read_cap(base, co)

    write_company_md(base, co, "---\nbudget_usd_cents_month: \"9876\"\n---\n")
    assert 9_876 == CompanyCap.read_cap(base, co)

    write_company_md(base, co, "---\nslug: acme\n---\n")
    assert nil == CompanyCap.read_cap(base, co)
  end

  test "used_this_month sums only this company's agents",
       %{base: base, company: co} do
    seed_ledger("eng", 1_500)
    seed_ledger("sales", 2_500)
    seed_ledger("outsider", 9_000)

    assert 4_000 == CompanyCap.used_this_month(base, co)
  end
end
