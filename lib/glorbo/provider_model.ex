defmodule Glorbo.ProviderModel do
  @moduledoc """
  SQLite projection of cached native-provider model catalogs.

  Rows are rebuilt from `~/.glorbo/cache/providers/*.json` by
  `Glorbo.Providers.ModelCatalog` and `glorbo reindex`; nothing here is
  authoritative beyond the cache files on disk.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "provider_models" do
    field :alias, :string
    field :model_id, :string
    field :context_window, :integer
    field :family, :string
    field :raw_json, :string
    field :refreshed_at, :utc_datetime
  end
end
