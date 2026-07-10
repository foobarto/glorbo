defmodule Glorbo.Security.Capability do
  @moduledoc """
  Closed registry for agent permission capabilities.

  A permission is valid only when its `{resource, action}` pair appears in
  this module. Each valid capability is classified as either:

    * `:mount` — it grants direct filesystem visibility and therefore must
      have a Bubblewrap mapping; or
    * `:router` — the agent writes to its own outbox and the Router performs
      the privileged mutation after checking the permission.

  Keeping this registry closed prevents a misspelled or obsolete action from
  being accepted and then silently turning into an empty sandbox policy.
  """

  @type permission :: {resource :: String.t(), action :: String.t(), scope :: String.t()}
  @type enforcement :: :mount | :router
  @type scope_rule :: :any | :agent | :wildcard_only

  @capabilities %{
    {"projects", "read"} => {:mount, :any},
    {"projects", "write"} => {:mount, :any},
    {"chat", "read"} => {:mount, :any},
    {"chat", "write"} => {:router, :any},
    {"agents", "message"} => {:router, :agent},
    {"tasks", "create"} => {:router, :any},
    {"tasks", "read"} => {:mount, :any},
    {"tasks", "update"} => {:mount, :any},
    {"proposals", "read"} => {:mount, :wildcard_only},
    {"proposals", "propose"} => {:router, :wildcard_only},
    {"proposals", "decide"} => {:router, :wildcard_only}
  }

  @resources @capabilities |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  @unsupported MapSet.new([{"agents", "create"}, {"agents", "list"}, {"tasks", "write"}])

  @doc "Validate and classify a parsed permission tuple."
  @spec validate(permission()) ::
          {:ok, enforcement()}
          | {:error, :invalid_scope | :not_implemented | :unknown_action | :unknown_resource}
  def validate({resource, action, scope})
      when is_binary(resource) and is_binary(action) and is_binary(scope) do
    case Map.fetch(@capabilities, {resource, action}) do
      {:ok, {enforcement, scope_rule}} ->
        if valid_scope?(scope, scope_rule) do
          {:ok, enforcement}
        else
          {:error, :invalid_scope}
        end

      :error ->
        cond do
          resource not in @resources -> {:error, :unknown_resource}
          MapSet.member?(@unsupported, {resource, action}) -> {:error, :not_implemented}
          true -> {:error, :unknown_action}
        end
    end
  end

  @doc "Return the enforcement class for a valid permission."
  @spec enforcement(permission()) ::
          {:ok, enforcement()}
          | {:error, :invalid_scope | :not_implemented | :unknown_action | :unknown_resource}
  def enforcement(permission), do: validate(permission)

  @doc "Return all registered `{resource, action}` capability families."
  @spec families() :: [{String.t(), String.t()}]
  def families, do: @capabilities |> Map.keys() |> Enum.sort()

  defp valid_scope?("*", _rule), do: true
  defp valid_scope?(_scope, :wildcard_only), do: false
  defp valid_scope?(scope, :agent), do: Glorbo.Slug.valid?(scope, :agent)
  defp valid_scope?(scope, :any), do: Glorbo.Slug.valid?(scope)
end
