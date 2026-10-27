defmodule Junderground.Record do
  @moduledoc """
  A house record: the unit of the directory.

  It is a self-signed statement of who a house is, where it can be reached, and
  which statement supersedes which. The shape is the jawnos crest shape — a map
  of strings and integers, a raw Ed25519 `pubkey`, and a `sig` over the
  canonical JSON of every other field.

  ## The chain

    * `seq` starts at 1 and steps by exactly one.
    * `prev` is the `sig` of the record it supersedes, so a server cannot
      reorder or roll back a house's history without breaking the chain.
    * `rotate` moves signing authority: it is signed by the **old** key, names
      `new_pubkey`, and every later record carries the new key.
    * `tombstone` retires a handle. The same key may return with a higher `seq`;
      a different key may not take the handle over.
  """

  alias Junderground.Keys

  @format "junderground-house"
  @version 1
  @kinds ~w(register route rotate tombstone)
  @handle_re ~r/^[a-z0-9][a-z0-9._-]{1,62}$/
  @visibilities ~w(public unlisted sealed)
  @max_routes 16
  @max_value 2048
  @max_skew 3600

  def format, do: @format
  def kinds, do: @kinds

  @doc """
  Build an unsigned record. `fields` are merged over the defaults; pass
  `"prev"`, `"routes"`, `"name"`, `"visibility"` and friends there.
  """
  def build(kind, handle, pubkey, seq, fields \\ %{}) do
    Map.merge(
      %{
        "format" => @format,
        "version" => @version,
        "kind" => kind,
        "handle" => handle,
        "pubkey" => pubkey,
        "seq" => seq,
        "issued" => System.system_time(:second)
      },
      fields
    )
  end

  @doc """
  Validate `record` against the house's current head (or `nil` for a first
  registration).

  Returns `:ok`, `:unchanged` (this exact signature is already stored), or
  `{:error, reason}`.
  """
  def validate(record, prior) when is_map(record) do
    with :ok <- check_shape(record),
         :ok <- check_handle(record),
         :ok <- check_signature(record) do
      chain(record, prior)
    end
  end

  def validate(_record, _prior), do: {:error, :bad_record}

  @doc "The key that signs the next record (the new key after a rotation)."
  def active_pubkey(%{"kind" => "rotate", "new_pubkey" => key}), do: key
  def active_pubkey(record), do: record["pubkey"]

  def tombstone?(%{"kind" => "tombstone"}), do: true
  def tombstone?(_), do: false

  defp check_shape(record) do
    cond do
      record["format"] != @format ->
        {:error, :bad_format}

      record["version"] != @version ->
        {:error, :bad_version}

      record["kind"] not in @kinds ->
        {:error, :bad_kind}

      not Keys.valid_public_key?(record["pubkey"]) ->
        {:error, :bad_pubkey}

      record["kind"] == "rotate" and not Keys.valid_public_key?(record["new_pubkey"]) ->
        {:error, :bad_new_pubkey}

      record["kind"] == "rotate" and record["new_pubkey"] == record["pubkey"] ->
        {:error, :bad_new_pubkey}

      not is_integer(record["seq"]) or record["seq"] < 1 ->
        {:error, :bad_seq}

      not is_integer(record["issued"]) ->
        {:error, :bad_issued}

      record["issued"] > System.system_time(:second) + @max_skew ->
        {:error, :future}

      not is_binary(record["sig"]) ->
        {:error, :bad_signature}

      not valid_routes?(record["routes"]) ->
        {:error, :bad_routes}

      not valid_visibility?(record["visibility"]) ->
        {:error, :bad_visibility}

      not valid_name?(record["name"]) ->
        {:error, :bad_name}

      true ->
        :ok
    end
  end

  defp check_handle(record) do
    if is_binary(record["handle"]) and Regex.match?(@handle_re, record["handle"]) do
      :ok
    else
      {:error, :bad_handle}
    end
  end

  defp check_signature(record) do
    if Keys.verify_record(record), do: :ok, else: {:error, :bad_signature}
  end

  # first record ever seen for this handle
  defp chain(%{"kind" => "register"} = record, nil) do
    if record["seq"] == 1, do: :ok, else: {:error, :bad_first_seq}
  end

  defp chain(_record, nil), do: {:error, :not_registered}

  defp chain(record, prior) do
    cond do
      record["sig"] == prior["sig"] ->
        :unchanged

      prior["tombstoned"] and record["kind"] != "register" ->
        {:error, :retired}

      prior["tombstoned"] and record["pubkey"] != prior["pubkey"] ->
        {:error, :retired}

      record["kind"] == "register" and record["pubkey"] != prior["pubkey"] ->
        {:error, :taken}

      record["seq"] <= prior["seq"] ->
        {:error, :stale}

      record["seq"] != prior["seq"] + 1 ->
        {:error, :gap}

      record["prev"] != prior["sig"] ->
        {:error, :broken_chain}

      record["pubkey"] != prior["pubkey"] ->
        {:error, :wrong_key}

      true ->
        :ok
    end
  end

  defp valid_routes?(nil), do: true

  defp valid_routes?(routes) when is_map(routes) and map_size(routes) <= @max_routes do
    Enum.all?(routes, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        byte_size(key) > 0 and byte_size(value) <= @max_value

      _ ->
        false
    end)
  end

  defp valid_routes?(_), do: false

  defp valid_visibility?(nil), do: true
  defp valid_visibility?(value), do: value in @visibilities

  defp valid_name?(nil), do: true
  defp valid_name?(name), do: is_binary(name) and byte_size(name) <= 200
end
