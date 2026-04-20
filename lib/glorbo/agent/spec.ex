defmodule Glorbo.Agent.Spec do
  @moduledoc """
  Runtime-only agent specification produced by `Glorbo.Agent.Parser.parse_file/1`.

  Distinct from the persisted `Glorbo.Agent` Ecto schema (Plan 02 D-36):
  `Glorbo.Agent` mirrors whatever `Glorbo.Filesystem.Reindex` extracted from
  disk; `Spec` is the strict-validated, runtime-only parse product that
  `Glorbo.Agent.Server` consumes on every wake.

  A `Spec` is ephemeral — rebuilt from `agent.md` on every Agent.Server
  start. Never persisted; never cached across restarts.

  Fields are all required in the parser output (defaults are applied inside
  `Glorbo.Agent.Parser`): the struct itself is a simple payload carrier.
  """

  @type permission :: {String.t(), String.t(), String.t()}
  @type network_policy :: :none | :api_only | :open

  @typedoc """
  Named autonomy tier (T1-F). Maps to existing primitives the
  parser already enforces — this field is a human-readable alias
  that the scaffold + UI can offer without introducing new runtime
  behaviour.

    * `:manual` — every dispatch requires `requires_approval: director`
      on the task (director touches every wake).
    * `:supervised` — approval only required for `priority: high` or
      budget-approaching tasks; heartbeat pauses if budget alert fires.
    * `:auto` — no approval gate; audit + budget hard-stop still apply.

  Defaults to `:supervised` when not declared, preserving the pre-T1-F
  behaviour of "approval is opt-in, heartbeat runs on schedule."
  """
  @type autonomy :: :manual | :supervised | :auto

  @type t :: %__MODULE__{
          slug: String.t(),
          company: String.t(),
          role: String.t(),
          provider: String.t(),
          model: String.t(),
          permissions: [permission()],
          heartbeat: String.t() | nil,
          network: network_policy(),
          skills: [String.t()],
          budget_usd_cents_month: non_neg_integer() | nil,
          timeout_seconds: pos_integer(),
          allow_untracked_budget: boolean(),
          autonomy: autonomy(),
          reports_to: String.t() | nil,
          icon: String.t() | nil,
          file_path: String.t()
        }

  @enforce_keys [
    :slug,
    :company,
    :role,
    :provider,
    :model,
    :permissions,
    :network,
    :skills,
    :timeout_seconds,
    :file_path
  ]
  defstruct [
    :slug,
    :company,
    :role,
    :provider,
    :model,
    :permissions,
    :heartbeat,
    :network,
    :skills,
    :budget_usd_cents_month,
    :timeout_seconds,
    :file_path,
    allow_untracked_budget: false,
    autonomy: :supervised,
    reports_to: nil,
    icon: nil
  ]
end
