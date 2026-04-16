defmodule Glorbo.Container.InvocationTest do
  use ExUnit.Case, async: true

  alias Glorbo.Container.Invocation

  @base "/tmp/glorbo-invocation-test"

  describe "build_argv/4 security flags (RT-04)" do
    test "ephemeral mode: argv starts with run/--rm and includes all locked flags" do
      argv = Invocation.build_argv("acme", "ceo", :ephemeral, base: @base)

      assert hd(argv) == "run"
      assert "--rm" in argv
      assert flag_pair?(argv, "--userns", "keep-id")
      assert "--read-only" in argv
      assert flag_pair?(argv, "--network", "none")
      assert flag_pair?(argv, "--tmpfs", "/tmp")
    end

    test "persistent mode replaces --rm with -d" do
      argv = Invocation.build_argv("acme", "ceo", :persistent, base: @base)

      refute "--rm" in argv
      assert "-d" in argv
    end

    test "volume mounts include company (ro) and socket (rw) bind with :Z labels" do
      argv = Invocation.build_argv("acme", "ceo", :ephemeral, base: @base)

      company_mount = "#{@base}/companies/acme:/company:Z,ro"
      socket_mount = "#{@base}/runtime/sockets/acme:/run:Z,rw"

      assert flag_pair?(argv, "--volume", company_mount)
      assert flag_pair?(argv, "--volume", socket_mount)
    end

    test "container name + runtime image + uvicorn UDS invocation present" do
      argv = Invocation.build_argv("acme", "ceo", :ephemeral, base: @base)

      assert flag_pair?(argv, "--name", "glorbo-acme-ceo")
      image = Invocation.runtime_image()
      assert image in argv

      # uvicorn launch sequence follows the runtime image at the end of argv.
      image_idx = Enum.find_index(argv, &(&1 == image))
      tail = Enum.drop(argv, image_idx + 1)

      assert tail == ["uvicorn", "worker.main:app", "--uds", "/run/agent.sock"]
    end
  end

  describe "build_argv/4 negative security assertions" do
    test "argv never carries API-key env vars (D-37)" do
      argv = Invocation.build_argv("acme", "ceo", :ephemeral, base: @base)

      refute Enum.any?(argv, &String.contains?(&1, "API_KEY"))
      refute Enum.any?(argv, &String.contains?(&1, "GLORBO_API_KEY"))
    end

    test "argv never carries --privileged / --cap-add / host networking (RT-04)" do
      argv = Invocation.build_argv("acme", "ceo", :ephemeral, base: @base)

      refute "--privileged" in argv
      refute "--cap-add" in argv
      refute flag_pair?(argv, "--network", "host")
    end

    test "argv carries the expected GLORBO_COMPANY/AGENT env but no secrets" do
      argv = Invocation.build_argv("acme", "ceo", :ephemeral, base: @base)

      assert flag_pair?(argv, "--env", "GLORBO_COMPANY=acme")
      assert flag_pair?(argv, "--env", "GLORBO_AGENT=ceo")
    end
  end

  describe "runtime_image/0" do
    test "returns the ghcr image string" do
      assert Invocation.runtime_image() =~ "ghcr.io/foobarto/glorbo-runtime"
    end
  end

  describe "build_argv/4 extra_volumes keyword (Plan 04 back-edit)" do
    test "extra_volumes appends additional --volume pairs before the image" do
      extra = ["/tmp/ollama.sock:/tmp/ollama.sock:Z,rw"]

      argv =
        Invocation.build_argv("acme", "ceo", :persistent,
          base: @base,
          extra_volumes: extra
        )

      assert flag_pair?(argv, "--volume", "/tmp/ollama.sock:/tmp/ollama.sock:Z,rw")

      image = Invocation.runtime_image()
      image_idx = Enum.find_index(argv, &(&1 == image))
      extra_idx = Enum.find_index(argv, &(&1 == "/tmp/ollama.sock:/tmp/ollama.sock:Z,rw"))

      # extra volume must appear BEFORE the image (where podman expects --volume args).
      assert extra_idx < image_idx
    end

    test "extra_volumes default is empty and does not alter original argv shape" do
      argv_no = Invocation.build_argv("acme", "ceo", :persistent, base: @base)

      argv_empty =
        Invocation.build_argv("acme", "ceo", :persistent, base: @base, extra_volumes: [])

      assert argv_no == argv_empty
    end
  end

  # Helpers ------------------------------------------------------------

  # Matches "... --flag value ..." anywhere in the argv.
  defp flag_pair?(argv, flag, value) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      [^flag, ^value] -> true
      _ -> false
    end)
  end
end
