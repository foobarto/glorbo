defmodule Glorbo.CLI.Registry.Provider do
  @moduledoc """
  Provider entry in the CLI registry (GEP-8 §6).

  A Provider bundles everything the Dispatcher needs to invoke a CLI
  tool: invocation shape, env overrides, reply contract, version-probe
  config, and an optional usage-parser binding.

  Two populations exist:

    * **`:builtin`** — loaded from `priv/providers/*.toml` (shipped in the
      release). `allow_version_probe` defaults to `true`.
    * **`:user`** — loaded from `~/.glorbo/providers.toml` (local-only).
      `allow_version_probe` defaults to `false` (GEP-8 D13) — running
      `<arbitrary-user-binary> --version` without explicit opt-in would
      execute untrusted code on the host.

  The `source` field is computed by the Loader from the file the entry
  came from; it is never a TOML field.

  Runtime-only fields (`installed?`, `resolved_path`, `version`,
  `probe_error`) are filled in by `Glorbo.CLI.Registry.Detection` after
  load. Before detection runs, they carry their default (`false`,
  `nil`, `nil`, `nil`).
  """

  @prompt_modes ~w(stdin stdin_dash argv tmpfile_argv acp)a
  @kinds ~w(cli native)a
  @auth_modes ~w(none bearer api_key)a
  @model_list_shapes ~w(openai ollama static none)a

  @type prompt_mode :: :stdin | :stdin_dash | :argv | :tmpfile_argv | :acp
  @type kind :: :cli | :native
  @type auth_mode :: :none | :bearer | :api_key
  @type model_list_shape :: :openai | :ollama | :static | :none
  @type source :: :builtin | :user

  @type usage_path_spec :: %{
          kind: :jsonl_latest_in_dir | :jsonl_file | :json_file | :stdout,
          path: String.t() | nil
        }

  @type path_transform :: %{
          name: String.t(),
          from: String.t(),
          transform: String.t()
        }

  @type auth_bind :: %{
          required(:host) => String.t(),
          required(:sandbox) => String.t(),
          required(:mode) => :ro | :rw
        }

  @type model_list :: %{
          required(:shape) => model_list_shape(),
          required(:path) => String.t() | nil,
          optional(:models) => [String.t()]
        }

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          binary: String.t() | nil,
          args: [String.t()],
          prompt_mode: prompt_mode(),
          env: %{optional(String.t()) => String.t()},
          reply_dir: String.t() | nil,
          reply_filename_template: String.t() | nil,
          reply_max_bytes: pos_integer(),
          phase_timeout_ms: pos_integer() | nil,
          endpoint: String.t() | nil,
          auth: auth_mode() | nil,
          model_list: model_list() | nil,
          version_flag: String.t(),
          version_regex: String.t() | nil,
          allow_version_probe: boolean(),
          usage_parser: String.t(),
          usage_path: usage_path_spec() | nil,
          path_transforms: [path_transform()],
          auth_binds: [auth_bind()],
          fallback_paths: [String.t()],
          source: source(),
          source_file: String.t(),
          installed?: boolean(),
          resolved_path: String.t() | nil,
          version: String.t() | nil,
          probe_error: term() | nil
        }

  @enforce_keys [
    :name,
    :source,
    :source_file
  ]

  defstruct [
    :name,
    :endpoint,
    :auth,
    :model_list,
    :binary,
    :reply_dir,
    :reply_filename_template,
    :version_regex,
    :usage_path,
    :source,
    :source_file,
    :resolved_path,
    :version,
    :probe_error,
    kind: :cli,
    prompt_mode: :stdin,
    args: [],
    env: %{},
    reply_max_bytes: 1_048_576,
    phase_timeout_ms: nil,
    version_flag: "",
    allow_version_probe: false,
    usage_parser: "none",
    path_transforms: [],
    auth_binds: [],
    fallback_paths: [],
    installed?: false
  ]

  @doc """
  Enumerates the accepted `prompt_mode` values. Used by the Loader to
  validate TOML entries.
  """
  @spec prompt_modes() :: [prompt_mode()]
  def prompt_modes, do: @prompt_modes

  @doc """
  Enumerates the accepted provider kinds.
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Enumerates the accepted native auth modes.
  """
  @spec auth_modes() :: [auth_mode()]
  def auth_modes, do: @auth_modes

  @doc """
  Enumerates the accepted native model-list shapes.
  """
  @spec model_list_shapes() :: [model_list_shape()]
  def model_list_shapes, do: @model_list_shapes

  @doc """
  Derived status for UI classification (GEP-8 §8).

    * `:routable` — installed? and (`usage_parser != "none"` or agent
      opted in via `allow_untracked_budget`; the opt-in check happens
      at dispatch, not here).
    * `:installed_untracked` — installed? but `usage_parser == "none"`.
      Routable only for agents with `allow_untracked_budget: true`.
    * `:not_installed` — provider unavailable at runtime.
  """
  @spec status(t()) :: :routable | :installed_untracked | :not_installed
  def status(%__MODULE__{installed?: false}), do: :not_installed
  def status(%__MODULE__{usage_parser: "none"}), do: :installed_untracked
  def status(%__MODULE__{}), do: :routable
end
