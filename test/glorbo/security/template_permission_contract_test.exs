defmodule Glorbo.Security.TemplatePermissionContractTest do
  use ExUnit.Case, async: true

  alias Glorbo.Security.ACLMapper

  @agent_templates Path.wildcard("priv/templates/agents/*.md") ++
                     Path.wildcard("priv/templates/companies/*/agents/*/AGENT.md")

  test "every permission declared by a shipped agent template is registered" do
    failures =
      for path <- @agent_templates,
          permission <- template_permissions(path),
          not match?({:ok, _}, ACLMapper.parse_permission(permission)) do
        {path, permission, ACLMapper.parse_permission(permission)}
      end

    assert failures == []
  end

  defp template_permissions(path) do
    path
    |> File.read!()
    |> String.replace("{{ reports_to }}", "ceo")
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "permissions:"))
    |> Enum.drop(1)
    |> Enum.take_while(&String.match?(&1, ~r/^\s+-\s+/))
    |> Enum.map(fn line -> line |> String.trim() |> String.trim_leading("- ") end)
  end
end
