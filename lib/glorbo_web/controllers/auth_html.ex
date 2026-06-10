defmodule GlorboWeb.AuthHTML do
  @moduledoc """
  Dead-render templates for the GEP-0053 director passphrase flow
  (`GlorboWeb.AuthController`): the `/login` form and the first-run
  `/setup` wizard.

  Both use the `<.form>` component with an `action`, which auto-injects the
  hidden `_csrf_token` — `:protect_from_forgery` (on the `:browser`
  pipeline) only *validates* it, so the form MUST emit it (GEP-0053 D8).
  No per-route CSRF skip is permitted: skipping `/setup` would make it a
  remote passphrase-planting CSRF.
  """
  use GlorboWeb, :html

  def render("login.html", assigns) do
    ~H"""
    <section class="gl-view gl-auth">
      <h1 class="gl-heading gl-heading--display">Sign in</h1>
      <p class="gl-muted">Enter the director passphrase to access this Glorbo dashboard.</p>

      <.error_flash flash={@flash} />

      <.form :let={_f} for={%{}} as={:auth} action={~p"/login"} method="post">
        <label class="gl-field">
          <span>Passphrase</span>
          <input
            type="password"
            name="passphrase"
            autocomplete="current-password"
            autofocus
            required
          />
        </label>
        <button type="submit" class="gl-btn gl-btn--primary">Sign in</button>
      </.form>
    </section>
    """
  end

  def render("setup.html", assigns) do
    ~H"""
    <section class="gl-view gl-auth">
      <h1 class="gl-heading gl-heading--display">Set your passphrase</h1>
      <p class="gl-muted">
        First-run setup. Choose a director passphrase (at least 8 characters).
        You'll use it to sign in to this dashboard from now on; the <code>dashboard_token</code>
        keeps working for MCP/CLI clients.
      </p>

      <.error_flash flash={@flash} />

      <.form :let={_f} for={%{}} as={:auth} action={~p"/setup"} method="post">
        <label class="gl-field">
          <span>Passphrase</span>
          <input type="password" name="passphrase" autocomplete="new-password" autofocus required />
        </label>
        <label class="gl-field">
          <span>Confirm passphrase</span>
          <input
            type="password"
            name="passphrase_confirmation"
            autocomplete="new-password"
            required
          />
        </label>
        <button type="submit" class="gl-btn gl-btn--primary">Set passphrase</button>
      </.form>
    </section>
    """
  end

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)

  # Minimal inline flash — the auth pages render under the bare root layout
  # (no LiveView flash group), so surface the error directly.
  defp error_flash(assigns) do
    ~H"""
    <p :if={Phoenix.Flash.get(@flash, :error)} class="gl-alert gl-alert--error" role="alert">
      {Phoenix.Flash.get(@flash, :error)}
    </p>
    """
  end
end
