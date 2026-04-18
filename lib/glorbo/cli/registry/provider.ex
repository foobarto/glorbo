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

  @prompt_modes ~w(stdin stdin_dash argv tmpfile_argv)a

  @type prompt_mode :: :stdin | :stdin_dash | :argv | :tmpfile_argv
  @type source :: :builtin | :user

  @type usage_path_spec :: %{
          kind: :jsonl_latest_in_dir | :jsonl_file | :stdout,
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

  @type t :: %__MODULE__{
          name: String.t(),
          binary: String.t(),
          args: [String.t()],
          prompt_mode: prompt_mode(),
          env: %{optional(String.t()) => String.t()},
          reply_dir: String.t(),
          reply_filename_template: String.t(),
          reply_max_bytes: pos_integer(),
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
    :binary,
    :args,
    :reply_dir,
    :reply_filename_template,
    :source,
    :source_file
  ]

  defstruct [
    :name,
    :binary,
    :args,
    :reply_dir,
    :reply_filename_template,
    :version_regex,
    :usage_path,
    :source,
    :source_file,
    :resolved_path,
    :version,
    :probe_error,
    prompt_mode: :stdin,
    env: %{},
    reply_max_bytes: 1_048_576,
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
  Derived status for UI classification (GEP-8 §8).

    * `:routable` — installed? and (`usage_parser != "none"` or agent
      opted in via `allow_untracked_budget`; the opt-in check happens
      at dispatch, not here).
    * `:installed_untracked` — installed? but `usage_parser == "none"`.
      Routable only for agents with `allow_untracked_budget: true`.
    * `:not_installed` — binary missing on PATH.
  """
  @spec status(t()) :: :routable | :installed_untracked | :not_installed
  def status(%__MODULE__{installed?: false}), do: :not_installed
  def status(%__MODULE__{usage_parser: "none"}), do: :installed_untracked
  def status(%__MODULE__{}), do: :routable
end
