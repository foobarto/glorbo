defmodule Glorbo.Util.UTF8 do
  @moduledoc """
  UTF-8 helpers for places where Glorbo bounds attacker-influenced
  strings before they reach a sink that requires valid UTF-8 (most
  notably `Jason.encode!`, which raises on invalid byte sequences).

  ## Why this exists

  The naive `binary_part(s, 0, max)` truncation by raw bytes can split
  a multi-byte UTF-8 codepoint right in the middle, producing an
  invalid binary. When that invalid binary then reaches the audit
  writer (`Glorbo.Company.AuditLog.append/2` → `Jason.encode!/1`), the
  encode raises and either drops the audit record (via the calling
  `Glorbo.CLI.Audit.emit/3` swallow) or kills the audit GenServer
  before the JSONL line is appended. Either way the audit evidence is
  lost.

  Codex flagged this in two places:

    * `Glorbo.Agent.Dispatch.bound_target/1` — tool-audit `target`
      capped at 1024 bytes.
    * `Glorbo.CLI.Dispatcher.Acp.Client.truncate_string/1` — ACP
      protocol audit detail values capped at 256 bytes.

  Both call `safe_byte_slice/2` here.
  """

  @doc """
  Return a prefix of `binary` that is at most `max_bytes` long AND is
  valid UTF-8.

  If `binary` already fits, it is returned unchanged. Otherwise the
  byte prefix is trimmed back over any trailing UTF-8 continuation
  bytes (and the incomplete lead byte that started a sequence) so the
  result lands on a codepoint boundary.

  The result is guaranteed valid UTF-8 when `binary` itself was valid
  UTF-8 (which is the only case that matters: every caller's input
  comes from a JSON-decoded string and is therefore valid by
  construction).

  Worst-case the returned binary is up to 3 bytes shorter than
  `max_bytes` (UTF-8 sequences are 1-4 bytes; a 4-byte sequence cut
  in its tail has 3 continuation bytes + 1 lead byte to strip).
  """
  @spec safe_byte_slice(binary(), pos_integer()) :: binary()
  def safe_byte_slice(binary, max_bytes)
      when is_binary(binary) and is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(binary) <= max_bytes do
      binary
    else
      binary
      |> binary_part(0, max_bytes)
      |> trim_partial_utf8()
    end
  end

  # Walk backward one byte at a time until the prefix is valid UTF-8.
  # An earlier byte-pattern-based version (strip continuation bytes,
  # then strip the lead) was incorrect: valid multi-byte codepoints
  # END with continuation bytes too — e.g. `é` is `0xC3 0xA9`, where
  # `0xA9` is a continuation byte. The byte-pattern walk would strip
  # the trailing `0xA9` from a complete `é` and then the `0xC3` lead,
  # destroying a valid codepoint. (Copilot review on PR #33.)
  #
  # `String.valid?/1` is the authoritative check. A truncated UTF-8
  # binary's longest valid prefix is at most 3 bytes shorter (max
  # codepoint length is 4 bytes; if the last is cut, strip its 1-3
  # trailing bytes).
  defp trim_partial_utf8(<<>>), do: <<>>

  defp trim_partial_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_partial_utf8()
    end
  end
end
