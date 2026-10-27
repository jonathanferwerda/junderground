defmodule Junderground.PresenceTest do
  use ExUnit.Case, async: false

  alias Junderground.Presence

  setup do
    start_supervised!(Presence)
    :ok
  end

  test "join, roster and leave" do
    assert {:ok, entry, roster} = Presence.join("alpha/lobby", "alpha", ["join"], "jti-1", 60)
    assert entry["subject"] == "alpha"
    assert length(roster) == 1

    {:ok, _entry2, roster} = Presence.join("alpha/lobby", "beta", ["join"], "jti-2", 60)
    assert Enum.map(roster, & &1["subject"]) |> Enum.sort() == ["alpha", "beta"]

    assert {:error, :forbidden} = Presence.leave("alpha/lobby", entry["id"], "beta")
    assert :ok = Presence.leave("alpha/lobby", entry["id"], "alpha")

    {:ok, roster} = Presence.roster("alpha/lobby")
    assert Enum.map(roster, & &1["subject"]) == ["beta"]
  end

  test "an entry expires on its own" do
    {:ok, _entry, _roster} = Presence.join("alpha/lobby", "alpha", ["join"], "jti-3", 1)
    Process.sleep(1_100)
    assert {:ok, []} = Presence.roster("alpha/lobby")
  end

  test "a non-ticketed entry is evicted; a ticketed one stays" do
    now = System.system_time(:second)

    {:ok, _a, _} =
      Presence.join("alpha/lobby", "alpha", ["join"], "jti-evict", 60, %{
        "ticketed" => false,
        "notify_at" => now + 1,
        "evict_at" => now + 1
      })

    {:ok, _b, _} =
      Presence.join("alpha/lobby", "beta", ["join"], "jti-stay", 60, %{"ticketed" => true})

    Process.sleep(1_100)
    {:ok, roster} = Presence.roster("alpha/lobby")

    assert Enum.map(roster, & &1["subject"]) == ["beta"]
    assert hd(roster)["ticketed"] == true
  end
end
