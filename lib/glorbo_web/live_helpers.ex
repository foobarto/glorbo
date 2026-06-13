defmodule GlorboWeb.LiveHelpers do
  @moduledoc """
  Cross-LiveView helpers. These used to be `defp` copies scattered
  across 8 LV files; REVIEW.md 2026-04-18 flagged the duplication,
  hence this module.

  Each helper is a pure transformation — no PubSub subscriptions, no
  GenServer state — so LVs can call them from any callback without
  worrying about the socket lifecycle.
  """

  alias Glorbo.Filesystem.Hierarchy

  @doc """
  Filesystem base dir for the dashboard (the `~/.glorbo` root, or
  whatever `:glorbo_base` resolves to — see `Hierarchy.default_root/0`).
  """
  @spec base_dir() :: Path.t()
  def base_dir, do: Hierarchy.default_root()

  @coalesce_reload_ms 250

  @doc """
  Coalesce a burst of high-frequency re-render triggers (inotify
  `:file_event`s) into a single deferred reload.

  An active agent writes many files per second; without coalescing each
  `:file_event` drove a full `load_*` reload + whole-page re-render,
  which thrashed layout (the document height oscillated several times a
  second) and clobbered open modals / in-flight form inputs — the page
  was unusable while any agent worked.

  Call this from the high-frequency `handle_info({:file_event, …})`
  clause and perform the real reload in the `reload_msg` handler,
  clearing the latch there with `clear_reload_pending/2`. Repeated calls
  while a reload is already pending are no-ops, so a burst collapses to
  one reload per window.

  `latch_key` names the assign used as the pending-flag. A LiveView that
  coalesces two *independent* high-frequency streams (e.g. `:file_event`
  and `:agent_status`) must give each its own latch — sharing one means
  a pending reload of one kind suppresses scheduling the other, and the
  message that fires clears the shared latch on behalf of both. Pass a
  distinct `latch_key` (and matching `reload_msg`) per stream.
  """
  @spec schedule_coalesced_reload(Phoenix.LiveView.Socket.t(), term(), pos_integer(), atom()) ::
          Phoenix.LiveView.Socket.t()
  def schedule_coalesced_reload(
        socket,
        reload_msg \\ :coalesced_reload,
        delay_ms \\ @coalesce_reload_ms,
        latch_key \\ :reload_pending?
      ) do
    if socket.assigns[latch_key] do
      socket
    else
      Process.send_after(self(), reload_msg, delay_ms)
      Phoenix.Component.assign(socket, latch_key, true)
    end
  end

  @doc "Clear the coalesced-reload latch set by `schedule_coalesced_reload/4`."
  @spec clear_reload_pending(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def clear_reload_pending(socket, latch_key \\ :reload_pending?),
    do: Phoenix.Component.assign(socket, latch_key, false)

  @doc """
  Pretty-print the base dir for UI labels. When the base is the
  default `~/.glorbo/` under the director's home, render that
  literally (shorter, recognisable). Otherwise render the real
  absolute path — directors running with a `GLORBO_HOME` override
  (UAT workspaces, multi-instance dev setups) must not see a
  label that lies about where their data lives.

  Examples:
    * `~/.glorbo` default → `"~/.glorbo"`
    * `/tmp/glorbo-uat-xxx` override → `"/tmp/glorbo-uat-xxx"`
  """
  @spec display_base() :: String.t()
  def display_base do
    base = base_dir()
    default = Path.expand("~/.glorbo")

    if base == default, do: "~/.glorbo", else: base
  end

  @doc """
  Display string for the XDG config root (GEP-61) — where provider config +
  credentials live, out of the `~/.glorbo` data tree. `~`-abbreviated when it
  is the default `~/.config/glorbo`.
  """
  @spec display_config_base() :: String.t()
  def display_config_base do
    root = Hierarchy.config_root()
    default = Path.expand("~/.config/glorbo")

    if root == default, do: "~/.config/glorbo", else: root
  end

  @doc """
  Current UTC year-month as `"YYYY-MM"` — the bucket key used by
  `Glorbo.Budget.Ledger` and `Glorbo.Company.AuditLog` month files.
  """
  @spec current_year_month() :: String.t()
  def current_year_month do
    d = Date.utc_today()
    "#{d.year}-#{String.pad_leading(Integer.to_string(d.month), 2, "0")}"
  end

  @doc """
  Classify a `used/cap` budget ratio into `{pct, class}` where `class`
  is a color keyword the template maps to a CSS modifier. Returns
  `{0, nil}` when `cap` is zero or not numeric (avoids div-by-zero).

  Thresholds: 80% → amber, 90% → rose. These match the BudgetRing
  component's visual breakpoints.
  """
  @spec budget_classify(number() | any(), number() | any()) :: {integer(), String.t() | nil}
  def budget_classify(_used, cap) when not is_number(cap) or cap <= 0, do: {0, nil}

  def budget_classify(used, cap) when is_number(used) do
    pct = min(round(used / cap * 100), 100)

    cls =
      cond do
        pct > 90 -> "rose"
        pct > 80 -> "amber"
        true -> nil
      end

    {pct, cls}
  end

  def budget_classify(_, _), do: {0, nil}

  @doc """
  Format a number with 2 decimal places, e.g. `12.00`. Non-numbers
  become `"0.00"` — the safer default for currency-style displays.
  """
  @spec two_dp(number() | any()) :: String.t()
  def two_dp(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  def two_dp(_), do: "0.00"

  @doc """
  Format a number with 0 decimal places. Non-numbers become `"0"`.
  """
  @spec zero_dp(number() | any()) :: String.t()
  def zero_dp(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 0)
  def zero_dp(_), do: "0"
end
