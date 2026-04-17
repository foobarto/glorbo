# Intentionally empty.
#
# Glorbo's domain data lives on the filesystem under ~/.glorbo/companies/,
# not in the SQLite index. The index is rebuildable by `glorbo reindex`
# (GEP-7 — SQLite as derived data), so there's nothing meaningful to
# seed directly into the DB.
#
# The `glorbo init --example` CLI bootstraps a sample company on disk;
# that's the moral equivalent of seeds for this project.
#
# Kept as a no-op instead of deleted because `mix ecto.setup` (in
# mix.exs aliases) references `run priv/repo/seeds.exs` — removing the
# file would break the alias.
