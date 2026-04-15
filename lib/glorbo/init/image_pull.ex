defmodule Glorbo.Init.ImagePull do
  @moduledoc """
  Step 4 of the init pipeline: `podman pull ghcr.io/foobarto/glorbo-runtime`
  with D-17 cached-fallback behaviour.

  If `--skip-pull` is set → `%{status: :skipped, detail: "--skip-pull"}`.
  Otherwise delegate to `Glorbo.ContainerManager.ensure_image/1`:

    * `:ok`                             → `:ok`
    * `{:error, _}` AND image cached    → `:skipped` with "using cached image"
    * `{:error, _}` AND no cache        → `:error` with a clear "requires
      network for first pull" message (D-17 warn-and-continue)
  """

  alias Glorbo.Container.Invocation
  alias Glorbo.ContainerManager

  @type step_status :: :ok | :skipped | :error
  @type step_result :: %{status: step_status(), detail: String.t()}

  @spec run(keyword()) :: step_result()
  def run(opts \\ []) do
    image = Keyword.get(opts, :image, Invocation.runtime_image())
    ensure_fun = Keyword.get(opts, :ensure_image_fun, &ContainerManager.ensure_image/1)
    cached_fun = Keyword.get(opts, :image_cached_fun, &image_cached?/1)

    cond do
      Keyword.get(opts, :skip_pull, false) ->
        %{status: :skipped, detail: "--skip-pull"}

      true ->
        case ensure_fun.(image) do
          :ok ->
            %{status: :ok, detail: "image ready: #{image}"}

          {:error, _} = err ->
            if cached_fun.(image) do
              %{status: :skipped, detail: "using cached image: #{image}"}
            else
              %{
                status: :error,
                detail:
                  "LLM execution requires network for first pull (#{inspect(err)})"
              }
            end
        end
    end
  end

  defp image_cached?(image) do
    case System.cmd("podman", ["image", "exists", image], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
