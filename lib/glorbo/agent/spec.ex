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
    :file_path
  ]
end
