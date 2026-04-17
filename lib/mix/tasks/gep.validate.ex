defmodule Mix.Tasks.Gep.Validate do
  @moduledoc """
  Validates GEP files for frontmatter structure, cross-references,
  bidirectional links, README index consistency, and required body sections.

  ## Usage

      mix gep.validate

  Exit code `0` when all checks pass; `1` when any errors are found.
  Warnings do not cause a non-zero exit.
  """
  @shortdoc "Validate GEP frontmatter, links, and structure"

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    gep_dir = "docs/geps"
    records = load_records(gep_dir)
    results = Gep.Validator.validate_all(gep_dir)
    Gep.Formatter.format(records, results)
  end

  defp load_records(gep_dir) do
    gep_dir
    |> File.ls!()
    |> Enum.filter(&String.match?(&1, ~r/^\d{4}-.*\.md$/))
    |> Enum.reject(&(&1 == "0000-template.md"))
    |> Enum.map(fn filename ->
      path = Path.join(gep_dir, filename)
      content = File.read!(path)

      case YamlFrontMatter.parse(content) do
        {:ok, metadata, _body} ->
          number =
            case Regex.run(~r/^(\d{4})/, filename) do
              [_, digits] -> String.to_integer(digits)
              _ -> nil
            end

          %Gep.Record{
            number: number,
            filename: filename,
            title: to_string(metadata["title"]),
            status: metadata["status"],
            type: metadata["type"]
          }

        _ ->
          %Gep.Record{
            number: nil,
            filename: filename,
            title: "(unparseable)",
            status: nil,
            type: nil
          }
      end
    end)
  end
end
