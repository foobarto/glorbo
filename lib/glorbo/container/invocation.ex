defmodule Glorbo.Container.Invocation do
  @moduledoc """
  Builds the `podman run` argv list per RT-04.

  Pure — no IO, no side effects. The caller passes the result to
  `System.cmd("podman", argv, ...)` or `MuonTrap.Daemon.start_link`. Every
  security flag is non-negotiable and asserted by `invocation_test.exs` via
  positive AND negative assertions:

    * positive: `--userns keep-id`, `--read-only`, `--network none`,
      `--tmpfs /tmp`, `:Z` SELinux label on both bind mounts.
    * negative: no `--privileged`, no `--cap-add`, no `--network host`,
      no secret-bearing env vars anywhere in the argv (D-37 bans injecting
      provider keys as container env; they live in request bodies only).

  See DESIGN.md §4.4 for the canonical invocation this argv must satisfy.
  """

  @runtime_image_default "ghcr.io/foobarto/glorbo-runtime:v0.1.0"

  @type mode :: :ephemeral | :persistent

  @doc """
  Build the argv list for `podman run` + uvicorn entrypoint.

  Options:

    * `:base` — the Glorbo home root (default `~/.glorbo`). Used as the
      prefix for both the company bind-mount and the socket directory.
    * `:image` — override the runtime image string (default
      `#{@runtime_image_default}`). Only intended for tests.
    * `:extra_volumes` — list of `"host:container:flags"` strings appended
      as additional `--volume` pairs (Plan 04 back-edit). The only current
      use is bind-mounting `/tmp/ollama.sock` for airplane-mode inference
      (LLM-05). Default: `[]`.

  Modes:

    * `:ephemeral` — `--rm`. One-shot task; container removed on exit (RT-05).
    * `:persistent` — `-d`. FastAPI worker stays up for multiple /run calls
      (D-13).
  """
  @spec build_argv(String.t(), String.t(), mode(), keyword()) :: [String.t()]
  def build_argv(company, agent, mode \\ :ephemeral, opts \\ []) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    image = Keyword.get(opts, :image, @runtime_image_default)
    extra_volumes = Keyword.get(opts, :extra_volumes, [])
    host_company_dir = Path.join([base, "companies", company])
    host_socket_dir = Path.join([base, "runtime", "sockets", company])

    lifecycle_flag = if mode == :ephemeral, do: "--rm", else: "-d"

    extra_volume_args =
      extra_volumes
      |> Enum.flat_map(fn spec -> ["--volume", spec] end)

    base_argv = [
      "run",
      lifecycle_flag,
      "--name",
      "glorbo-#{company}-#{agent}",
      "--userns",
      "keep-id",
      "--read-only",
      "--network",
      "none",
      "--tmpfs",
      "/tmp",
      "--volume",
      "#{host_company_dir}:/company:Z,ro",
      "--volume",
      "#{host_socket_dir}:/run:Z,rw"
    ]

    tail = [
      "--env",
      "GLORBO_COMPANY=#{company}",
      "--env",
      "GLORBO_AGENT=#{agent}",
      image,
      "uvicorn",
      "worker.main:app",
      "--uds",
      "/run/agent.sock"
    ]

    base_argv ++ extra_volume_args ++ tail
  end

  @doc "The runtime image string this plan pins."
  @spec runtime_image() :: String.t()
  def runtime_image, do: @runtime_image_default
end
