defmodule Glorbo.PodmanCase do
  @moduledoc """
  ExUnit case template for tests gated on podman availability on the host.

  Tests using this module get an automatic `@moduletag :podman` plus a setup
  that skips when the `podman` binary is not in `$PATH`. CI runs with
  `mix test --exclude podman` by default; the gate runs on developer hosts
  and on CI jobs that install podman explicitly.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :podman

      setup do
        if System.find_executable("podman") do
          :ok
        else
          {:skip, "podman not installed; skip @moduletag :podman test"}
        end
      end
    end
  end
end
