defmodule Junderground.Canonical do
  @moduledoc """
  Canonical JSON: the exact bytes a house signs.

  This is deliberately the same convention jawnos already uses for crests
  (`subs::crest_canonical_json`: `JSON::PP->new->canonical(1)` over the record
  with `sig` removed, then Ed25519 over the result). Keeping it identical means
  the phone and the desktop can verify a junderground record with no new
  dependency.

  Signed payloads are restricted to what both encoders render identically:

    * object keys are ASCII strings, sorted byte-wise;
    * values are strings, integers, lists, or nested objects;
    * no floats, booleans, or null (use a string when a flag is needed);
    * no whitespace; non-ASCII is legal UTF-8 but discouraged in signed fields.
  """

  @spec encode(term()) :: binary()
  def encode(value), do: IO.iodata_to_binary(do_encode(value))

  defp do_encode(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {key, value} -> {key!(key), value} end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> [quote_string(key), ?:, do_encode(value)] end)
      |> Enum.intersperse(?,)

    [?{, inner, ?}]
  end

  defp do_encode(list) when is_list(list) do
    [?[, Enum.map_intersperse(list, ?,, &do_encode/1), ?]]
  end

  defp do_encode(n) when is_integer(n), do: Integer.to_string(n)
  defp do_encode(s) when is_binary(s), do: quote_string(s)

  defp do_encode(other) do
    raise ArgumentError,
          "not canonical-serialisable (strings, integers, lists and maps only): #{inspect(other)}"
  end

  defp key!(key) when is_binary(key) do
    if String.valid?(key) and byte_size(key) > 0 do
      key
    else
      raise ArgumentError, "canonical JSON keys must be non-empty valid UTF-8"
    end
  end

  defp key!(key),
    do: raise(ArgumentError, "canonical JSON keys must be strings, got: #{inspect(key)}")

  defp quote_string(bin) when is_binary(bin) do
    unless String.valid?(bin), do: raise(ArgumentError, "invalid UTF-8 in canonical JSON string")
    [?", escape(bin, []), ?"]
  end

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<8, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<12, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])

  defp escape(<<c, rest::binary>>, acc) when c < 0x20 do
    escape(rest, [:io_lib.format("\\u~4.16.0b", [c]) | acc])
  end

  defp escape(<<c, rest::binary>>, acc), do: escape(rest, [<<c>> | acc])

  @doc "Lower-case hex SHA-256, the form used in signed request headers."
  def sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
end
