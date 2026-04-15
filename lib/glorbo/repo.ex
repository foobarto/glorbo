defmodule Glorbo.Repo do
  use Ecto.Repo,
    otp_app: :glorbo,
    adapter: Ecto.Adapters.SQLite3
end
