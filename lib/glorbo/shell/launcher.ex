defmodule Glorbo.Shell.Launcher do
  @moduledoc """
  GEP-37 Phase 2c — composes `TermUI.Runtime.run/1` inputs from the
  CLI's argv + environment.

  Phase 2c ships the Launcher as a separate module so its argv +
  environment-resolution logic is unit-testable WITHOUT calling into
  term_ui's TTY runtime. The `:runner_fn` opt is the real
  `&TermUI.Runtime.run/1` in production and a test double in
  `launcher_test.exs`.

  Argv shape (Phase 2c minimum):

      glorbo shell <company>

  `--help` / `-h` are handled upstream in `Glorbo.Shell.run/1`. A
  missing or non-slug company returns `{:error, :usage}`. A
  company directory that doesn't exist on disk returns
  `{:error, :unknown_company}`.

  Phase 3+ widens the argv surface (initial view, theme, palette
  ANSI colour mode, etc.); Phase 2c keeps it minimal so the
  end-to-end "glorbo shell acme" flow has a clean test target.
  """

  alias Glorbo.Filesystem.Hierarchy
  alias Glorbo.Shell.AppRoot

  @typedoc "Reason an argv→opts compose can fail."
  @type compose_error :: :usage | :unknown_company | {:invalid_slug, String.t()}

  @doc """
  Entry point. Returns `{:ok, exit_code, output}` on success or
  `{:error, reason}` for argv / environment problems. The runner_fn
  is invoked with the composed term_ui opts; tests pass a mock fn
  that records the inputs without booting term_ui.
  """
  @spec run([String.t()], keyword()) :: {:ok, 0 | 1, String.t()} | {:error, compose_error()}
  def run(args, opts \\ []) do
    runner_fn = Keyword.get(opts, :runner_fn, &TermUI.Runtime.run/1)
    base = Keyword.get(opts, :base, Hierarchy.default_root())

    with {:ok, company} <- parse_argv(args),
         :ok <- validate_company_dir(base, company) do
      runner_opts = build_runner_opts(base, company)
      _ = runner_fn.(runner_opts)
      {:ok, 0, ""}
    end
  end

  @doc false
  @spec parse_argv([String.t()]) :: {:ok, String.t()} | {:error, compose_error()}
  def parse_argv([company | _rest]) when is_binary(company) and company != "" do
    if Glorbo.Actions.Support.valid_slug?(company) do
      {:ok, company}
    else
      {:error, {:invalid_slug, company}}
    end
  end

  def parse_argv(_), do: {:error, :usage}

  @doc false
  @spec validate_company_dir(Path.t(), String.t()) :: :ok | {:error, :unknown_company}
  def validate_company_dir(base, company) do
    if File.dir?(Path.join([base, "companies", company])) do
      :ok
    else
      {:error, :unknown_company}
    end
  end

  @doc false
  @spec build_runner_opts(Path.t(), String.t()) :: keyword()
  def build_runner_opts(base, company) do
    # Phase 3a: AppRoot is the new root view, owning the
    # `C-c <letter>` chord prefix that switches between views.
    # AppRoot's init/1 forwards opts to its initial sub-view
    # (Inbox today; Phase 3b adds Health/Overview/etc.).
    [
      root: AppRoot,
      opts: [base: base, company: company]
    ]
  end
end
