defmodule Junderground.Keys do
  @moduledoc """
  Ed25519 over canonical JSON — the jawnos crest convention.

  A record carries its public key (`pubkey`, raw 32 bytes, base64) and its
  signature (`sig`, 64 bytes, base64). The signature covers the canonical JSON of
  every field except `sig`, so the key itself is signed for and cannot be swapped
  without breaking the signature.
  """

  alias Junderground.Canonical

  @doc "The exact bytes a record signs: canonical JSON with `sig` removed."
  def signing_bytes(record) when is_map(record) do
    record |> Map.delete("sig") |> Canonical.encode()
  end

  @doc "Return `record` with a `sig` made by `private_key` (raw 32 bytes)."
  def sign_record(record, private_key) when is_map(record) and is_binary(private_key) do
    sig = :crypto.sign(:eddsa, :none, signing_bytes(record), [private_key, :ed25519])
    Map.put(record, "sig", Base.encode64(sig))
  end

  @doc "True when `record` carries a valid signature by the key it names."
  def verify_record(record) when is_map(record) do
    with pub64 when is_binary(pub64) <- record["pubkey"],
         {:ok, pub} <- Base.decode64(pub64),
         true <- byte_size(pub) == 32,
         sig64 when is_binary(sig64) <- record["sig"],
         {:ok, sig} <- Base.decode64(sig64),
         true <- byte_size(sig) == 64 do
      :crypto.verify(:eddsa, :none, signing_bytes(record), sig, [pub, :ed25519])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "A fresh key pair: `{public_b64, private_raw}`."
  def generate do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {Base.encode64(pub), priv}
  end

  @doc "The human-facing fingerprint jawnos shows for a crest key."
  def fingerprint(pub64) do
    case Base.decode64(pub64) do
      {:ok, pub} ->
        pub
        |> Canonical.sha256_hex()
        |> String.upcase()
        |> String.replace(~r/(.{4})(?=.)/, "\\1 ")

      _ ->
        nil
    end
  end

  @doc "A stable, URL-safe id for a public key: SHA-256 hex of the raw key."
  def key_id(pub64) do
    case Base.decode64(pub64) do
      {:ok, pub} -> Canonical.sha256_hex(pub)
      _ -> nil
    end
  end

  @doc "True when `value` is a base64 raw Ed25519 public key."
  def valid_public_key?(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, key} -> byte_size(key) == 32
      _ -> false
    end
  end

  def valid_public_key?(_), do: false
end
