defmodule Gep.Record do
  @moduledoc """
  Struct representing a parsed GEP file.

  All fields come from YAML frontmatter except `:number` (derived from
  filename) and `:body` (the markdown content after the frontmatter).
  `:gep_field` is the raw `gep:` value from frontmatter, used to compare
  against the filename number.
  """

  defstruct [
    :number,
    :gep_field,
    :filename,
    :title,
    :author,
    :status,
    :type,
    :created,
    :updated,
    :history,
    :requires,
    :supersedes,
    :superseded_by,
    :extended_by,
    :see_also,
    :implemented_in,
    :body
  ]

  @type t :: %__MODULE__{
          number: integer() | nil,
          gep_field: integer() | nil,
          filename: String.t(),
          title: String.t() | nil,
          author: String.t() | nil,
          status: String.t() | nil,
          type: String.t() | nil,
          created: String.t() | nil,
          updated: String.t() | nil,
          history: [map()] | nil,
          requires: [integer()] | nil,
          supersedes: [integer()] | nil,
          superseded_by: integer() | nil,
          extended_by: [integer()] | nil,
          see_also: [integer()] | nil,
          implemented_in: String.t() | nil,
          body: String.t() | nil
        }
end
