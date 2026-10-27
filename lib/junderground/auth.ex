defmodule Junderground.Auth do
  @moduledoc """
  House-signed requests.

  A signed request names the house and proves possession of its key:

      X-JG-Handle:    alpha
      X-JG-Timestamp: 1760000000
      X-JG-Nonce:     12+ random bytes, base64url
      X-JG-Signature: base64 Ed25519 over the message below

  The message is:

      METHOD \\n PATH?QUERY \\n hex(sha256(body)) \\n timestamp \\n nonce

  The body hash binds the JSON, the timestamp bounds the window, and the nonce
  makes a captured request unusable a second time. Reads that need no identity
  (`GET /v1/houses/:handle`) are anonymous; bytes still need verifying for
  private handles, and the body is then empty.
  """

  alias Junderground.{Canonical, Directory, Nonces}

  @max_skew 300

  @doc "Verify the signed request. Returns `{:ok, %{handle, pubkey}}`."
  def verify(conn, raw_body) do
    with {:ok, handle} <- header(conn, "x-jg-handle"),
         {:ok, ts_text} <- header(conn, "x-jg-timestamp"),
         {:ok, nonce} <- header(conn, "x-jg-nonce"),
         {:ok, sig64} <- header(conn, "x-jg-signature"),
         {:ok, ts} <- to_int(ts_text),
         :ok <- in_window(ts),
         :ok <- Nonces.check(nonce, @max_skew),
         {:ok, head} <- Directory.live(handle),
         :ok <- check_signature(head, conn, raw_body, ts_text, nonce, sig64) do
      {:ok, %{handle: handle, pubkey: head["pubkey"]}}
    end
  end

  @doc "The exact bytes a client signs for a request."
  def message(conn, body, timestamp, nonce) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string

    Enum.join(
      [conn.method, conn.request_path <> query, Canonical.sha256_hex(body), timestamp, nonce],
      "\n"
    )
  end

  def max_skew, do: @max_skew

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
    if abs(System.system_time(:second) - ts) <= @max_skew do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  defp check_signature(head, conn, body, timestamp, nonce, sig64) do
    with {:ok, pub} <- Base.decode64(head["pubkey"]),
         {:ok, sig} <- Base.decode64(sig64) do
      msg = message(conn, body, timestamp, nonce)

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
