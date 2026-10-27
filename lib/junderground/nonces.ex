defmodule Junderground.Nonces do
  @moduledoc """
  Short-lived nonce memory for signed requests. A repeated nonce inside the
  request window is a replay and is refused.
  """

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Remember `nonce` for `ttl` seconds; `{:error, :replay}` if already seen."
  def check(nonce, ttl) when is_binary(nonce) and byte_size(nonce) >= 16 do
    GenServer.call(__MODULE__, {:check, nonce, ttl})
  end

  def check(_nonce, _ttl), do: {:error, :bad_nonce}

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:check, nonce, ttl}, _from, state) do
    now = System.monotonic_time(:second)
    state = state |> Enum.reject(fn {_k, expires} -> expires < now end) |> Map.new()

    if Map.has_key?(state, nonce) do
      {:reply, {:error, :replay}, state}
    else
      {:reply, :ok, Map.put(state, nonce, now + ttl)}
    end
  end
end
