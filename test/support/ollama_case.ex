defmodule Glorbo.OllamaCase do
  @moduledoc """
  ExUnit case template for tests gated on ollama availability on the host.

  Checks both `$PATH` and the Glorbo-managed `~/.glorbo/bin/ollama` location
  (D-04 / D-05 — Glorbo downloads here when the system binary is absent).
  Skips when neither path finds an ollama binary.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :ollama

      setup do
        managed = Path.expand("~/.glorbo/bin/ollama")

        cond do
          System.find_executable("ollama") -> :ok
          File.exists?(managed) -> :ok
          true -> {:skip, "ollama not installed; skip @moduletag :ollama test"}
        end
      end
    end
  end
end
