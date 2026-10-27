defmodule Junderground.Admin do
  @moduledoc """
  Administrators are crest keys listed in configuration (`JG_ADMIN_KEYS`).

  An admin request is signed exactly like a house request, but names its key in
  `X-JG-Admin` instead of a handle. This is the API an approval agent uses: it
  can read the queue, put a house on probation, extend a review, suspend a
  house, or lift a ban, and every decision is written to the audit log.
  """

  alias Junderground.{Auth, Nonces}

  @max_skew 300

  def keys do
    Application.get_env(:junderground, :admin_keys, [])
    |> List.wrap()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def count, do: length(keys())

  def admin_key?(pubkey) when is_binary(pubkey), do: pubkey in keys()
  def admin_key?(_pubkey), do: false

  @doc "Verify an administrator-signed request. Returns `{:ok, %{admin: pubkey}}`."
  def verify(conn, raw_body) do
    with {:ok, pub} <- header(conn, "x-jg-admin"),
         true <- admin_key?(pub) or {:error, :not_admin},
         {:ok, ts_text} <- header(conn, "x-jg-timestamp"),
         {:ok, nonce} <- header(conn, "x-jg-nonce"),
         {:ok, sig64} <- header(conn, "x-jg-signature"),
         {:ok, ts} <- to_int(ts_text),
         :ok <- in_window(ts),
         :ok <- Nonces.check(nonce, @max_skew),
         :ok <- check_signature(pub, conn, raw_body, ts_text, nonce, sig64) do
      {:ok, %{admin: pub}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_admin}
    end
  end

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_auth}
    end
  end

  defp to_int(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_timestamp}
    end
  end

  defp in_window(ts) do
    if abs(System.system_time(:second) - ts) <= @max_skew,
      do: :ok,
      else: {:error, :stale_timestamp}
  end

  defp check_signature(pub64, conn, body, timestamp, nonce, sig64) do
    with {:ok, pub} <- Base.decode64(pub64),
         {:ok, sig} <- Base.decode64(sig64) do
      msg = Auth.message(conn, body, timestamp, nonce)

      if :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519]) do
        :ok
      else
        {:error, :bad_signature}
      end
    else
      _ -> {:error, :bad_signature}
    end
  end
end
