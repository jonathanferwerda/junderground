defmodule Junderground.ServerKey do
  @moduledoc """
  The switch's own Ed25519 identity, used to sign room grants and advertised in
  `GET /v1/meta`. Clients pin this key (or the `iss` that maps to it).
  """

  @persistent_key :junderground_server_key

  @doc "`{public_b64, private_raw}` for this switch, generated on first use."
  def pair do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        pair = load()
        :persistent_term.put(@persistent_key, pair)
        pair

      pair ->
        pair
    end
  end

  def public_b64, do: elem(pair(), 0)
  def private, do: elem(pair(), 1)

  @doc "Forget the cached key (tests only)."
  def reset, do: :persistent_term.erase(@persistent_key)

  defp load do
    dir = Application.get_env(:junderground, :data_dir, "data")
    path = Path.join(dir, "server.key")
    File.mkdir_p!(Path.dirname(path))

    case File.read(path) do
      {:ok, text} ->
        [pub64, priv64] = text |> String.trim() |> String.split(":")
        {pub64, Base.decode64!(priv64)}

      _ ->
        {pub64, priv} = Junderground.Keys.generate()
        File.write!(path, pub64 <> ":" <> Base.encode64(priv))
        File.chmod(path, 0o600)
        {pub64, priv}
    end
  end
end
