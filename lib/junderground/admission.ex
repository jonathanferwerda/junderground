defmodule Junderground.Admission do
  @moduledoc """
  Who may use this switch.

  A house is not admitted by registering; it is admitted by an administrator.
  Registration creates a `pending` entry, and an administrator — a person or an
  agent holding an admin key — moves it along:

      pending ──▶ approved ──▶ probation ──▶ approved
         │            │            │
         ├──▶ rejected│            ├──▶ suspended ──▶ approved
         └──▶ banned  └────────────┴──▶ banned

  `approved` is normal use. `probation` is a real, restricted state: short
  grants, audio only, no recording, no invites. `suspended`, `rejected` and
  `banned` may not write, create rooms or receive grants.

  A registration whose crest key is in `JG_ADMIN_KEYS` is approved at once, so
  the administrator's own house does not sit in its own queue.
  """

  use GenServer

  alias Junderground.Admin

  @table :junderground_admission
  @statuses ~w(pending approved probation suspended rejected banned)
  @writer_statuses ~w(pending approved probation)
  @grant_statuses ~w(approved probation)
  @report_reasons ~w(spam abuse fraud impersonation illegal other)
  @verdicts ~w(clear watch suspend ban)

  # ---- api -----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def statuses, do: @statuses
  def report_reasons, do: @report_reasons
  def verdicts, do: @verdicts

  def pending(handle, pubkey), do: GenServer.call(__MODULE__, {:pending, handle, pubkey})
  def status(handle), do: GenServer.call(__MODULE__, {:status, handle})

  def decide(handle, status, by, reason, review_at) do
    GenServer.call(__MODULE__, {:decide, handle, status, by, reason, review_at})
  end

  def queue, do: GenServer.call(__MODULE__, :queue)
  def audit(since, limit \\ 100), do: GenServer.call(__MODULE__, {:audit, since, limit})

  def report(target, reporter, reason, detail),
    do: GenServer.call(__MODULE__, {:report, target, reporter, reason, detail})

  def reports(since, limit \\ 100), do: GenServer.call(__MODULE__, {:reports, since, limit})

  def review(handle, verdict, by, detail, evidence) do
    GenServer.call(__MODULE__, {:review, handle, verdict, by, detail, evidence})
  end

  def reviews(since, limit \\ 100), do: GenServer.call(__MODULE__, {:reviews, since, limit})

  @doc "The moment this house was last stopped; grants issued before it are dead."
  def revoked_before(handle), do: GenServer.call(__MODULE__, {:revoked_before, handle})

  @doc "Bumped on every stop; a grant carries the epoch it was issued under."
  def epoch(handle), do: GenServer.call(__MODULE__, {:epoch, handle})

  def may_write?(handle), do: status_in?(handle, @writer_statuses)
  def may_create_room?(handle), do: status_in?(handle, ~w(approved))
  def may_grant?(handle), do: status_in?(handle, @grant_statuses)
  def admitted?(handle), do: status_in?(handle, @grant_statuses)
  def probation?(handle), do: status_in?(handle, ~w(probation))

  defp status_in?(handle, allowed) do
    case status(handle) do
      {:ok, record} -> record["status"] in allowed
      _ -> false
    end
  end

  # ---- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.get_env(:junderground, :data_dir, "data"))
    File.mkdir_p!(dir)
    path = Path.join(dir, "admission.dets")

    :dets.close(@table)

    {:ok, _} =
      :dets.open_file(@table,
        file: String.to_charlist(path),
        type: :set,
        auto_save: 2_000
      )

    {:ok,
     %{
       audit_seq: counter(:audit_seq),
       report_seq: counter(:report_seq),
       review_seq: counter(:review_seq)
     }}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @impl true
  def handle_call({:pending, handle, pubkey}, _from, state) do
    case lookup(handle) do
      nil ->
        now = System.system_time(:second)

        {status, reason, by} =
          cond do
            Admin.admin_key?(pubkey) ->
              {"approved", "crest is an administrator key", "system"}

            Application.get_env(:junderground, :auto_approve, false) ->
              {"approved", "auto-approved by configuration", "system"}

            true ->
              {"pending", "awaiting review", ""}
          end

        record = %{
          "handle" => handle,
          "status" => status,
          "first_seen" => now,
          "since" => now,
          "review_at" => 0,
          "reason" => reason,
          "by" => by,
          "crest" => pubkey
        }

        :dets.insert(@table, {{:status, handle}, record})
        {:reply, {:ok, record}, state}

      record ->
        {:reply, {:ok, record}, state}
    end
  end

  def handle_call({:status, handle}, _from, state) do
    case lookup(handle) do
      nil -> {:reply, {:error, :not_found}, state}
      record -> {:reply, {:ok, record}, state}
    end
  end

  def handle_call({:decide, handle, status, by, reason, review_at}, _from, state) do
    case decide_now(handle, status, by, reason, review_at, state) do
      {:ok, record, state} -> {:reply, {:ok, record}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:review, handle, verdict, by, detail, evidence}, _from, state) do
    cond do
      verdict not in @verdicts ->
        {:reply, {:error, :bad_verdict}, state}

      not is_binary(detail) or byte_size(detail) > 4_000 ->
        {:reply, {:error, :bad_detail}, state}

      not is_binary(evidence) or byte_size(evidence) > 4_000 ->
        {:reply, {:error, :bad_evidence}, state}

      true ->
        now = System.system_time(:second)
        n = state.review_seq + 1

        review = %{
          "at" => now,
          "handle" => handle,
          "verdict" => verdict,
          "by" => by || "",
          "detail" => detail,
          "evidence" => evidence
        }

        :dets.insert(@table, [{{:review, n}, review}, {{:meta, :review_seq}, n}])
        state = %{state | review_seq: n}

        case verdict_status(verdict) do
          nil ->
            {:reply, {:ok, %{"review" => review, "admission" => nil}}, state}

          status ->
            case decide_now(handle, status, by, "agent review: " <> verdict, 0, state) do
              {:ok, admission, state} ->
                {:reply, {:ok, %{"review" => review, "admission" => admission}}, state}

              {:error, reason, state} ->
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  def handle_call({:revoked_before, handle}, _from, state) do
    case lookup(handle) do
      nil -> {:reply, 0, state}
      record -> {:reply, record["revoked_before"] || 0, state}
    end
  end

  def handle_call({:epoch, handle}, _from, state) do
    case lookup(handle) do
      nil -> {:reply, 0, state}
      record -> {:reply, record["epoch"] || 0, state}
    end
  end

  def handle_call({:reviews, since, limit}, _from, state) do
    {:reply, {:ok, collect(:review, since, max(limit, 0), state.review_seq)}, state}
  end

  def handle_call(:queue, _from, state) do
    all = list_statuses()
    pending = all |> Enum.filter(&(&1["status"] == "pending")) |> Enum.sort_by(& &1["first_seen"])

    probation =
      all |> Enum.filter(&(&1["status"] == "probation")) |> Enum.sort_by(& &1["review_at"])

    {:reply, %{"pending" => pending, "probation" => probation}, state}
  end

  def handle_call({:audit, since, limit}, _from, state) do
    {:reply, {:ok, collect(:audit, since, max(limit, 0), state.audit_seq)}, state}
  end

  def handle_call({:report, target, reporter, reason, detail}, _from, state) do
    cond do
      not is_binary(target) or target == "" ->
        {:reply, {:error, :bad_handle}, state}

      target == reporter ->
        {:reply, {:error, :self_report}, state}

      reason not in @report_reasons ->
        {:reply, {:error, :bad_reason}, state}

      not is_binary(detail) or byte_size(detail) > 2_000 ->
        {:reply, {:error, :bad_detail}, state}

      true ->
        n = state.report_seq + 1

        record = %{
          "id" => n,
          "at" => System.system_time(:second),
          "handle" => target,
          "by" => reporter,
          "reason" => reason,
          "detail" => detail
        }

        :dets.insert(@table, [{{:report, n}, record}, {{:meta, :report_seq}, n}])
        {:reply, {:ok, record}, %{state | report_seq: n}}
    end
  end

  def handle_call({:reports, since, limit}, _from, state) do
    {:reply, {:ok, collect(:report, since, max(limit, 0), state.report_seq)}, state}
  end

  defp decide_now(handle, status, by, reason, review_at, state) do
    if status not in @statuses do
      {:error, :bad_status, state}
    else
      now = System.system_time(:second)
      existing = lookup(handle)
      stopped = status in ["suspended", "rejected", "banned"]

      record =
        (existing || %{"handle" => handle, "first_seen" => now})
        |> Map.merge(%{
          "handle" => handle,
          "status" => status,
          "since" => now,
          "by" => by || "",
          "reason" => reason || "",
          "review_at" => if(is_integer(review_at), do: review_at, else: 0),
          "revoked_before" =>
            if(stopped, do: now, else: Map.get(existing || %{}, "revoked_before", 0)),
          "epoch" =>
            if(stopped,
              do: Map.get(existing || %{}, "epoch", 0) + 1,
              else: Map.get(existing || %{}, "epoch", 0)
            )
        })

      n = state.audit_seq + 1

      :dets.insert(@table, [
        {{:status, handle}, record},
        {{:audit, n},
         %{
           "at" => now,
           "handle" => handle,
           "status" => status,
           "by" => by || "",
           "reason" => reason || "",
           "review_at" => record["review_at"]
         }},
        {{:meta, :audit_seq}, n}
      ])

      {:ok, record, %{state | audit_seq: n}}
    end
  end

  defp verdict_status("watch"), do: "probation"
  defp verdict_status("suspend"), do: "suspended"
  defp verdict_status("ban"), do: "banned"
  defp verdict_status(_clear), do: nil

  # ---- storage -------------------------------------------------------------

  defp lookup(handle) do
    case :dets.lookup(@table, {:status, handle}) do
      [{{:status, ^handle}, record}] -> record
      _ -> nil
    end
  end

  defp list_statuses do
    :dets.select(@table, [{{{:status, :_}, :"$1"}, [], [:"$1"]}])
  end

  defp counter(name) do
    case :dets.lookup(@table, {:meta, name}) do
      [{{:meta, ^name}, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  defp collect(_kind, _since, limit, _top) when limit <= 0, do: []
  defp collect(_kind, since, _limit, top) when since >= top, do: []

  defp collect(kind, since, limit, top) do
    last = min(since + limit, top)

    (since + 1)..last
    |> Enum.reduce([], fn n, acc ->
      case :dets.lookup(@table, {kind, n}) do
        [{{^kind, ^n}, record}] -> [record | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end
end
