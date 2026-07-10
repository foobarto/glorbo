defmodule Glorbo.CompanyBoot do
  @moduledoc """
  One-shot child that enumerates `<base>/companies/*` at app start and
  spins up a `Glorbo.Company.Supervisor` for each existing company
  under `Glorbo.CompanySupervisor`.

  Without this, the dashboard (`mix phx.server`) has no per-company
  `AuditLog`, `Router`, `Gate`, etc. registered — every Director
  write-action (`post_message`, `set_approval`, `wake_agent`) times
  out a `GenServer.call` to `Glorbo.Company.AuditLog` and crashes the
  LiveView.

  Gated behind `config :glorbo, :auto_start_companies, <bool>`:

    * `true`  (default, dev/prod) — boot companies on start.
    * `false` (test)              — each test manages its own company
      supervisor via fixtures. Auto-booting would fight per-test
      isolated `TmpGlorboHome` roots.

  This is a `Task` spec (one-shot), not a GenServer — it runs its
  enumeration, starts the children, and exits. Failure to boot a
  single company is logged but not fatal (so one malformed
  `company.md` doesn't take down the dashboard).
  """
  require Logger

  alias Glorbo.Company.Supervisor, as: CompanySup
  alias Glorbo.Filesystem.Hierarchy

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :run, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @spec run(keyword()) :: {:ok, pid()}
  def run(opts \\ []) do
    Task.start_link(fn -> do_boot(opts) end)
  end

  defp do_boot(opts) do
    if Application.get_env(:glorbo, :auto_start_companies, true) do
      base = Keyword.get(opts, :base, Hierarchy.default_root())
      companies_dir = Path.join(base, "companies")

      case File.ls(companies_dir) do
        {:ok, slugs} ->
          slugs
          |> Enum.filter(fn slug ->
            Glorbo.Slug.valid?(slug) and real_directory?(Path.join(companies_dir, slug))
          end)
          |> Enum.each(&ensure_started(&1, base))

        _ ->
          :ok
      end
    end

    :ok
  end

  # Gemini round-4 finding (PR #36): `File.dir?` follows symlinks.
  # Requires the attacker to have write into the user's $HOME
  # (already-compromised host), so defense-in-depth — but mirrors
  # the pattern used in Restore.walk_all_entries / Sandbox.
  # SymlinkGuard. Use `read_link_info` so a symlink at
  # `companies/<valid-slug>` pointing at an attacker-controlled
  # tree doesn't get booted as a company.
  defp real_directory?(path) do
    case :file.read_link_info(path) do
      {:ok, info} -> elem(info, 2) == :directory
      _ -> false
    end
  end

  @doc """
  Ensure the runtime supervision tree for an on-disk company is running.

  `CompanyBoot` performs this once for companies present at application boot.
  Dashboard-created companies use this public seam so their AuditLog, Router,
  approval gate, and other runtime children become available immediately
  without requiring an application restart.

  The call is a clean no-op when automatic company startup is disabled (the
  normal unit-test configuration).
  """
  @spec ensure_started(String.t(), Path.t()) ::
          {:ok, pid() | :already_started | :disabled} | {:error, term()}
  def ensure_started(slug, base \\ Hierarchy.default_root())

  def ensure_started(slug, base)
      when is_binary(slug) and is_binary(base) do
    cond do
      not Application.get_env(:glorbo, :auto_start_companies, true) ->
        {:ok, :disabled}

      not Glorbo.Slug.valid?(slug) ->
        {:error, :invalid_company_slug}

      not real_directory?(Path.join([base, "companies", slug])) ->
        {:error, :company_not_found}

      true ->
        start_company_supervisor(slug, base)
    end
  end

  def ensure_started(_slug, _base), do: {:error, :invalid_company_slug}

  defp start_company_supervisor(slug, base) do
    spec =
      {CompanySup,
       [
         company: slug,
         base: base,
         name: {:via, Registry, {Glorbo.Agent.Registry, {:company_sup, slug}}}
       ]}

    case DynamicSupervisor.start_child(Glorbo.CompanySupervisor, spec) do
      {:ok, pid} ->
        Logger.info("Started company supervisor for #{slug}")
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        {:ok, :already_started}

      {:error, reason} ->
        Logger.warning("Failed to start company supervisor for #{slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
