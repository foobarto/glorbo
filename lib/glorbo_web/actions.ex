defmodule GlorboWeb.Actions do
  @moduledoc """
  Thin delegation facade over `Glorbo.Actions` (GEP-36).

  Exists for backwards-compat during the v0.8.0 Actions-extraction
  cut so individual LiveView + MCP callers can migrate to
  `Glorbo.Actions.*` one at a time. Slated for removal in v0.9.0
  once no caller references `GlorboWeb.Actions` directly.

  Do NOT add new functions here. New write-path operations go in
  `Glorbo.Actions` in core; web/shell/mcp frontends call core
  directly.
  """

  defdelegate post_message(company, channel, body, opts \\ []), to: Glorbo.Actions

  defdelegate post_task_comment(company, task_path, body, opts \\ []), to: Glorbo.Actions

  defdelegate set_approval(company, task_path, decision, opts \\ []), to: Glorbo.Actions

  defdelegate wake_agent(company, agent, reason, opts \\ []), to: Glorbo.Actions
end
