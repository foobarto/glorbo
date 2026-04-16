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
    # WR-08: enforce pairing — swapping out `ensure_image_fun` for a fake
    # without also providing an `image_cached_fun` would silently hit real
    # podman during a "hermetic" test. Require both or neither.
    cond do
      Keyword.has_key?(opts, :ensure_image_fun) and
          not Keyword.has_key?(opts, :image_cached_fun) ->
        raise ArgumentError,
              "ensure_image_fun: must be paired with image_cached_fun: for hermetic tests"

      Keyword.has_key?(opts, :image_cached_fun) and
          not Keyword.has_key?(opts, :ensure_image_fun) ->
        raise ArgumentError,
              "image_cached_fun: must be paired with ensure_image_fun: for hermetic tests"

      Keyword.get(opts, :skip_pull, false) ->
        %{status: :skipped, detail: "--skip-pull"}

      true ->
        do_pull(opts)
    end
  end

  defp do_pull(opts) do
    image = Keyword.get(opts, :image, Invocation.runtime_image())
    ensure_fun = Keyword.get(opts, :ensure_image_fun, &ContainerManager.ensure_image/1)
    cached_fun = Keyword.get(opts, :image_cached_fun, &image_cached?/1)

    case ensure_fun.(image) do
      :ok -> %{status: :ok, detail: "image ready: #{image}"}
      {:error, _} = err -> fallback_or_error(image, cached_fun, err)
    end
  end

  defp fallback_or_error(image, cached_fun, err) do
    if cached_fun.(image) do
      %{status: :skipped, detail: "using cached image: #{image}"}
    else
      %{
        status: :error,
        detail: "LLM execution requires network for first pull (#{inspect(err)})"
      }
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
