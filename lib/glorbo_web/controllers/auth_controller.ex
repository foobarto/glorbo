defmodule GlorboWeb.AuthController do
  @moduledoc """
  Director passphrase auth flow (GEP-0053): the first-run `/setup` wizard,
  `/login`, and `/logout`.

  These are the dashboard's only dead-render POST forms. They live in the
  unprotected `:browser` scope (so `:protect_from_forgery` covers them) but
  NOT behind `GlorboWeb.DirectorAuth` — they are the auth entry points.
  Each action enforces its own state precondition instead:

    * `/setup`  — BOOTSTRAP only, and only with a valid `dashboard_token`
      (the token is what authorises setting a passphrase before one
      exists). Single-shot: refuses once a hash is present.
    * `/login`  — CONFIGURED only.
    * `/logout` — any state; drops the session.

  On success both `/setup` and `/login` rotate the session
  (`configure_session(renew: true)`, GEP-0053 D4 — defeats fixation) before
  writing the `director_auth` marker, and `/setup` also `put_env`s the new
  hash so the running node flips to CONFIGURED without a restart (D3).

  Throttling, the post-auth `return_to` same-origin guard, the timing
  reference-hash, and the sliding idle timeout are layered on in a
  follow-up (GEP-0053 C3); this module is the functional spine.
  """
  use GlorboWeb, :controller

  alias Glorbo.Config
  alias Glorbo.Filesystem.Hierarchy
  alias GlorboWeb.DirectorAuth
  alias GlorboWeb.LoginThrottle
  alias GlorboWeb.Plugs.DashboardToken

  @min_passphrase 8

  # ── /login ─────────────────────────────────────────────────────────────

  def login_form(conn, _params) do
    case DirectorAuth.auth_state() do
      {:configured, _hash} -> render_login(conn)
      :bootstrap -> redirect(conn, to: "/setup")
      :degraded -> degraded(conn)
    end
  end

  def login_submit(conn, params) do
    passphrase = string_param(params, "passphrase")

    case DirectorAuth.auth_state() do
      {:configured, hash} ->
        verify_and_respond(conn, passphrase, hash)

      :bootstrap ->
        redirect(conn, to: "/setup")

      :degraded ->
        degraded(conn)
    end
  end

  # D14: atomically reserve-or-reject BEFORE the PBKDF2 verify, so a
  # throttled attempt burns zero hashing cost and holds no connection
  # (immediate rejection, never a sleep). `reserve/0` pre-records this
  # attempt as a pending failure in the same serialized call that grants
  # it, so a parallel burst can't all slip past the gate — only this
  # attempt reaches the verify per backoff window.
  defp verify_and_respond(conn, passphrase, hash) do
    case LoginThrottle.reserve() do
      {:throttled, retry_ms} ->
        conn
        |> put_flash(:error, "Too many attempts — wait #{ceil_seconds(retry_ms)}s and try again.")
        |> render_login()

      :ok ->
        if is_binary(passphrase) and Pbkdf2.verify_pass(passphrase, hash) do
          # Clear the pre-recorded failure — a correct passphrase resets it.
          LoginThrottle.record_success()

          conn
          |> establish_director_session(hash)
          |> redirect(to: "/")
        else
          # Leave the pre-recorded failure in place — it escalates the
          # backoff. Generic error — never reveal whether the passphrase
          # was close.
          conn
          |> put_flash(:error, "Incorrect passphrase.")
          |> render_login()
        end
    end
  end

  defp ceil_seconds(ms), do: max(1, div(ms + 999, 1000))

  # ── /setup ───────────────────────────────────────────────────────────────

  def setup_form(conn, params) do
    case DirectorAuth.auth_state() do
      :bootstrap ->
        cond do
          not DashboardToken.authorized?(conn) ->
            unauthorized(conn)

          # Token supplied via the URL query → stash it in the session and
          # redirect to a BARE /setup, so the raw token leaves the address
          # bar (GEP-49 / codex Low). The redirected GET authorises off the
          # session cookie; the form's POST does too — no token in the HTML.
          is_binary(params["token"]) ->
            conn
            |> DashboardToken.remember()
            |> redirect(to: "/setup")

          true ->
            conn
            |> DashboardToken.remember()
            |> render_setup()
        end

      {:configured, _hash} ->
        # Passphrase already set — setup is single-shot. Send to /login.
        redirect(conn, to: "/login")

      :degraded ->
        degraded(conn)
    end
  end

  def setup_submit(conn, params) do
    passphrase = string_param(params, "passphrase")
    confirmation = string_param(params, "passphrase_confirmation")

    cond do
      DirectorAuth.auth_state() != :bootstrap ->
        # Lost the race / already configured — never re-plant (D7).
        redirect(conn, to: "/login")

      not DashboardToken.authorized?(conn) ->
        unauthorized(conn)

      not valid_new_passphrase?(passphrase, confirmation) ->
        conn
        |> put_flash(:error, passphrase_error(passphrase, confirmation))
        |> render_setup()

      true ->
        commit_setup(conn, passphrase)
    end
  end

  # Single-shot commit (D7). The atomic compare-and-set lives in
  # `Config.put_password_hash_if_absent/2` (node-global lock): it writes
  # ONLY when disk has no hash, refuses (`:already_set`) if one is already
  # there (we lost the race / already configured), and fails closed
  # (`:degraded`) on a `:malformed` disk value — never overwriting it.
  defp commit_setup(conn, passphrase) do
    base = Hierarchy.default_root()
    hash = Pbkdf2.hash_pwd_salt(passphrase)

    case Config.put_password_hash_if_absent(base, hash) do
      :ok ->
        # D3: flip the running node to CONFIGURED immediately.
        Application.put_env(:glorbo, :director_password_hash, hash)

        conn
        |> establish_director_session(hash)
        |> redirect(to: "/")

      :already_set ->
        redirect(conn, to: "/login")

      :degraded ->
        degraded(conn)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not save the passphrase. Check the Glorbo logs.")
        |> render_setup()
    end
  end

  # ── /logout ──────────────────────────────────────────────────────────────

  def logout(conn, _params) do
    # D6: drop the session entirely (not a value clear) so the issued
    # cookie stops validating.
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Rotate the session id, then write the passphrase marker (D4/D5).
  defp establish_director_session(conn, hash) do
    conn
    |> configure_session(renew: true)
    |> put_session(DirectorAuth.session_key(), DirectorAuth.session_marker(hash))
  end

  defp render_login(conn), do: render(conn, :login, page_title: "Sign in — Glorbo")
  defp render_setup(conn), do: render(conn, :setup, page_title: "Set your passphrase — Glorbo")

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> text("unauthorized — open the token URL printed by `glorbo serve`")
  end

  defp degraded(conn) do
    conn
    |> put_status(:service_unavailable)
    |> text(
      "Configuration error: director_password_hash is malformed. Run `glorbo reset-password`."
    )
  end

  defp string_param(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp valid_new_passphrase?(passphrase, confirmation) do
    is_binary(passphrase) and String.length(passphrase) >= @min_passphrase and
      passphrase == confirmation
  end

  defp passphrase_error(passphrase, confirmation) do
    cond do
      not is_binary(passphrase) or String.length(passphrase) < @min_passphrase ->
        "Passphrase must be at least #{@min_passphrase} characters."

      passphrase != confirmation ->
        "Passphrases do not match."

      true ->
        "Invalid passphrase."
    end
  end
end
