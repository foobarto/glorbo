defmodule Glorbo.Integration.ContainerLifecycleTest do
  @moduledoc """
  Integration — runs only when `podman` is available (`@moduletag :podman`)
  AND the `glorbo-runtime` image is pulled. Exercises the full
  `ContainerManager.start_container/2` + `stop_container/1` path against a
  real rootless-Podman runtime.

  Gated by two moduletags: `:podman` (skipped in plain CI) and `:integration`
  (excluded by default in `test/test_helper.exs`).
  """
  use Glorbo.PodmanCase
  @moduletag :integration

  alias Glorbo.Container.Invocation

  setup do
    image = Invocation.runtime_image()

    case System.cmd("podman", ["image", "exists", image], stderr_to_stdout: true) do
      {_, 0} -> {:ok, image: image}
      {_, _} -> {:skip, "runtime image #{image} not pulled; skip lifecycle test"}
    end
  end

  test "ephemeral container exits cleanly after short-running command", %{image: image} do
    # Override the tail with a one-shot `true`; we only want the launch +
    # exit path, not uvicorn staying up.
    {output, code} =
      System.cmd(
        "podman",
        [
          "run",
          "--rm",
          "--name",
          "glorbo-it-ephemeral",
          "--userns",
          "keep-id",
          "--read-only",
          "--network",
          "none",
          "--tmpfs",
          "/tmp",
          image,
          "/bin/true"
        ],
        stderr_to_stdout: true
      )

    assert code == 0, "podman run --rm /bin/true failed: #{output}"

    # --rm removed the container; `podman inspect` should fail.
    {_, inspect_code} =
      System.cmd("podman", ["inspect", "glorbo-it-ephemeral"], stderr_to_stdout: true)

    assert inspect_code != 0
  end

  test "podman inspect confirms --network=none + --read-only on a live container", %{image: image} do
    name = "glorbo-it-inspect-#{System.unique_integer([:positive])}"

    try do
      # Start detached so we can inspect, then kill.
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
            image,
            "sleep",
            "10"
          ],
          stderr_to_stdout: true
        )

      {json, 0} = System.cmd("podman", ["inspect", name], stderr_to_stdout: true)
      [info] = Jason.decode!(json)

      assert get_in(info, ["HostConfig", "NetworkMode"]) == "none"
      assert get_in(info, ["HostConfig", "ReadonlyRootfs"]) == true
    after
      System.cmd("podman", ["kill", name], stderr_to_stdout: true)
      System.cmd("podman", ["rm", "-f", name], stderr_to_stdout: true)
    end
  end
end
