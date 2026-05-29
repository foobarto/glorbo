defmodule Glorbo.CLI.Lifecycle.Banner do
  @moduledoc """
  State-aware dashboard URL for the `serve` / `up` startup banners
  (GEP-0053 D18).

  The banner must NOT advertise the `?token=` URL once a director
  passphrase is set: the token no longer grants browser access (it's
  MCP/CLI-only), so the URL would be misleading, and reprinting the token
  keeps a standing credential in scrollback / journals. So:

    * **CONFIGURED** (a `$pbkdf2-…$` hash) → bare `…/login` (no token).
    * **BOOTSTRAP** (no hash) → `…/setup?token=<token>` so the operator can
      click straight through to set a passphrase.
    * **DEGRADED** (`:malformed` hash) → `…/login` plus a fix hint.

  The hash value is read from the running app-env (`serve`, in-daemon) or
  the loaded `config.md` (`up`, separate CLI BEAM); this module just maps a
  resolved `(hash, token)` to the right URL.
  """

  @spec dashboard_url(String.t(), binary() | nil | :malformed, binary() | nil) :: String.t()
  def dashboard_url(base_url, hash, token)

  def dashboard_url(base_url, hash, _token) when is_binary(hash) and hash != "" do
    "#{base_url}/login"
  end

  def dashboard_url(base_url, :malformed, _token) do
    "#{base_url}/login  (config error — run `glorbo reset-password`)"
  end

  def dashboard_url(base_url, _bootstrap, token) when is_binary(token) and token != "" do
    "#{base_url}/setup?token=#{token}"
  end

  def dashboard_url(base_url, _bootstrap, _no_token) do
    "#{base_url}/setup  (token: see ~/.glorbo/config.md)"
  end
end
