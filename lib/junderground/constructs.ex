defmodule Junderground.Constructs do
  @moduledoc """
  The social constructs a dial is made of, and the matching rule.

  The eleven kinds are the same ones jawnos uses in `gb.pl`, but a dial here is
  **partial**: a construct that is not named is not "the default", it is
  *undefined*. That is the difference between a universal room and a specific
  one:

      {event: "christmas"}                                  → anyone dialling Christmas
      {communities: "warwick", event: "rock_show", teams: "the_greatest_band"}
                                                            → only that show

  A room matches a viewer when **every construct the room defines** is present
  in the viewer's dial with the same value. The viewer may have more. An empty
  room scope matches every dial (a house lobby).

  This deliberately differs from the Mail app's `mail_channel_key`, which fills
  missing constructs with defaults. jawnos' dial should adopt the same
  partial-scope rule so the two sides agree.
  """

  @kinds [
    %{"name" => "communities", "sing" => "community", "def" => "local", "order" => 0},
    %{"name" => "clubs", "sing" => "club", "def" => "peers", "order" => 1},
    %{"name" => "teams", "sing" => "team", "def" => "family", "order" => 2},
    %{"name" => "people", "sing" => "person", "def" => "self", "order" => 3},
    %{"name" => "projects", "sing" => "project", "def" => "life", "order" => 4},
    %{"name" => "institutions", "sing" => "institution", "def" => "house", "order" => 5},
    %{"name" => "governments", "sing" => "government", "def" => "civic", "order" => 6},
    %{"name" => "corporations", "sing" => "corporation", "def" => "sole", "order" => 7},
    %{"name" => "places", "sing" => "place", "def" => "home", "order" => 8},
    %{"name" => "vendors", "sing" => "vendor", "def" => "market", "order" => 9},
    %{"name" => "events", "sing" => "event", "def" => "now", "order" => 10}
  ]

  @names Enum.map(@kinds, & &1["name"])
  @suggestions Map.new(@kinds, fn kind -> {kind["name"], kind["def"]} end)
  @max_value 120

  def kinds, do: @kinds
  def names, do: @names
  def max_value, do: @max_value

  @doc "The values to *suggest* in a dial UI; they are not applied to a room."
  def suggestions, do: @suggestions

  @doc """
  Keep only the constructs that are defined. `""`, `nil` and a missing key all
  mean the same thing: not part of the scope.
  """
  def normalize(nil), do: {:ok, %{}}

  def normalize(input) when is_map(input) do
    scope =
      input
      |> Enum.reject(fn {_name, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    if Enum.all?(scope, fn {name, value} ->
         is_binary(name) and name in @names and is_binary(value) and
           byte_size(value) <= @max_value
       end) do
      {:ok, scope}
    else
      {:error, :bad_constructs}
    end
  end

  def normalize(_input), do: {:error, :bad_constructs}

  @doc "A stable id for a room's scope (SHA-256 hex over the defined pairs)."
  def scope_id(scope) when is_map(scope) do
    pairs =
      scope
      |> Enum.sort()
      |> Enum.map_join(<<0x1F>>, fn {name, value} -> name <> "=" <> value end)

    :crypto.hash(:sha256, "jg-scope-v1" <> <<0>> <> pairs)
    |> Base.encode16(case: :lower)
  end

  @doc "True when every construct the room defines is in the viewer's dial."
  def matches?(room_scope, dial) when is_map(room_scope) and is_map(dial) do
    Enum.all?(room_scope, fn {name, value} -> Map.get(dial, name) == value end)
  end
end
