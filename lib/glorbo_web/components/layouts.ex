defmodule GlorboWeb.Layouts do
  @moduledoc """
  Application layouts. Minimal in Phase 1 — the LiveView dashboard lands in
  Phase 4 and will extend this module with navigation, flash handling, and
  theme toggles.
  """
  use GlorboWeb, :html

  embed_templates "layouts/*"
end
