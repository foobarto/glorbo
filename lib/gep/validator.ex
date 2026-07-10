defmodule Gep.Validator do
  @moduledoc """
  Pure validation engine for GEP files.

  Validates frontmatter structure, cross-references, bidirectional links,
  README index consistency, and required body sections.
  """

  @valid_statuses ~w(Placeholder Draft Accepted Implemented Superseded Withdrawn Rejected)
  @valid_types ~w(Standards Informational Process)
  @date_re ~r/^\d{4}-\d{2}-\d{2}$/

  @required_fields [:gep, :title, :author, :status, :type, :created, :history]

  @section_aliases %{
    "Problem" => [
      "Problem",
      "Purpose",
      "What is a GEP?",
      "Why bother?",
      "Context",
      "The gap being named",
      "Why this shape"
    ],
    "Goals" => ["Goals", "Objectives"],
    "Non-goals" => [
      "Non-goals",
      "Non-goals",
      "Out of scope",
      "Scope",
      "What this GEP does NOT do"
    ],
    "Design" => [
      "Design",
      "High-level design",
      "Architecture",
      "The design",
      "Role",
      "On-disk layout",
      "The invariant",
      "Formats",
      "Architectural pillars",
      "Topology",
      "Runtime story",
      "Shape of the dashboard",
      "What the sandbox does NOT do",
      "bwrap as the kernel layer",
      "What SQLite holds",
      "What SQLite must NOT hold",
      "Candidate protocols",
      "Proposed shape",
      "The principle"
    ],
    "Migration" => [
      "Migration",
      "Migration / rollout",
      "Rollout",
      "Migration plan",
      "Implications for v0.0.2 and beyond"
    ],
    "Decision log" => ["Decision log", "Decision log (for this GEP)"]
  }

  @required_sections %{
    "Standards" => ["Problem", "Goals", "Non-goals", "Design", "Migration", "Decision log"],
    "Informational" => ["Problem", "Design", "Decision log"],
    "Process" => ["Problem", "Design", "Decision log"]
  }

  @doc """
  Run all validations. Returns a list of result maps with keys:
  `:severity` (`:error`, `:warning`, `:pass`), `:label`, `:detail`,
  and optionally `:gep_number`.
  """
  @spec validate_all(String.t()) :: [map()]
  def validate_all(gep_dir \\ "docs/geps") do
    readme = Path.join(gep_dir, "README.md")
    records = load_all(gep_dir)
    number_map = Map.new(records, fn r -> {r.number, r} end)

    per_gep =
      records
      |> Enum.sort_by(& &1.number)
      |> Enum.flat_map(fn r -> validate_record(r, number_map) end)

    global =
      [
        check_sequential(records),
        check_bidirectional(records, number_map),
        check_cross_references(records, number_map),
        check_readme_index(records, readme)
      ]
      |> List.flatten()

    per_gep ++ global
  end

  # ---------------------------------------------------------------------------
  # Loading
  # ---------------------------------------------------------------------------

  defp load_all(gep_dir) do
    gep_dir
    |> File.ls!()
    |> Enum.filter(&String.match?(&1, ~r/^\d{4}-.*\.md$/))
    |> Enum.reject(&(&1 == "0000-template.md"))
    |> Enum.map(fn filename ->
      path = Path.join(gep_dir, filename)
      parse_file(path, filename)
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp parse_file(path, filename) do
    content = File.read!(path)

    case YamlFrontMatter.parse(content) do
      {:ok, metadata, body} ->
        number = extract_number(filename)
        gep_field = normalize_int(metadata["gep"])

        %Gep.Record{
          number: number,
          gep_field: gep_field,
          filename: filename,
          title: to_string(metadata["title"]),
          author: to_string(metadata["author"]),
          status: metadata["status"],
          type: metadata["type"],
          created: metadata["created"],
          updated: metadata["updated"],
          history: metadata["history"] || [],
          requires: normalize_int_list(metadata["requires"]),
          supersedes: normalize_int_list(metadata["supersedes"]),
          superseded_by: normalize_int(metadata["superseded-by"]),
          extended_by: normalize_int_list(metadata["extended-by"]),
          see_also: normalize_int_list(metadata["see-also"]),
          implemented_in: metadata["implemented-in"],
          body: body
        }

      {:error, _} ->
        nil
    end
  end

  defp extract_number(filename) do
    case Regex.run(~r/^(\d{4})/, filename) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  defp normalize_int_list(nil), do: nil
  defp normalize_int_list([]), do: nil
  defp normalize_int_list(list) when is_list(list), do: Enum.map(list, &to_integer/1)
  defp normalize_int_list(_), do: nil

  defp normalize_int(nil), do: nil
  defp normalize_int(v), do: to_integer(v)

  defp to_integer(v) when is_integer(v), do: v

  defp to_integer(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {integer, ""} -> integer
      _ -> v
    end
  end

  defp to_integer(v), do: v

  # ---------------------------------------------------------------------------
  # Per-record validations
  # ---------------------------------------------------------------------------

  defp validate_record(record, number_map) do
    [
      check_required_fields(record),
      check_enum_values(record),
      check_filename_match(record),
      check_status_history_consistency(record),
      check_history_entries(record),
      check_cross_references_for_record(record, number_map),
      check_superseded_status(record),
      check_required_sections(record)
    ]
    |> List.flatten()
  end

  defp check_required_fields(record) do
    @required_fields
    |> Enum.reject(fn
      :gep -> record.gep_field != nil
      :history -> record.history != nil && record.history != []
      field -> Map.get(record, field) not in [nil, ""]
    end)
    |> Enum.map(fn field ->
      %{
        severity: :error,
        label: "Required fields",
        detail: "Missing required field: #{field}",
        gep_number: record.number
      }
    end)
    |> case do
      [] -> [%{severity: :pass, label: "Required fields", detail: "", gep_number: record.number}]
      errors -> errors
    end
  end

  defp check_enum_values(record) do
    results = []

    results =
      if record.status != nil and record.status not in @valid_statuses do
        results ++
          [
            %{
              severity: :error,
              label: "Status enum",
              detail:
                "Invalid status '#{record.status}'. Must be one of: #{Enum.join(@valid_statuses, ", ")}",
              gep_number: record.number
            }
          ]
      else
        results
      end

    results =
      if record.type != nil and record.type not in @valid_types do
        results ++
          [
            %{
              severity: :error,
              label: "Type enum",
              detail:
                "Invalid type '#{record.type}'. Must be one of: #{Enum.join(@valid_types, ", ")}",
              gep_number: record.number
            }
          ]
      else
        results
      end

    case results do
      [] -> [%{severity: :pass, label: "Enum values", detail: "", gep_number: record.number}]
      _ -> results
    end
  end

  defp check_filename_match(record) do
    filename_num = record.number
    gep_field = record.gep_field

    if gep_field != nil and filename_num != nil and filename_num == gep_field do
      [%{severity: :pass, label: "Filename match", detail: "", gep_number: record.number}]
    else
      [
        %{
          severity: :error,
          label: "Filename match",
          detail: "Filename says #{filename_num}, frontmatter says gep: #{gep_field}",
          gep_number: record.number
        }
      ]
    end
  end

  defp check_status_history_consistency(record) do
    last_history = List.last(record.history || [])

    if last_history == nil do
      [
        %{
          severity: :error,
          label: "Status/history consistency",
          detail: "No history entries",
          gep_number: record.number
        }
      ]
    else
      history_status = last_history["status"]

      if history_status == record.status do
        [
          %{
            severity: :pass,
            label: "Status/history consistency",
            detail: "",
            gep_number: record.number
          }
        ]
      else
        [
          %{
            severity: :error,
            label: "Status/history consistency",
            detail:
              "Top-level status says \"#{record.status}\", last history entry says \"#{history_status}\"",
            gep_number: record.number
          }
        ]
      end
    end
  end

  defp check_history_entries(record) do
    errors =
      record.history
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {entry, idx} ->
        entry_errors = []

        entry_errors =
          if entry["date"] == nil or entry["date"] == "" do
            entry_errors ++
              [%{severity: :error, idx: idx, detail: "history[#{idx}] missing date"}]
          else
            if Regex.match?(@date_re, to_string(entry["date"])) do
              entry_errors
            else
              entry_errors ++
                [
                  %{
                    severity: :error,
                    idx: idx,
                    detail: "history[#{idx}] invalid date format: #{entry["date"]}"
                  }
                ]
            end
          end

        entry_errors =
          if entry["status"] == nil or entry["status"] == "" do
            entry_errors ++
              [%{severity: :error, idx: idx, detail: "history[#{idx}] missing status"}]
          else
            entry_errors
          end

        entry_errors
      end)

    case errors do
      [] ->
        [%{severity: :pass, label: "History entries", detail: "", gep_number: record.number}]

      errs ->
        Enum.map(errs, fn e ->
          %{
            severity: e.severity,
            label: "History entries",
            detail: e.detail,
            gep_number: record.number
          }
        end)
    end
  end

  defp check_cross_references_for_record(record, number_map) do
    refs = [
      {"requires", record.requires},
      {"supersedes", record.supersedes},
      {"see-also", record.see_also},
      {"extended-by", record.extended_by}
    ]

    errors =
      refs
      |> Enum.flat_map(fn {field_name, refs_list} ->
        (refs_list || [])
        |> Enum.reject(fn ref -> Map.has_key?(number_map, ref) end)
        |> Enum.map(fn ref ->
          %{
            severity: :error,
            label: "Cross-references",
            detail:
              "#{field_name} references GEP-#{String.pad_leading("#{ref}", 4, "0")} which does not exist",
            gep_number: record.number
          }
        end)
      end)

    case errors do
      [] -> [%{severity: :pass, label: "Cross-references", detail: "", gep_number: record.number}]
      _ -> errors
    end
  end

  defp check_superseded_status(record) do
    if record.superseded_by != nil do
      if record.status == "Superseded" do
        [%{severity: :pass, label: "Superseded status", detail: "", gep_number: record.number}]
      else
        [
          %{
            severity: :error,
            label: "Superseded status",
            detail:
              "Has superseded-by: #{record.superseded_by} but status is \"#{record.status}\", expected \"Superseded\"",
            gep_number: record.number
          }
        ]
      end
    else
      []
    end
  end

  defp check_required_sections(record) do
    # Only validate sections for Standards GEPs that are actively being written
    # toward acceptance (status == Draft). Placeholders are intentional parking
    # spots per GEP-1 and must graduate before being held to the full template.
    # Accepted / Implemented / Superseded / Withdrawn / Rejected GEPs have
    # frozen structure and are append-only (or archival). Informational /
    # Process GEPs are descriptive by nature and don't follow the Standards
    # template.
    if record.type != "Standards" or
         record.status in ~w(Placeholder Accepted Implemented Superseded Withdrawn Rejected) do
      []
    else
      sections = @required_sections[record.type] || []

      missing =
        sections
        |> Enum.reject(fn section ->
          section_matches?(record.body || "", section)
        end)

      case missing do
        [] ->
          [%{severity: :pass, label: "Required sections", detail: "", gep_number: record.number}]

        _ ->
          [
            %{
              severity: :error,
              label: "Required sections",
              detail: "Missing required sections for #{record.type}: #{Enum.join(missing, ", ")}",
              gep_number: record.number
            }
          ]
      end
    end
  end

  defp section_matches?(body, section_name) do
    aliases = @section_aliases[section_name] || [section_name]

    Enum.any?(aliases, fn alias_name ->
      # Match both "## Problem" and "## 1. Problem" and "## 3. Non-goals (for this spec)"
      pattern =
        Regex.compile!(
          "^##\\s+(?:\\d+\\.\\s*)?#{Regex.escape(alias_name)}",
          [:caseless, :multiline]
        )

      Regex.match?(pattern, body)
    end)
  end

  # ---------------------------------------------------------------------------
  # Global validations
  # ---------------------------------------------------------------------------

  defp check_sequential(records) do
    numbers = records |> Enum.map(& &1.number) |> Enum.sort()

    if numbers == [] do
      [%{severity: :pass, label: "Numbering", detail: "No GEP files found"}]
    else
      min_n = List.first(numbers)
      max_n = List.last(numbers)
      expected = Enum.to_list(min_n..max_n)
      missing = expected -- numbers

      case missing do
        [] ->
          [%{severity: :pass, label: "Numbering", detail: "Sequential, no gaps"}]

        _ ->
          labels = Enum.map(missing, fn n -> "GEP-#{String.pad_leading("#{n}", 4, "0")}" end)

          [
            %{
              severity: :warning,
              label: "Numbering",
              detail: "Gap(s) in numbering: #{Enum.join(labels, ", ")}"
            }
          ]
      end
    end
  end

  defp check_bidirectional(records, number_map) do
    errors =
      records
      |> Enum.flat_map(fn record ->
        acc = []

        # supersedes → superseded-by
        acc =
          (record.supersedes || [])
          |> Enum.reduce(acc, fn ref_n, acc ->
            check_superseded_by(acc, record, number_map[ref_n], ref_n)
          end)

        # extended-by → see-also or requires on target
        acc =
          (record.extended_by || [])
          |> Enum.reduce(acc, fn ref_n, acc ->
            check_back_ref(acc, record, number_map[ref_n], ref_n)
          end)

        acc
      end)

    case errors do
      [] -> [%{severity: :pass, label: "Bidirectional links", detail: "All consistent"}]
      _ -> errors
    end
  end

  defp check_superseded_by(acc, _record, nil, _ref_n), do: acc

  defp check_superseded_by(acc, record, ref, ref_n) do
    if ref.superseded_by == record.number do
      acc
    else
      acc ++
        [
          %{
            severity: :error,
            label: "Bidirectional links",
            detail:
              "GEP-#{gep_label(record.number)} supersedes GEP-#{gep_label(ref_n)} but GEP-#{gep_label(ref_n)} has no superseded-by: #{record.number}",
            gep_number: record.number
          }
        ]
    end
  end

  defp check_back_ref(acc, _record, nil, _ref_n), do: acc

  defp check_back_ref(acc, record, ref, ref_n) do
    back_refs = (ref.see_also || []) ++ (ref.requires || []) ++ (ref.extended_by || [])

    if record.number in back_refs do
      acc
    else
      acc ++
        [
          %{
            severity: :error,
            label: "Bidirectional links",
            detail:
              "GEP-#{gep_label(record.number)} extended-by GEP-#{gep_label(ref_n)} but GEP-#{gep_label(ref_n)} does not reference back",
            gep_number: record.number
          }
        ]
    end
  end

  defp check_cross_references(records, number_map) do
    all_refs =
      records
      |> Enum.flat_map(fn r ->
        [
          {"requires", r.requires},
          {"supersedes", r.supersedes},
          {"see-also", r.see_also},
          {"extended-by", r.extended_by}
        ]
        |> Enum.flat_map(fn {field, refs} ->
          (refs || [])
          |> Enum.map(fn ref -> {r.number, field, ref} end)
        end)
      end)

    broken =
      all_refs
      |> Enum.reject(fn {_from, _field, ref} -> Map.has_key?(number_map, ref) end)
      |> Enum.map(fn {from, field, ref} ->
        %{
          severity: :error,
          label: "Cross-references",
          detail:
            "GEP-#{gep_label(from)} #{field} references GEP-#{gep_label(ref)} which does not exist"
        }
      end)

    case broken do
      [] -> [%{severity: :pass, label: "Cross-references", detail: "All resolve"}]
      _ -> broken
    end
  end

  defp check_readme_index(records, readme_path) do
    if File.exists?(readme_path) do
      content = File.read!(readme_path)

      index_entries = parse_readme_index(content)

      file_entries =
        records
        |> Enum.sort_by(& &1.number)
        |> Enum.map(fn r ->
          %{
            number: r.number,
            title: r.title,
            type: r.type,
            status: r.status,
            filename: r.filename
          }
        end)

      errors = []

      # Check every file has an index entry
      missing_from_index =
        file_entries
        |> Enum.reject(fn fe ->
          Enum.any?(index_entries, fn ie -> ie.number == fe.number end)
        end)

      errors =
        errors ++
          Enum.map(missing_from_index, fn fe ->
            %{
              severity: :error,
              label: "README index",
              detail: "GEP-#{gep_label(fe.number)} exists but is not in README index"
            }
          end)

      # Check every index entry has a file
      missing_files =
        index_entries
        |> Enum.reject(fn ie ->
          Enum.any?(file_entries, fn fe -> fe.number == ie.number end)
        end)

      errors =
        errors ++
          Enum.map(missing_files, fn ie ->
            %{
              severity: :error,
              label: "README index",
              detail: "README index lists GEP-#{gep_label(ie.number)} but no file exists"
            }
          end)

      # Check status match
      status_mismatches =
        file_entries
        |> Enum.map(fn fe ->
          ie = Enum.find(index_entries, fn x -> x.number == fe.number end)

          if ie != nil and ie.status != fe.status do
            %{
              severity: :error,
              label: "README index",
              detail:
                "GEP-#{gep_label(fe.number)}: README says \"#{ie.status}\", file says \"#{fe.status}\""
            }
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      errors = errors ++ status_mismatches

      case errors do
        [] -> [%{severity: :pass, label: "README index", detail: "All entries valid"}]
        _ -> errors
      end
    else
      [
        %{
          severity: :error,
          label: "README index",
          detail: "README.md not found at #{readme_path}"
        }
      ]
    end
  end

  defp parse_readme_index(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^\|\s*\d{4}\s*\|/))
    |> Enum.map(fn line ->
      parts = line |> String.trim() |> String.split("|") |> Enum.map(&String.trim/1)

      case parts do
        ["", number, title_link, type, status, ""] ->
          n = String.to_integer(number)

          status_clean =
            status
            |> String.replace(~r/\*+/, "")
            |> String.trim()

          %{number: n, title: title_link, type: type, status: status_clean}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp gep_label(n), do: String.pad_leading("#{n}", 4, "0")
end
