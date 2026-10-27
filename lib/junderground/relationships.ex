defmodule Junderground.Relationships do
  @moduledoc """
  The reference rule for grading a room by who is in it.

  **This runs in the house, not in the switch.** The switch hands a client the
  room's roster (`GET /v1/rooms/:handle/:room/presence`); the client compares it
  with the relationships it already keeps — the people list, the Box Office
  blacklist, a hostile mark — and decides what to show before the room opens.
  The switch never receives the relationship map, which is why there is no
  grading endpoint here.

  jawnos should mirror these rules so the phone and the desktop agree:

    * any blacklisted subject  → `hostile`, flag `blacklisted`
    * any hostile subject      → `hostile`, flag `hostile`
    * every subject unknown    → `strangers`, flag `stranger`
    * some unknown             → `mixed`, flag `stranger`
    * all known, some trusted  → `known`
    * all trusted              → `trusted`
    * nobody in the room       → `empty`

  A `blacklisted` flag is the one that must block the open, even when everyone
  else in the room is a friend: a room is only as safe as the person you cannot
  see.
  """

  @levels ~w(trusted known mixed strangers hostile empty)
  @known ~w(friend family colleague trusted contact)

  def levels, do: @levels

  @doc """
  Grade `roster` (a list of presence entries) against `relationships`
  (`%{handle => relation}`).

  A relation is `"blacklist"`, `"hostile"`, one of `#{inspect(@known)}`, or
  anything else for "known". A handle missing from the map is a stranger.
  """
  def grade(roster, relationships) when is_list(roster) and is_map(relationships) do
    subjects =
      roster
      |> Enum.map(& &1["subject"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    counts = count(subjects, relationships)
    flags = flags(relationships, subjects, counts)
    level = level(relationships, subjects, counts, flags)

    %{
      "grade" => level,
      "flags" => flags,
      "block" => "blacklisted" in flags,
      "counts" => counts,
      "subjects" => subjects
    }
  end

  defp count(subjects, relationships) do
    Enum.reduce(
      subjects,
      %{"trusted" => 0, "known" => 0, "blacklisted" => 0, "hostile" => 0, "unknown" => 0},
      fn subject, acc ->
        case Map.get(relationships, subject) do
          "blacklist" -> Map.update!(acc, "blacklisted", &(&1 + 1))
          "hostile" -> Map.update!(acc, "hostile", &(&1 + 1))
          nil -> Map.update!(acc, "unknown", &(&1 + 1))
          relation when relation in @known -> Map.update!(acc, "trusted", &(&1 + 1))
          _ -> Map.update!(acc, "known", &(&1 + 1))
        end
      end
    )
  end

  defp flags(_relationships, _subjects, counts) do
    [
      if(counts["blacklisted"] > 0, do: "blacklisted"),
      if(counts["hostile"] > 0, do: "hostile"),
      if(counts["unknown"] > 0, do: "stranger")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp level(_relationships, subjects, counts, flags) do
    cond do
      subjects == [] -> "empty"
      "blacklisted" in flags -> "hostile"
      "hostile" in flags -> "hostile"
      counts["unknown"] == length(subjects) -> "strangers"
      counts["unknown"] > 0 -> "mixed"
      counts["trusted"] == length(subjects) -> "trusted"
      true -> "known"
    end
  end
end
