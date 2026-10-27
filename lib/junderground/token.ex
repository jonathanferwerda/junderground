defmodule Junderground.Token do
  @moduledoc """
  A compact, signed capability token: `JG1.<payload>.<signature>`.

  The payload is canonical JSON signed with Ed25519 by the switch's own key. It
  is not a JWT: it is the same crypto and encoding as a record, so one verifier
  covers both. A token is short-lived and carries a `jti`, which is what a room
  revokes.
  """

  alias Junderground.Canonical

  @prefix "JG1"

  def mint(payload, private_key) when is_map(payload) do
    body = Canonical.encode(payload)
    sig = :crypto.sign(:eddsa, :none, body, [private_key, :ed25519])
    Enum.join([@prefix, b64(body), b64(sig)], ".")
  end

  def verify(token, public_b64) when is_binary(token) and is_binary(public_b64) do
    with [@prefix, body64, sig64] <- String.split(token, "."),
         {:ok, body} <- unb64(body64),
         {:ok, sig} <- unb64(sig64),
         {:ok, pub} <- Base.decode64(public_b64),
         true <- byte_size(pub) == 32,
         true <- :crypto.verify(:eddsa, :none, body, sig, [pub, :ed25519]),
         {:ok, payload} when is_map(payload) <- JSON.decode(body) do
      {:ok, payload}
    else
      _ -> {:error, :bad_token}
    end
  rescue
    _ -> {:error, :bad_token}
  end

  def verify(_token, _public_b64), do: {:error, :bad_token}

  def expired?(payload) when is_map(payload) do
    exp = payload["exp"]
    is_integer(exp) and exp <= System.system_time(:second)
  end

  def expired?(_), do: true

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp unb64(text), do: Base.url_decode64(text, padding: false)
end
