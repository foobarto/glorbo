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
            GlorboWeb.Slug.valid?(slug) and File.dir?(Path.join(companies_dir, slug))
          end)
          |> Enum.each(&start_company(&1, base))

        _ ->
          :ok
      end
    end

    :ok
  end

  defp start_company(slug, base) do
    spec =
      {CompanySup,
       [
         company: slug,
         base: base,
         name: {:via, Registry, {Glorbo.Agent.Registry, {:company_sup, slug}}}
       ]}

    case DynamicSupervisor.start_child(Glorbo.CompanySupervisor, spec) do
      {:ok, _pid} ->
        Logger.info("Started company supervisor for #{slug}")

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to start company supervisor for #{slug}: #{inspect(reason)}")
    end
  end
end
