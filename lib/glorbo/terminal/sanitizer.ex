defmodule Glorbo.Terminal.Sanitizer do
  @moduledoc """
  Strip terminal control / ANSI / OSC escape sequences from untrusted text
  before it is written to the operator's terminal (C-117).

  Agent / provider stdout is an attacker-controlled output channel under the
  Glorbo threat model. Writing it verbatim lets a compromised provider inject
  escape sequences that spoof output, rewrite displayed lines, or manipulate
  the window title / hyperlinks / clipboard (OSC 8/52). The LiveView
  `StdoutStreamer` strips ANSI before broadcasting to the browser; this module
  is the equivalent guard for the CLI (`glorbo logs <co> <agent>`).

  Implemented as a single forward pass over the binary (not a backtracking
  regex). This matters because the CLI feeds the *whole* `stdout.log`, which is
  unbounded — a regex with a `[^\\x07]*` OSC alternative would be O(n²) on
  adversarial input of unterminated OSC starts (cf. finding C-091, where the
  same regex is bounded only because the dispatcher caps its input). A linear
  scanner has no such cliff.

  What is removed:

    * C0 control bytes (0x00-0x1F) except `\\t` and `\\n` — including BEL
      (`\\a`), backspace (`\\b`, used for overstrike spoofing), and CR (`\\r`,
      which renders as a line break under `pre-wrap` / lets text be rewritten
      in-place on a terminal).
    * The C1 control range (0x80-0x9F) when it appears as raw bytes.
    * CSI sequences: `ESC [ ... <final-byte>` (SGR colour, cursor moves,
      clears, etc.).
    * OSC sequences: `ESC ] ... (BEL | ESC \\)` (window title, hyperlinks,
      clipboard).
    * Other two-byte `ESC <byte>` escapes (e.g. `ESC =`, `ESC \\`).

  Visible (printable) text — including UTF-8 — is preserved.
  """

  @doc """
  Remove terminal control / escape sequences from `bin`, returning safe text.

  `\\t` and `\\n` are preserved so multi-line / tabular output still renders.
  """
  @spec strip(binary()) :: binary()
  def strip(bin) when is_binary(bin), do: scan(bin, [])

  # --- linear scanner -------------------------------------------------------

  defp scan(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # ESC introduces an escape sequence.
  defp scan(<<0x1B, rest::binary>>, acc), do: skip_escape(rest, acc)

  # Keep tab + newline.
  defp scan(<<c, rest::binary>>, acc) when c in [?\t, ?\n], do: scan(rest, [<<c>> | acc])

  # Drop other C0 control bytes (incl. CR, BEL, backspace).
  defp scan(<<c, rest::binary>>, acc) when c < 0x20, do: scan(rest, acc)

  # Printable ASCII passes as-is.
  defp scan(<<c, rest::binary>>, acc) when c >= 0x20 and c < 0x80,
    do: scan(rest, [<<c>> | acc])

  # A complete multi-byte UTF-8 codepoint passes through as one unit, so its
  # continuation bytes (0x80-0xBF) are never mistaken for raw C1 controls.
  defp scan(<<cp::utf8, rest::binary>>, acc), do: scan(rest, [<<cp::utf8>> | acc])

  # Remaining lead byte that did not form valid UTF-8 (incl. raw C1 controls
  # 0x80-0x9F and malformed bytes) — drop it.
  defp scan(<<_c, rest::binary>>, acc), do: scan(rest, acc)

  # ESC [ — CSI: consume parameter/intermediate bytes up to a final byte
  # (0x40-0x7E), then resume.
  defp skip_escape(<<?[, rest::binary>>, acc), do: skip_csi(rest, acc)

  # ESC ] — OSC: consume up to BEL or ESC \ (ST), then resume.
  defp skip_escape(<<?], rest::binary>>, acc), do: skip_osc(rest, acc)

  # Bare ESC at end of input — drop it.
  defp skip_escape(<<>>, acc), do: scan(<<>>, acc)

  # Other ESC <byte> two-char escapes — drop both bytes.
  defp skip_escape(<<_c, rest::binary>>, acc), do: scan(rest, acc)

  # CSI final byte is in 0x40-0x7E; parameters/intermediates precede it.
  defp skip_csi(<<>>, acc), do: scan(<<>>, acc)

  defp skip_csi(<<c, rest::binary>>, acc) when c >= 0x40 and c <= 0x7E, do: scan(rest, acc)
  defp skip_csi(<<_c, rest::binary>>, acc), do: skip_csi(rest, acc)

  # OSC terminates on BEL (0x07) or ST (ESC \).
  defp skip_osc(<<>>, acc), do: scan(<<>>, acc)
  defp skip_osc(<<0x07, rest::binary>>, acc), do: scan(rest, acc)
  defp skip_osc(<<0x1B, ?\\, rest::binary>>, acc), do: scan(rest, acc)
  defp skip_osc(<<_c, rest::binary>>, acc), do: skip_osc(rest, acc)
end
