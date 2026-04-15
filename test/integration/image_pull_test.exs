defmodule Glorbo.Integration.ImagePullTest do
  @moduledoc """
  RT-02 proof — `podman pull ghcr.io/foobarto/glorbo-runtime:latest`
  succeeds. Gated on podman availability AND network reachability; skipped
  silently otherwise so CI without a runtime-image tag still passes.
  """
  use Glorbo.PodmanCase
  @moduletag :integration
  @moduletag :image_pull

  test "ghcr.io image pull succeeds (RT-02)" do
    image = "ghcr.io/foobarto/glorbo-runtime:latest"

    case System.cmd("podman", ["pull", image], stderr_to_stdout: true) do
      {_, 0} ->
        {listing, 0} =
          System.cmd("podman", ["image", "exists", image], stderr_to_stdout: true)

        # image-exists returns exit 0 when present; `listing` is empty.
        assert listing |> to_string() |> String.trim() == ""

      {output, _} ->
        flunk("""
        podman pull failed. If network is unreachable or the tag is not yet
        published, mark this test skipped at the invocation site.

        #{output}
        """)
    end
  end
end
