defmodule GlorboWeb.DirectorAuth do
  @moduledoc """
  Browser-side auth gate for the director dashboard (GEP-0053).

  Distinct from `GlorboWeb.Plugs.DashboardToken`, which gates the MCP/CLI
  surface (`:api` / `:mcp`) with the `dashboard_token` Bearer credential.
  `DirectorAuth` gates the *human* dashboard with a director **passphrase**
  session, and — once a passphrase is set — the token grants no browser
  access (GEP-0053 D2).

  ## Authority on both transports (D1)

  The dashboard is entirely LiveView, and the persistent `/live` WebSocket
  **bypasses the router pipeline** — plugs run only on the initial HTTP
  dead render. So this module is BOTH:

    * a **plug** (`call/2`) on the protected `:browser` dashboard scope —
      gates the dead render and the plain controller routes; and
    * an **`on_mount/4`** hook (`:ensure_director`) wrapped around the
      dashboard `live` routes via `live_session` — gates the WebSocket
      mount + reconnects, and arms a periodic re-check so a passphrase
      reset force-logs-out already-open tabs.

  The plug alone is insufficient (the socket skips it); the `on_mount`
  alone is insufficient (it doesn't cover plain controller routes). Both
  are load-bearing.

  ## State machine

  Keyed on `Application.get_env(:glorbo, :director_password_hash)` (wired
  from `config.md` by `config/runtime.exs`; updated in-process by `/setup`
  and `glorbo reset-password` so changes take effect without a restart —
  D3):

    * `nil` — **BOOTSTRAP**: no passphrase yet. The protected dashboard
      redirects to `/setup` (which itself enforces a valid `dashboard_token`
      before it will set a passphrase).
    * a `$pbkdf2-…$` string — **CONFIGURED**: a valid `director_auth`
      passphrase session is required, else redirect to `/login`. The
      token grants no browser access here.
    * `:malformed` — **DEGRADED**: the stored hash is corrupt. Fail
      **closed** — never silently revert to bootstrap (D9).

  ## Session marker (D5)

  The signed session carries `director_auth` =
  `sha256("director-session/v1|" <> hash)`, a domain-separated fingerprint
  of the full encoded PBKDF2 hash. Changing or resetting the passphrase
  changes the hash, hence the marker, invalidating every outstanding
  cookie for free. Distinct from the GEP-48 `dashboard_auth` token
  fingerprint — `DirectorAuth` checks ONLY `director_auth`, never the
  token marker (D2). Compared in constant time.
  """
  @behaviour Plug

  import Plug.Conn

  alias GlorboWeb.Plugs.DashboardToken

  require Logger

  # Session key holding the passphrase-session fingerprint. Distinct from
  # GEP-48's "dashboard_auth" (token) key — never honoured here (D2).
  @session_key "director_auth"

  # Domain-separation label so a passphrase marker can never be confused
  # with the GEP-48 token fingerprint (sha256(token)) by a future refactor.
  @marker_label "director-session/v1|"

  # How often a connected LiveView re-checks its session against the live
  # hash, so a passphrase reset/change disconnects open tabs within the
  # window rather than only on the next full navigation (D1, D4 finding).
  @revalidate_ms :timer.seconds(60)

  @typedoc "Resolved browser-auth state."
  @type state :: :bootstrap | {:configured, binary()} | :degraded

  @doc """
  Resolve the current browser-auth state from the runtime app-env.
  """
  @spec auth_state() :: state()
  def auth_state do
    case Application.get_env(:glorbo, :director_password_hash) do
      hash when is_binary(hash) and hash != "" -> {:configured, hash}
      :malformed -> :degraded
      _ -> :bootstrap
    end
  end

  @doc """
  The signed-session fingerprint for a given stored PBKDF2 `hash`.

  This is what `/login` and `/setup` write into the session on success and
  what the gate compares against. Exposed so the auth controller (and test
  support) can mint a matching session without duplicating the derivation.
  """
  @spec session_marker(binary()) :: binary()
  def session_marker(hash) when is_binary(hash) do
    :crypto.hash(:sha256, @marker_label <> hash) |> Base.url_encode64(padding: false)
  end

  @doc "The session key under which the marker is stored."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  # ── Plug (dead-render gate) ────────────────────────────────────────────

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case auth_state() do
      :degraded ->
        conn |> degraded_response() |> halt()

      :bootstrap ->
        # No passphrase yet — funnel the browser to /setup, which enforces
        # the dashboard_token before it will set one. No long-lived
        # tokenless window: every protected route bounces here. If a valid
        # token is present, stash it in the session and redirect to a BARE
        # /setup so the raw token leaves the URL (GEP-49 / codex Low) rather
        # than riding through in `?token=`.
        conn |> maybe_remember_token() |> redirect_to("/setup") |> halt()

      {:configured, hash} ->
        if conn_authenticated?(conn, hash) do
          conn
        else
          conn |> redirect_to("/login") |> halt()
        end
    end
  end

  # Stash a valid bootstrap token into the session so the subsequent bare
  # /setup authorises off the session cookie, keeping the raw token out of
  # the redirect Location + the address bar (GEP-49). No-op if no valid
  # token is present (the bare /setup then 401s).
  defp maybe_remember_token(conn) do
    if DashboardToken.authorized?(conn), do: DashboardToken.remember(conn), else: conn
  end

  defp conn_authenticated?(conn, hash) do
    case get_session(conn, @session_key) do
      marker when is_binary(marker) ->
        Plug.Crypto.secure_compare(marker, session_marker(hash))

      _ ->
        false
    end
  end

  # A 302 without dragging in Phoenix.Controller (keeps the plug lean and
  # avoids a flash/format dependency on the bare gate).
  defp redirect_to(conn, path) do
    conn
    |> put_resp_header("location", path)
    |> put_resp_content_type("text/html")
    |> send_resp(
      302,
      ~s(<html><body>You are being <a href="#{path}">redirected</a>.</body></html>)
    )
  end

  defp degraded_response(conn) do
    Logger.error(
      "director_password_hash is malformed in config.md — refusing browser " <>
        "access (fail-closed). Run `glorbo reset-password` to recover."
    )

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      503,
      "<html><body><h1>Configuration error</h1><p>The director passphrase " <>
        "in <code>config.md</code> is malformed. Run <code>glorbo " <>
        "reset-password</code> to reset it, then restart Glorbo.</p></body></html>"
    )
  end

  # ── on_mount (LiveView socket gate) ────────────────────────────────────

  @doc """
  `live_session` hook: gate the LiveView socket on the passphrase session.

  Runs on both the (dead-render) and connected mounts of every dashboard
  LiveView. On the connected mount it also arms a 60s re-validation timer
  (via an attached `handle_info` hook) so a passphrase reset/change
  disconnects the tab rather than letting an already-mounted socket keep
  acting until it is closed (D1).
  """
  def on_mount(:ensure_director, _params, session, socket) do
    case auth_state() do
      {:configured, hash} ->
        if session_authenticated?(session, hash) do
          {:cont, arm_revalidation(socket, session)}
        else
          {:halt, redirect_socket(socket, "/login")}
        end

      :bootstrap ->
        {:halt, redirect_socket(socket, "/setup")}

      :degraded ->
        {:halt, redirect_socket(socket, "/login")}
    end
  end

  defp session_authenticated?(session, hash) when is_map(session) do
    case Map.get(session, @session_key) do
      marker when is_binary(marker) ->
        Plug.Crypto.secure_compare(marker, session_marker(hash))

      _ ->
        false
    end
  end

  defp session_authenticated?(_session, _hash), do: false

  # Arm the periodic re-check only on the connected socket (the dead-render
  # mount has no live process to message). Captures the session marker seen
  # at mount; each tick re-derives the marker from the CURRENT hash, so a
  # reset/change (new hash → new marker) fails the compare and redirects.
  defp arm_revalidation(socket, session) do
    if Phoenix.LiveView.connected?(socket) do
      Process.send_after(self(), :director_revalidate, @revalidate_ms)

      Phoenix.LiveView.attach_hook(
        socket,
        :director_revalidate,
        :handle_info,
        &revalidate_hook(&1, &2, session)
      )
    else
      socket
    end
  end

  defp revalidate_hook(:director_revalidate, socket, session) do
    case auth_state() do
      {:configured, hash} ->
        if session_authenticated?(session, hash) do
          Process.send_after(self(), :director_revalidate, @revalidate_ms)
          {:halt, socket}
        else
          {:halt, redirect_socket(socket, "/login")}
        end

      _ ->
        {:halt, redirect_socket(socket, "/login")}
    end
  end

  defp revalidate_hook(_msg, socket, _session), do: {:cont, socket}

  defp redirect_socket(socket, path), do: Phoenix.LiveView.redirect(socket, to: path)
end
