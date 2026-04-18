defmodule GlorboWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use GlorboWeb, :html

  # If you want to customize your error pages,
  # uncomment the embed_templates/1 call below
  # and add pages to the error directory:
  #
  #   * lib/glorbo_web/controllers/error_html/404.html.heex
  #   * lib/glorbo_web/controllers/error_html/500.html.heex
  #
  # embed_templates "error_html/*"

  # 04-UI-SPEC §Error states — specific copy for the 404 / 500 pages
  # that ship the dashboard. Other templates fall back to the default
  # `status_message_from_template` plain-text render.
  def render("404.html", assigns) do
    ~H"""
    <section class="gl-view">
      <h1 class="gl-heading gl-heading--display">Not found.</h1>
      <p class="gl-muted">
        Check <code>~/.glorbo/companies/</code> or run <code>glorbo reindex</code>.
      </p>
    </section>
    """
  end

  def render("500.html", assigns) do
    ~H"""
    <section class="gl-view">
      <h1 class="gl-heading gl-heading--display">Something broke.</h1>
      <p class="gl-muted">
        Check <code>~/.glorbo/logs/</code> and report at github.com/foobarto/glorbo.
      </p>
    </section>
    """
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

# UAT N6: Plug.Static.InvalidPathError is raised on URL-encoded path
# traversal attempts (e.g. /companies/%2e%2e%2fetc%2fpasswd) BEFORE
# the router has a chance to 404. Phoenix's debug_errors then renders
# a 500. Tell Plug to treat this as a 404 instead — safer UX, no
# security surface lost (Plug.Static's own guard still rejects the
# underlying request).
defimpl Plug.Exception, for: Plug.Static.InvalidPathError do
  def status(_), do: 404
  def actions(_), do: []
end
