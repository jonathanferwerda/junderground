defmodule Junderground.Rooms do
  @moduledoc """
  Rooms belong to a house, which signs their policy record with its own key.
  The switch turns a room policy plus a signed request into a short-lived grant
  (see `Junderground.Token`) and hands out TURN credentials alongside it.

  A grant is the only thing a media server or a peer needs to admit someone:
  it names the room, the subject, the capabilities, an expiry and a `jti` the
  room owner can revoke.
  """

  use GenServer

  alias Junderground.{Admission, Canonical, Constructs, Directory, Keys, ServerKey, Token, Turn}

  @table :junderground_rooms
  @format "junderground-room"
  @version 1
  @kinds ~w(register update tombstone)
  @slug ~r/^[a-z0-9][a-z0-9._-]{0,62}$/
  @policies ~w(open house invite)
  @recordings ~w(off allow)
  @caps ~w(join publish_audio publish_video subscribe record moderate invite)
  @max_skew 3600

  # ---- api -----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def build(handle, room, pubkey, seq, fields \\ %{}) do
    Map.merge(
      %{
        "format" => @format,
        "version" => @version,
        "kind" => "register",
        "handle" => handle,
        "room" => room,
        "pubkey" => pubkey,
        "seq" => seq,
        "issued" => System.system_time(:second),
        "name" => room,
        "constructs" => Constructs.defaults(),
        "advertised" => "no",
        "policy" => "invite",
        "max" => 16,
        "recording" => "off",
        "expires" => 0
      },
      fields
    )
  end

  def register(record), do: GenServer.call(__MODULE__, {:register, record})
  def latest(handle, room), do: GenServer.call(__MODULE__, {:latest, handle, room})
  def list(handle), do: GenServer.call(__MODULE__, {:list, handle})
  def by_channel(channel), do: GenServer.call(__MODULE__, {:by_channel, channel})

  def grant(handle, room, requester, body) when is_map(body) do
    GenServer.call(__MODULE__, {:grant, handle, room, requester, body})
  end

  def revoke(handle, room, requester, jti, expires) do
    GenServer.call(__MODULE__, {:revoke, handle, room, requester, jti, expires})
  end

  def verify_grant(token), do: GenServer.call(__MODULE__, {:verify_grant, token})
  def revoked?(jti), do: GenServer.call(__MODULE__, {:revoked?, jti})
  def caps, do: @caps

  # ---- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.get_env(:junderground, :data_dir, "data"))
    File.mkdir_p!(dir)
    path = Path.join(dir, "rooms.dets")

    :dets.close(@table)

    {:ok, _} =
      :dets.open_file(@table,
        file: String.to_charlist(path),
        type: :set,
        auto_save: 2_000
      )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @impl true
  def handle_call({:register, record}, _from, state) do
    prior = head(record["handle"], record["room"])

    reply =
      case validate(record, prior) do
        :unchanged ->
          {:ok, :unchanged}

        :ok ->
          put(record)
          {:ok, %{handle: record["handle"], room: record["room"], seq: record["seq"]}}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:latest, handle, room}, _from, state) do
    reply =
      case head(handle, room) do
        nil -> {:error, :not_found}
        head -> {:ok, head}
      end

    {:reply, reply, state}
  end

  def handle_call({:list, handle}, _from, state) do
    ms = [{{{:room, handle, :"$1"}, :"$2"}, [], [:"$2"]}]
    {:reply, {:ok, :dets.select(@table, ms)}, state}
  end

  def handle_call({:by_channel, channel}, _from, state) do
    heads = :dets.select(@table, [{{{:room, :_, :_}, :"$1"}, [], [:"$1"]}])

    open =
      Enum.filter(heads, fn head ->
        head["channel"] == channel and not head["tombstoned"]
      end)

    {:reply, {:ok, open}, state}
  end

  def handle_call({:grant, handle, room, requester, body}, _from, state) do
    reply =
      with {:ok, requester_record} <- Admission.status(requester.handle),
           :ok <- requester_admitted(requester_record),
           {:ok, head} <- fetch(handle, room),
           :ok <- room_state(head),
           :ok <- owner_admitted(head["record"]["handle"]),
           :ok <- access(head["record"], requester, body["invite"]),
           {:ok, caps} <- clamp(head["record"], requester, body["caps"], body["invite"]) do
        now = System.system_time(:second)
        probation = requester_record["status"] == "probation"
        ttl = Application.get_env(:junderground, :grant_ttl, 900)
        ttl = if probation, do: min(ttl, 300), else: ttl

        caps =
          if probation,
            do: Enum.filter(caps, &(&1 in ["join", "subscribe", "publish_audio"])),
            else: caps

        room_exp = head["record"]["expires"] || 0
        expires = if room_exp > 0, do: min(now + ttl, room_exp), else: now + ttl

        payload = %{
          "format" => "junderground-grant",
          "version" => 1,
          "iss" => Application.get_env(:junderground, :public_url, "http://localhost:4100"),
          "room" => handle <> "/" <> room,
          "room_key" => head["room_key"],
          "sub" => requester.handle,
          "caps" => caps,
          "iat" => now,
          "exp" => expires,
          "jti" => random_id()
        }

        {:ok,
         %{
           "grant" => Token.mint(payload, ServerKey.private()),
           "room" => payload["room"],
           "subject" => requester.handle,
           "caps" => caps,
           "expires" => expires,
           "ice_servers" => Turn.credentials(requester.handle, max(expires - now, 0))
         }}
      end

    {:reply, reply, state}
  end

  def handle_call({:revoke, handle, room, requester, jti, expires}, _from, state) do
    reply =
      with {:ok, head} <- fetch(handle, room),
           :ok <- owner_only(head["record"], requester),
           :ok <- valid_jti(jti) do
        now = System.system_time(:second)
        expires = if is_integer(expires) and expires > now, do: expires, else: now + 3_600
        :dets.insert(@table, {{:revoked, jti}, expires})
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:verify_grant, token}, _from, state) do
    {:reply, verify_grant_token(token), state}
  end

  def handle_call({:revoked?, jti}, _from, state) do
    {:reply, revoked_now?(jti), state}
  end

  # ---- validation ----------------------------------------------------------

  defp validate(record, prior) when is_map(record) do
    with :ok <- shape(record),
         :ok <- house_live(record["handle"]),
         :ok <- allowed(record["handle"], prior),
         :ok <- signature(record) do
      chain(record, prior)
    end
  end

  defp validate(_record, _prior), do: {:error, :bad_record}

  defp shape(record) do
    cond do
      record["format"] != @format ->
        {:error, :bad_format}

      record["version"] != @version ->
        {:error, :bad_version}

      record["kind"] not in @kinds ->
        {:error, :bad_kind}

      not is_binary(record["handle"]) or not Regex.match?(@slug, record["handle"]) ->
        {:error, :bad_handle}

      not is_binary(record["room"]) or not Regex.match?(@slug, record["room"]) ->
        {:error, :bad_room}

      not Keys.valid_public_key?(record["pubkey"]) ->
        {:error, :bad_pubkey}

      not is_integer(record["seq"]) or record["seq"] < 1 ->
        {:error, :bad_seq}

      not is_integer(record["issued"]) ->
        {:error, :bad_issued}

      record["issued"] > System.system_time(:second) + @max_skew ->
        {:error, :future}

      not is_binary(record["sig"]) ->
        {:error, :bad_signature}

      record["policy"] not in @policies ->
        {:error, :bad_policy}

      not is_integer(record["max"]) or record["max"] < 2 or record["max"] > 256 ->
        {:error, :bad_max}

      record["recording"] not in @recordings ->
        {:error, :bad_recording}

      not is_integer(record["expires"]) or record["expires"] < 0 ->
        {:error, :bad_expires}

      not is_binary(record["name"]) or byte_size(record["name"]) > 200 ->
        {:error, :bad_name}

      not valid_constructs?(record["constructs"]) ->
        {:error, :bad_constructs}

      record["advertised"] not in ["yes", "no"] ->
        {:error, :bad_advertised}

      true ->
        :ok
    end
  end

  defp house_live(handle) do
    case Directory.live(handle) do
      {:ok, _head} -> :ok
      _ -> {:error, :unknown_house}
    end
  end

  defp signature(record) do
    if Keys.verify_record(record), do: :ok, else: {:error, :bad_signature}
  end

  defp valid_constructs?(value), do: match?({:ok, _}, Constructs.normalize(value))

  # A new room needs an approved house; editing an existing one is allowed
  # while pending or on probation, but not after a stop.
  defp allowed(handle, nil) do
    if Admission.may_create_room?(handle), do: :ok, else: {:error, :not_admitted}
  end

  defp allowed(handle, _prior) do
    if Admission.may_write?(handle), do: :ok, else: {:error, :not_admitted}
  end

  defp requester_admitted(%{"status" => status}) when status in ["approved", "probation"], do: :ok
  defp requester_admitted(_record), do: {:error, :not_admitted}

  defp owner_admitted(handle) do
    case Admission.status(handle) do
      {:ok, %{"status" => status}} when status in ["approved", "probation"] -> :ok
      _ -> {:error, :room_closed}
    end
  end

  defp chain(%{"kind" => "register"} = record, nil) do
    if record["seq"] == 1, do: :ok, else: {:error, :bad_first_seq}
  end

  defp chain(_record, nil), do: {:error, :not_registered}

  defp chain(record, prior) do
    cond do
      record["sig"] == prior["sig"] -> :unchanged
      prior["tombstoned"] and record["kind"] != "register" -> {:error, :retired}
      prior["tombstoned"] and record["pubkey"] != prior["pubkey"] -> {:error, :retired}
      record["kind"] == "register" and record["pubkey"] != prior["pubkey"] -> {:error, :taken}
      record["seq"] <= prior["seq"] -> {:error, :stale}
      record["seq"] != prior["seq"] + 1 -> {:error, :gap}
      record["prev"] != prior["sig"] -> {:error, :broken_chain}
      record["pubkey"] != prior["pubkey"] -> {:error, :wrong_key}
      true -> :ok
    end
  end

  # ---- grants --------------------------------------------------------------

  defp room_state(%{"tombstoned" => true}), do: {:error, :retired}

  defp room_state(%{"record" => record}) do
    expires = record["expires"] || 0
    if expires > 0 and expires <= System.system_time(:second), do: {:error, :expired}, else: :ok
  end

  defp access(record, requester, invite) do
    cond do
      requester.handle == record["handle"] ->
        :ok

      record["policy"] == "open" ->
        :ok

      record["policy"] == "invite" ->
        if invite_ok?(invite, record), do: :ok, else: {:error, :invite_required}

      true ->
        {:error, :forbidden}
    end
  end

  defp invite_ok?(token, record) when is_binary(token) do
    case verify_grant_token(token) do
      {:ok, payload} ->
        payload["room"] == record["handle"] <> "/" <> record["room"] and
          "invite" in (payload["caps"] || [])

      _ ->
        false
    end
  end

  defp invite_ok?(_token, _record), do: false

  defp clamp(record, requester, requested, invite) do
    requested =
      if is_list(requested) and requested != [] do
        requested
      else
        ["join", "publish_audio", "subscribe"]
      end

    owner = requester.handle == record["handle"]

    owner_caps = if owner, do: ["moderate", "invite"], else: []
    record_caps = if owner and record["recording"] == "allow", do: ["record"], else: []

    invited_caps =
      case verify_grant_token(invite) do
        {:ok, payload} -> Enum.filter(payload["caps"] || [], &(&1 in @caps))
        _ -> []
      end

    allowed =
      MapSet.new(
        ["join", "publish_audio", "publish_video", "subscribe"] ++
          owner_caps ++ record_caps ++ invited_caps
      )

    cond do
      not Enum.all?(requested, &(&1 in @caps)) ->
        {:error, :bad_cap}

      true ->
        caps =
          requested |> Enum.filter(&MapSet.member?(allowed, &1)) |> Enum.uniq() |> Enum.sort()

        if "join" in caps, do: {:ok, caps}, else: {:error, :forbidden}
    end
  end

  def verify_grant_token(token) do
    with {:ok, payload} <- Token.verify(token, ServerKey.public_b64()) do
      cond do
        Token.expired?(payload) -> {:error, :expired}
        revoked_now?(payload["jti"]) -> {:error, :revoked}
        true -> {:ok, payload}
      end
    end
  end

  defp revoked_now?(jti) when is_binary(jti) do
    now = System.system_time(:second)

    case :dets.lookup(@table, {:revoked, jti}) do
      [{{:revoked, ^jti}, expires}] ->
        if expires > now do
          true
        else
          :dets.delete(@table, {:revoked, jti})
          false
        end

      _ ->
        false
    end
  end

  defp revoked_now?(_), do: false

  defp owner_only(record, requester) do
    if requester.handle == record["handle"], do: :ok, else: {:error, :forbidden}
  end

  defp valid_jti(jti) when is_binary(jti) and byte_size(jti) >= 8, do: :ok
  defp valid_jti(_), do: {:error, :bad_jti}

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  # ---- storage -------------------------------------------------------------

  defp fetch(handle, room) do
    case head(handle, room) do
      nil -> {:error, :not_found}
      head -> {:ok, head}
    end
  end

  defp head(handle, room) do
    case :dets.lookup(@table, {:room, handle, room}) do
      [{{:room, ^handle, ^room}, head}] -> head
      _ -> nil
    end
  end

  defp put(record) do
    sig = record["sig"]
    {:ok, constructs} = Constructs.normalize(record["constructs"])

    head = %{
      "seq" => record["seq"],
      "sig" => sig,
      "pubkey" => record["pubkey"],
      "tombstoned" => record["kind"] == "tombstone",
      "room_key" => Canonical.sha256_hex(sig),
      "constructs" => constructs,
      "channel" => Constructs.channel_id(constructs),
      "advertised" => record["advertised"] == "yes",
      "record" => record
    }

    :dets.insert(@table, {{:room, record["handle"], record["room"]}, head})
  end
end
