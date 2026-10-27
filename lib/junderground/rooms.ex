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

  alias Junderground.{
    Admission,
    Canonical,
    Constructs,
    Directory,
    Keys,
    Rentals,
    ServerKey,
    Token,
    Turn
  }

  @table :junderground_rooms
  @format "junderground-room"
  @version 1
  @kinds ~w(register update tombstone)
  @slug ~r/^[a-z0-9][a-z0-9._-]{0,62}$/
  @policies ~w(open house invite direct ticket)
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
        "constructs" => %{},
        "advertised" => "no",
        "members" => [],
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
  def dial(scope), do: GenServer.call(__MODULE__, {:dial, scope})

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

  def handle_call({:dial, scope}, _from, state) do
    heads = :dets.select(@table, [{{{:room, :_, :_}, :"$1"}, [], [:"$1"]}])

    open =
      Enum.filter(heads, fn head ->
        not head["tombstoned"] and Constructs.matches?(head["constructs"], scope)
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
           {:ok, rental} <- Rentals.open_for(handle, room, requester.handle),
           {:ok, ticket} <- consume_ticket(head["record"], requester, body["ticket"]),
           :ok <- access(head["record"], requester, body["invite"], ticket),
           {:ok, caps} <- clamp(head["record"], requester, body["caps"], body["invite"], ticket) do
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
        expires = if is_map(rental), do: min(expires, rental["end"]), else: expires

        payload =
          %{
            "format" => "junderground-grant",
            "version" => 1,
            "iss" => Application.get_env(:junderground, :public_url, "http://localhost:4100"),
            "room" => handle <> "/" <> room,
            "room_key" => head["room_key"],
            "sub" => requester.handle,
            "caps" => caps,
            "iat" => now,
            "exp" => expires,
            "epoch" => Admission.epoch(handle),
            "jti" => random_id()
          }
          |> maybe_rental(rental)

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

  def handle_call({:issue_ticket, handle, room, requester, body}, _from, state) do
    reply =
      with {:ok, head} <- fetch(handle, room),
           :ok <- room_state(head),
           :ok <- owner_only(head["record"], requester),
           {:ok, bind} <- ticket_bind(body["sub"], body["bind"]),
           {:ok, sub} <- ticket_subject(body["sub"], bind),
           {:ok, caps} <- ticket_caps(body["caps"]),
           {:ok, uses} <- ticket_uses(body["uses"]),
           {:ok, meta} <- ticket_meta(body["meta"]),
           {:ok, expires} <- ticket_expiry(body["expires"]),
           {:ok, rental} <- rental_for_ticket(handle, room),
           :ok <- ticket_window(expires, rental) do
        now = System.system_time(:second)
        expires = if is_map(rental), do: min(expires, rental["end"]), else: expires
        jti = random_id()

        payload =
          %{
            "format" => "junderground-grant",
            "version" => 1,
            "kind" => "ticket",
            "iss" => Application.get_env(:junderground, :public_url, "http://localhost:4100"),
            "room" => handle <> "/" <> room,
            "room_key" => head["room_key"],
            "bind" => bind,
            "meta" => meta,
            "caps" => caps,
            "iat" => now,
            "exp" => expires,
            "epoch" => Admission.epoch(handle),
            "jti" => jti,
            "uses" => uses
          }
          |> maybe_sub(sub)
          |> maybe_rental(rental)

        stored =
          %{
            "room" => handle <> "/" <> room,
            "bind" => bind,
            "meta" => meta,
            "caps" => caps,
            "exp" => expires,
            "uses_left" => uses,
            "by" => requester.handle
          }
          |> maybe_sub(sub)
          |> maybe_rental(rental)

        :dets.insert(@table, {{:ticket, jti}, stored})

        {:ok,
         %{
           "ticket" => Token.mint(payload, ServerKey.private()),
           "jti" => jti,
           "room" => payload["room"],
           "subject" => sub,
           "bind" => bind,
           "meta" => meta,
           "caps" => caps,
           "expires" => expires,
           "uses" => uses
         }
         |> maybe_rental(rental)}
      end

    {:reply, reply, state}
  end

  def handle_call({:list_tickets, handle, room}, _from, state) do
    room_id = handle <> "/" <> room

    tickets =
      :dets.select(@table, [{{{:ticket, :"$1"}, :"$2"}, [], [:"$1", :"$2"]}])
      |> Enum.filter(fn {_jti, stored} -> stored["room"] == room_id end)
      |> Enum.map(fn {jti, stored} ->
        %{
          "jti" => jti,
          "subject" => stored["sub"],
          "bind" => stored["bind"] || "subject",
          "meta" => stored["meta"] || %{},
          "rental" => stored["rental"],
          "caps" => stored["caps"],
          "expires" => stored["exp"],
          "uses_left" => stored["uses_left"]
        }
      end)
      |> Enum.sort_by(& &1["expires"])

    {:reply, {:ok, tickets}, state}
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

      not valid_members?(record["members"]) ->
        {:error, :bad_members}

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

  defp access(record, requester, invite, ticket) do
    cond do
      requester.handle == record["handle"] ->
        :ok

      record["policy"] == "open" ->
        :ok

      record["policy"] == "house" ->
        {:error, :forbidden}

      record["policy"] == "direct" ->
        if requester.handle in (record["members"] || []), do: :ok, else: {:error, :forbidden}

      record["policy"] == "invite" ->
        if invite_ok?(invite, record) or ticket != nil,
          do: :ok,
          else: {:error, :invite_required}

      record["policy"] == "ticket" ->
        if ticket != nil, do: :ok, else: {:error, :ticket_required}

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

  defp clamp(record, requester, requested, invite, ticket) do
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
      if ticket do
        MapSet.new(ticket["caps"] || [])
      else
        MapSet.new(
          ["join", "publish_audio", "publish_video", "subscribe"] ++
            owner_caps ++ record_caps ++ invited_caps
        )
      end

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
        stale_epoch?(payload) -> {:error, :revoked}
        suspended_subject?(payload["sub"]) -> {:error, :revoked}
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

  # A suspension is immediate for grants already in the wild: anything issued
  # before the stop began is dead, for the room's owner and for its subject.
  # A stop bumps the owner's epoch, so every grant issued before it dies at
  # once; a new grant carries the new epoch. A suspended subject is refused
  # even if its old grant is still inside its 15 minutes.
  defp stale_epoch?(payload) do
    owner =
      payload["room"]
      |> to_string()
      |> String.split("/", parts: 2)
      |> hd()

    Admission.epoch(owner) != (payload["epoch"] || 0)
  end

  defp suspended_subject?(sub) when is_binary(sub) do
    case Admission.status(sub) do
      {:ok, %{"status" => status}} -> status not in ["approved", "probation", "pending"]
      _ -> false
    end
  end

  defp suspended_subject?(_sub), do: false

  defp valid_members?(nil), do: true

  defp valid_members?(members) when is_list(members) and length(members) <= 32 do
    Enum.all?(members, fn member ->
      is_binary(member) and byte_size(member) > 0 and byte_size(member) <= 64 and
        not String.match?(member, ~r/[[:cntrl:]]/)
    end)
  end

  defp valid_members?(_members), do: false

  defp owner_only(record, requester) do
    if requester.handle == record["handle"], do: :ok, else: {:error, :forbidden}
  end

  defp valid_jti(jti) when is_binary(jti) and byte_size(jti) >= 8, do: :ok
  defp valid_jti(_), do: {:error, :bad_jti}

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp maybe_rental(payload, rental) when is_map(rental),
    do: Map.put(payload, "rental", rental["id"])

  defp maybe_rental(payload, _rental), do: payload

  defp maybe_sub(payload, nil), do: payload
  defp maybe_sub(payload, sub), do: Map.put(payload, "sub", sub)

  # ---- tickets -------------------------------------------------------------

  def issue_ticket(handle, room, requester, body) do
    GenServer.call(__MODULE__, {:issue_ticket, handle, room, requester, body})
  end

  def list_tickets(handle, room), do: GenServer.call(__MODULE__, {:list_tickets, handle, room})

  defp consume_ticket(record, requester, token) do
    cond do
      record["policy"] == "ticket" and not is_binary(token) ->
        {:error, :ticket_required}

      not is_binary(token) ->
        {:ok, nil}

      true ->
        with {:ok, payload} <- verify_grant_token(token),
             :ok <- ticket_kind(payload),
             :ok <- ticket_for_room(payload, record),
             :ok <- ticket_for_subject(payload, requester),
             {:ok, stored} <- ticket_lookup(payload["jti"]),
             :ok <- ticket_usable(stored, requester),
             :ok <- ticket_rental_window(payload, record) do
          :dets.insert(
            @table,
            {{:ticket, payload["jti"]}, Map.put(stored, "uses_left", stored["uses_left"] - 1)}
          )

          {:ok, payload}
        end
    end
  end

  defp ticket_kind(%{"kind" => "ticket"}), do: :ok
  defp ticket_kind(_payload), do: {:error, :bad_ticket}

  defp ticket_for_room(payload, record) do
    if payload["room"] == record["handle"] <> "/" <> record["room"],
      do: :ok,
      else: {:error, :bad_ticket}
  end

  defp ticket_for_subject(%{"bind" => "bearer"}, _requester), do: :ok

  defp ticket_for_subject(payload, requester) do
    if payload["sub"] == requester.handle, do: :ok, else: {:error, :forbidden}
  end

  defp ticket_lookup(jti) do
    case :dets.lookup(@table, {:ticket, jti}) do
      [{{:ticket, ^jti}, stored}] -> {:ok, stored}
      _ -> {:error, :ticket_not_found}
    end
  end

  defp ticket_usable(stored, requester) do
    cond do
      stored["bind"] == "subject" and stored["sub"] != requester.handle -> {:error, :forbidden}
      stored["uses_left"] <= 0 -> {:error, :ticket_spent}
      stored["exp"] <= System.system_time(:second) -> {:error, :expired}
      true -> :ok
    end
  end

  # A ticket minted against a rental is only good while that window is open.
  defp ticket_rental_window(%{"rental" => id}, record) when is_binary(id) do
    case Rentals.active(record["handle"], record["room"]) do
      {:ok, %{"id" => ^id}} -> :ok
      _ -> {:error, :not_open}
    end
  end

  defp ticket_rental_window(_payload, _record), do: :ok

  defp ticket_bind(nil, nil), do: {:ok, "bearer"}
  defp ticket_bind(sub, nil) when is_binary(sub), do: {:ok, "subject"}
  defp ticket_bind(_sub, "bearer"), do: {:ok, "bearer"}
  defp ticket_bind(sub, "subject") when is_binary(sub), do: {:ok, "subject"}
  defp ticket_bind(_sub, "subject"), do: {:error, :bad_subject}
  defp ticket_bind(_sub, _bind), do: {:error, :bad_bind}

  defp ticket_subject(_sub, "bearer"), do: {:ok, nil}
  defp ticket_subject(nil, _bind), do: {:error, :bad_subject}

  defp ticket_subject(sub, _bind) when is_binary(sub) do
    if byte_size(sub) > 0 and byte_size(sub) <= 64 and not String.match?(sub, ~r/[[:cntrl:]]/),
      do: {:ok, sub},
      else: {:error, :bad_subject}
  end

  defp ticket_subject(_sub, _bind), do: {:error, :bad_subject}

  defp ticket_meta(nil), do: {:ok, %{}}

  defp ticket_meta(meta) when is_map(meta) and map_size(meta) <= 10 do
    if Enum.all?(meta, fn {key, value} ->
         is_binary(key) and byte_size(key) <= 64 and is_binary(value) and byte_size(value) <= 200
       end) do
      {:ok, meta}
    else
      {:error, :bad_meta}
    end
  end

  defp ticket_meta(_meta), do: {:error, :bad_meta}

  defp rental_for_ticket(handle, room) do
    case Rentals.active(handle, room) do
      {:ok, rental} when is_map(rental) ->
        {:ok, rental}

      _ ->
        case Rentals.next(handle, room) do
          {:ok, rental} when is_map(rental) -> {:ok, rental}
          _ -> {:ok, nil}
        end
    end
  end

  defp ticket_window(_expires, nil), do: :ok

  defp ticket_window(expires, rental) when is_map(rental) do
    now = System.system_time(:second)

    cond do
      rental["end"] <= now -> {:error, :not_open}
      expires <= now -> {:error, :bad_expires}
      true -> :ok
    end
  end

  defp ticket_caps(nil), do: {:ok, ["join", "publish_audio", "subscribe"]}

  defp ticket_caps(caps) when is_list(caps) do
    caps = Enum.uniq(caps)

    if Enum.all?(caps, &(&1 in @caps)) and "join" in caps do
      {:ok, Enum.sort(caps)}
    else
      {:error, :bad_cap}
    end
  end

  defp ticket_caps(_caps), do: {:error, :bad_cap}

  defp ticket_uses(nil), do: {:ok, 1}
  defp ticket_uses(n) when is_integer(n) and n >= 1 and n <= 100, do: {:ok, n}
  defp ticket_uses(_n), do: {:error, :bad_uses}

  defp ticket_expiry(nil), do: {:ok, System.system_time(:second) + 7 * 86_400}

  defp ticket_expiry(n) when is_integer(n) do
    now = System.system_time(:second)

    if n > now and n <= now + 30 * 86_400,
      do: {:ok, n},
      else: {:error, :bad_expires}
  end

  defp ticket_expiry(_n), do: {:error, :bad_expires}

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
      "scope" => Constructs.scope_id(constructs),
      "advertised" => record["advertised"] == "yes",
      "record" => record
    }

    :dets.insert(@table, {{:room, record["handle"], record["room"]}, head})
  end
end
