# tests-for: lib/junderground/relationships.ex
defmodule Junderground.RelationshipsTest do
  use ExUnit.Case, async: true

  alias Junderground.Relationships

  defp roster(handles), do: Enum.map(handles, &%{"subject" => &1})

  test "a blacklisted person blocks the room even among friends" do
    result =
      Relationships.grade(roster(["alice", "mallory"]), %{
        "alice" => "friend",
        "mallory" => "blacklist"
      })

    assert result["grade"] == "hostile"
    assert result["block"] == true
    assert "blacklisted" in result["flags"]
    assert result["counts"]["blacklisted"] == 1
  end

  test "hostile is a warning without the blacklist block" do
    result = Relationships.grade(roster(["bob"]), %{"bob" => "hostile"})
    assert result["grade"] == "hostile"
    assert result["block"] == false
  end

  test "all friends is trusted" do
    assert %{"grade" => "trusted"} =
             Relationships.grade(roster(["a", "b"]), %{"a" => "family", "b" => "friend"})
  end

  test "a stranger among friends is mixed" do
    result = Relationships.grade(roster(["a", "z"]), %{"a" => "friend"})
    assert result["grade"] == "mixed"
    assert "stranger" in result["flags"]
  end

  test "all strangers" do
    assert %{"grade" => "strangers", "flags" => ["stranger"]} =
             Relationships.grade(roster(["x", "y"]), %{})
  end

  test "an empty room" do
    assert %{"grade" => "empty", "flags" => []} = Relationships.grade([], %{})
  end
end
