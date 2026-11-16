defmodule Junderground.Applications do
  @moduledoc """
  Job applications relayed by the switch.

  An applicant has no house handle and no tailnet address, so the house's own
  box-office form cannot be the only door. They POST an application to the
  house's handle here; the switch stores it and the house collects it over its
  signed rail. The switch is the ingress, not the employer: it never decides,
  and it hands the applicant a private token so they can see the house's answer
  without an account.

  Only what the application carries is stored. The switch never receives a
  relationship map, a role's permissions, or a house key. The IP is kept as a
  short hash, for abuse only.
  """

  use GenServer

  alias Junderground.Admission

  @table :junderground_applications
  @statuses ~w(received approved declined)
  @max_per_ip 20
  @max_per_house 200
  @window 3600
  @max_roles 10
  @max_crest 4_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def create(handle, body, ip) when is_binary(handle) and is_map(body) do
    GenServer.call(__MODULE__, {:create, handle, body, ip})
  end

  def list(handle, since \\ 0), do: GenServer.call(__MODULE__, {:list, handle, since})
  def status(id, token), do: GenServer.call(__MODULE__, {:status, id, token})
  def decide(handle, id, status), do: GenServer.call(__MODULE__, {:decide, handle, id, status})

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.get_env(:junderground, :data_dir, "data"))
    File.mkdir_p!(dir)
    path = Path.join(dir, "applications.dets")
    :dets.close(@table)

    {:ok, _} =
      :dets.open_file(@table,
        file: String.to_charlist(path),
        type: :set,
        auto_save: 2_000
      )

    {:ok, %{rates: %{}}}
  end

  @impl true
  def handle_call({:create, handle, body, ip}, _from, state) do
    now = System.system_time(:second)
    state = prune(state, now)

    with :ok <- house_admitted(handle),
         :ok <- rate_ok(state, ip, handle, now),
         {:ok, app} <- build(handle, body, ip, now) do
      :dets.insert(@table, {{:application, app["id"]}, app})
      reply = Map.take(app, ["id", "token", "status", "created"])
      {:reply, {:ok, reply}, bump(state, ip, handle, now)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list, handle, since}, _from, state) do
    apps =
      :dets.foldl(
        fn
          {{:application, _id}, app}, acc ->
            if app["handle"] == handle and app["created"] > since do
              [public(app) | acc]
            else
              acc
            end

          _, acc ->
            acc
        end,
        [],
        @table
      )
      |> Enum.sort_by(& &1["created"], :desc)
      |> Enum.take(500)

    {:reply, {:ok, apps}, state}
  end

  def handle_call({:status, id, token}, _from, state) do
    reply =
      case lookup(id) do
        {:ok, app} ->
          if is_binary(token) and
               Plug.Crypto.secure_compare(token, app["token"] || "") do
            {:ok, Map.take(app, ["id", "status", "created", "decided"])}
          else
            {:error, :forbidden}
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:decide, handle, id, status}, _from, state) do
    reply =
      cond do
        status not in @statuses ->
          {:error, :bad_status}

        true ->
          case lookup(id) do
            {:ok, app} ->
              if app["handle"] == handle do
                app =
                  app
                  |> Map.put("status", status)
                  |> Map.put("decided", System.system_time(:second))
                  |> Map.put("decided_by", handle)

                :dets.insert(@table, {{:application, id}, app})
                {:ok, public(app)}
              else
                {:error, :not_found}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end

    {:reply, reply, state}
  end

  # ---- validation ---------------------------------------------------------

  defp house_admitted(handle) do
    if Admission.admitted?(handle), do: :ok, else: {:error, :unknown_house}
  end

  defp build(handle, body, ip, now) do
    with {:ok, name} <- text(body["name"], 200, true),
         {:ok, email} <- text(body["email"], 200, false),
         {:ok, phone} <- text(body["phone"], 60, false),
         {:ok, description} <- text(body["description"], 2_000, false),
         {:ok, interview} <- text(body["interview"], 300, false),
         {:ok, trial} <- text(body["trial"], 1_000, false),
         {:ok, roles} <- roles(body["roles"]),
         {:ok, crest} <- crest(body["crest"]),
         :ok <- consent(body["consent"]) do
      app =
        %{
          "id" => random_id(16),
          "token" => random_token(),
          "handle" => handle,
          "name" => name,
          "email" => email,
          "phone" => phone,
          "description" => description,
          "interview" => interview,
          "trial" => trial,
          "roles" => roles,
          "crest" => crest,
          "status" => "received",
          "created" => now,
          "source" => "relay",
          "ip_hash" => hash_ip(ip)
        }
        |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
        |> Map.new()

      {:ok, app}
    end
  end

  defp text(value, max, required) do
    cond do
      is_nil(value) and required ->
        {:error, :bad_field}

      is_nil(value) ->
        {:ok, ""}

      not is_binary(value) ->
        {:error, :bad_field}

      true ->
        clean =
          value
          |> String.slice(0, max + 1)
          |> String.replace(~r/[\x00-\x1f\x7f]+/u, " ")
          |> String.trim()

        cond do
          byte_size(clean) > max -> {:error, :bad_field}
          required and clean == "" -> {:error, :bad_field}
          true -> {:ok, clean}
        end
    end
  end

  defp roles(nil), do: {:ok, []}
  defp roles(value) when is_binary(value), do: roles(String.split(value, ","))

  defp roles(list) when is_list(list) and length(list) <= @max_roles do
    cleaned =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or byte_size(&1) > 100))
      |> Enum.uniq()

    if length(cleaned) == Enum.count(list, &is_binary/1) do
      {:ok, cleaned}
    else
      {:error, :bad_roles}
    end
  end

  defp roles(_), do: {:error, :bad_roles}

  defp crest(nil), do: {:ok, nil}

  defp crest(value) when is_map(value) do
    if byte_size(JSON.encode!(value)) <= @max_crest and map_size(value) <= 12 do
      {:ok, value}
    else
      {:error, :bad_crest}
    end
  end

  defp crest(value) when is_binary(value) do
    if byte_size(value) <= @max_crest, do: {:ok, value}, else: {:error, :bad_crest}
  end

  defp crest(_), do: {:error, :bad_crest}

  defp consent("on"), do: :ok
  defp consent(_), do: {:error, :bad_consent}

  # ---- storage helpers ----------------------------------------------------

  defp lookup(id) do
    case :dets.lookup(@table, {:application, id}) do
      [{{:application, ^id}, app}] -> {:ok, app}
      _ -> {:error, :not_found}
    end
  end

  defp public(app) do
    Map.drop(app, ["token", "ip_hash"])
  end

  defp hash_ip(ip) when is_binary(ip) do
    :crypto.hash(:sha256, ip)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp hash_ip(_), do: ""

  defp random_id(bytes) do
    :crypto.strong_rand_bytes(bytes)
    |> Base.encode16(case: :lower)
  end

  defp random_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  # ---- rate limiting ------------------------------------------------------
  # A restart resets the counters; the door is the only thing this protects, and
  # a lost counter is cheaper than a DETS write per request.

  defp prune(state, now) do
    rates =
      state.rates
      |> Enum.filter(fn {_key, {start, _count}} -> now - start < @window end)
      |> Map.new()

    %{state | rates: rates}
  end

  defp rate_ok(state, ip, handle, now) do
    {_start, count} = Map.get(state.rates, {ip, handle}, {now, 0})

    house_count =
      state.rates
      |> Enum.filter(fn {{_ip, h}, _} -> h == handle end)
      |> Enum.map(fn {_key, {_start, n}} -> n end)
      |> Enum.sum()

    if count >= @max_per_ip or house_count >= @max_per_house do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp bump(state, ip, handle, now) do
    {start, count} = Map.get(state.rates, {ip, handle}, {now, 0})
    %{state | rates: Map.put(state.rates, {ip, handle}, {start, count + 1})}
  end
end
