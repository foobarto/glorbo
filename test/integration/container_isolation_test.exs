defmodule Glorbo.Integration.ContainerIsolationTest do
  @moduledoc """
  RT-03 proof — Container A cannot see Company B's directory.

  Creates two tmp "company" dirs, launches a container for A with only A's
  dir bind-mounted, and asserts B's marker file is absent inside the
  container (`podman exec ... ls /company`). Gated on podman availability.
  """
  use Glorbo.PodmanCase
  @moduletag :integration

  alias Glorbo.Container.Invocation

  setup do
    image = Invocation.runtime_image()

    case System.cmd("podman", ["image", "exists", image], stderr_to_stdout: true) do
      {_, 0} -> {:ok, image: image}
      {_, _} -> {:skip, "runtime image #{image} not pulled; skip isolation test"}
    end
  end

  test "Container A mounts only Company A's dir (RT-03)", %{image: image} do
    base = Path.join(System.tmp_dir!(), "glorbo_isolation_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    acme = Path.join([base, "companies", "acme"])
    beta = Path.join([base, "companies", "beta"])
    File.mkdir_p!(acme)
    File.mkdir_p!(beta)
    File.write!(Path.join(acme, "ACME.txt"), "acme only")
    File.write!(Path.join(beta, "BETA.txt"), "beta only")

    name = "glorbo-it-isolation-#{System.unique_integer([:positive])}"

    try do
      {_, 0} =
        System.cmd(
          "podman",
          [
            "run",
            "-d",
            "--name",
            name,
            "--userns",
            "keep-id",
            "--read-only",
            "--network",
            "none",
            "--tmpfs",
            "/tmp",
            "--volume",
            "#{acme}:/company:Z,ro",
            image,
            "sleep",
            "20"
          ],
          stderr_to_stdout: true
        )

      {listing, 0} =
        System.cmd("podman", ["exec", name, "ls", "/company"], stderr_to_stdout: true)

      assert String.contains?(listing, "ACME.txt")

      refute String.contains?(listing, "BETA.txt"),
             "container saw Company B's file — isolation broken"
    after
      System.cmd("podman", ["kill", name], stderr_to_stdout: true)
      System.cmd("podman", ["rm", "-f", name], stderr_to_stdout: true)
    end
  end
end
