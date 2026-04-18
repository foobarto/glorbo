defmodule GlorboWeb.ProjectLiveTest do
  use GlorboWeb.LiveCase, async: false

  test "renders project header + stats + config for seeded website project",
       %{conn: conn, base: base} do
    # Seed a project.md with name + icon.
    proj_dir = Path.join([base, "companies", "acme", "projects", "website"])
    File.mkdir_p!(proj_dir)

    File.write!(Path.join(proj_dir, "project.md"), """
    ---
    name: "Website"
    icon: "fa-globe"
    description: "Public marketing site."
    ---

    The public-facing website project.
    """)

    {:ok, _view, html} = live(conn, ~p"/companies/acme/projects/website")

    assert html =~ "Website"
    assert html =~ "fa-globe"
    assert html =~ "Public marketing site"
    assert html =~ "tasks"
    assert html =~ "config"
  end

  test "unknown project redirects to company", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme"}}} =
             live(conn, ~p"/companies/acme/projects/ghost")
  end

  test "save_project writes project.md with new name + icon + description",
       %{conn: conn, base: base} do
    proj_dir = Path.join([base, "companies", "acme", "projects", "website"])
    File.mkdir_p!(proj_dir)
    File.write!(Path.join(proj_dir, "project.md"), "---\n---\n")

    {:ok, view, _} = live(conn, ~p"/companies/acme/projects/website")

    # Flip to edit mode.
    render_click(view, "edit")

    render_submit(view, "save_project", %{
      "name" => "Website Redesign",
      "icon" => "fa-rocket",
      "description" => "Q3 refresh."
    })

    content = File.read!(Path.join(proj_dir, "project.md"))
    assert content =~ ~s(name: "Website Redesign")
    assert content =~ ~s(icon: "fa-rocket")
    assert content =~ ~s(description: "Q3 refresh.")
  end

  test "save_project sanitises a bogus icon (drops rather than writes it)",
       %{conn: conn, base: base} do
    proj_dir = Path.join([base, "companies", "acme", "projects", "website"])
    File.mkdir_p!(proj_dir)
    File.write!(Path.join(proj_dir, "project.md"), "---\n---\n")

    {:ok, view, _} = live(conn, ~p"/companies/acme/projects/website")
    render_click(view, "edit")

    render_submit(view, "save_project", %{
      "name" => "Website",
      "icon" => "<script>alert(1)</script>",
      "description" => ""
    })

    content = File.read!(Path.join(proj_dir, "project.md"))
    refute content =~ "script"
    refute content =~ "icon:"
  end

  test "missing project.md auto-creates a stub on first mount",
       %{conn: conn, base: base} do
    proj_dir = Path.join([base, "companies", "acme", "projects", "website"])
    File.mkdir_p!(proj_dir)
    # Fixture may seed one; remove it so we can assert auto-create.
    File.rm(Path.join(proj_dir, "project.md"))
    refute File.exists?(Path.join(proj_dir, "project.md"))

    {:ok, _view, _html} = live(conn, ~p"/companies/acme/projects/website")

    assert File.exists?(Path.join(proj_dir, "project.md"))
  end
end
