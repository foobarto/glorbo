defmodule Glorbo.Doctor.TestHelpers do
  @moduledoc false

  @doc """
  Builds a keyword deps list for `Glorbo.Doctor.run_checks/1` with selectively
  faked OS functions. Any key not supplied falls through to the real default.
  """
  def deps(overrides \\ []) do
    tmp_home =
      Path.join(System.tmp_dir!(), "glorbo-doctor-home-#{System.unique_integer([:positive])}")

    Keyword.merge(
      [
        cmd_fun: &System.cmd/2,
        which_fun: &System.find_executable/1,
        home_fun: fn -> tmp_home end,
        otp_release_fun: fn ->
          :otp_release |> :erlang.system_info() |> List.to_string()
        end,
        # Phase 2 addition (D-43 ollama daemon probe). Default keeps tests
        # host-independent by returning a connection error.
        http_fun: fn -> {:error, :not_stubbed} end
      ],
      overrides
    )
  end

  @doc "Fake for System.cmd/2 returning a canned stdout/exit tuple."
  def canned_cmd(output, status \\ 0) do
    fn _cmd, _args -> {output, status} end
  end

  @doc "Fake for System.find_executable/1 returning a map lookup."
  def canned_which(lookup) do
    fn name -> Map.get(lookup, name) end
  end
end
