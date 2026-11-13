defmodule Junderground.Sfu.Health do
  @moduledoc """
  The SFU's availability, cached.

  Every 30 seconds this process probes `GET <http-base>/` with a one-second
  timeout through `:httpc`. Three consecutive failures mark the SFU
  unavailable; one success restores it. A token request reads the cached
  answer through `up?/0`, so it never waits for a network probe.

  The base is `Sfu.http_base/0`: `wss://host/sfu` becomes `https://host/sfu`,
  and the path is kept. There is no assumed hostname.

  Tests replace the probe with `{Health, probe: fn -> :ok end}` and can force a
  check with `probe_now/0`.
  """

  use GenServer

  alias Junderground.Sfu

  @interval 30_000
  @timeout 1_000
  @failures_before_down 3
  @key :junderground_sfu_health

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The cached answer. False when the process is not running or no SFU is configured."
  def up? do
    if Process.whereis(__MODULE__) do
      case :persistent_term.get(@key, %{}) do
        %{up: up} -> up
        _ -> false
      end
    else
      false
    end
  end

  @doc "The cached state, for diagnostics and tests."
  def status do
    if Process.whereis(__MODULE__) do
      :persistent_term.get(@key, %{up: false, failures: 0, checked_at: nil})
    else
      %{up: false, failures: 0, checked_at: nil}
    end
  end

  @doc "Run the probe now, in the server process. Returns the probe's own result."
  def probe_now do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _ -> GenServer.call(__MODULE__, :probe_now, @timeout + 4_000)
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    probe = Keyword.get(opts, :probe, &default_probe/0)

    state = %{probe: probe, interval: interval, failures: 0, up: Sfu.enabled?(), checked_at: nil}
    state = check(state)
    publish(state)
    Process.send_after(self(), :probe, interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:probe_now, _from, state) do
    {result, state} = run(state)
    publish(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:probe, state) do
    {_result, state} = run(state)
    publish(state)
    Process.send_after(self(), :probe, state.interval)
    {:noreply, state}
  end

  # The cache lives in persistent_term so a token request reads it directly and
  # never queues behind the one-second probe running in this process.
  defp publish(state) do
    :persistent_term.put(@key, Map.take(state, [:up, :failures, :checked_at]))
  end

  defp check(state) do
    {_result, state} = run(state)
    state
  end

  defp run(state) do
    if Sfu.enabled?() do
      case state.probe.() do
        :ok -> {:ok, %{state | failures: 0, up: true, checked_at: now()}}
        {:error, _reason} = error -> fail(state, error)
        other -> fail(state, {:error, other})
      end
    else
      {{:error, :unconfigured}, %{state | failures: 0, up: false, checked_at: now()}}
    end
  rescue
    error -> fail(state, {:error, error})
  catch
    kind, reason -> fail(state, {:error, {kind, reason}})
  end

  defp fail(state, error) do
    failures = state.failures + 1

    {error,
     %{state | failures: failures, up: failures < @failures_before_down, checked_at: now()}}
  end

  defp now, do: System.system_time(:second)

  defp default_probe do
    case Sfu.http_base() do
      nil ->
        {:error, :unconfigured}

      base ->
        url = String.to_charlist(base <> "/")

        case :httpc.request(
               :get,
               {url, []},
               [timeout: @timeout, connect_timeout: @timeout],
               body_format: :binary
             ) do
          {:ok, {{_, status, _}, _, _}} when status >= 200 and status < 400 -> :ok
          {:ok, {{_, status, _}, _, _}} -> {:error, {:status, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
