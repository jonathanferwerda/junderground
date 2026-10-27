defmodule Junderground.Constructs do
  @moduledoc """
  The social constructs a dial is made of.

  These are the same eleven kinds, defaults and order jawnos uses in `gb.pl`'s
  `%social_constructs`, so a dial here names the same room a Mail/Chat dial
  names:

      communities=local  clubs=peers  teams=family  people=self
      projects=life      institutions=house  governments=civic
      corporations=sole  places=home  vendors=market  events=now

  A dial is one value per kind. The channel string is the values in sorted kind
  order joined by `0x1f` — byte-identical to `mail_channel_key` in jawnos — and
  the channel id is its SHA-256 hex, which is what records and lookups carry.
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
  @defaults Map.new(@kinds, fn kind -> {kind["name"], kind["def"]} end)
  @max_value 120

  def kinds, do: @kinds
  def names, do: @names
  def defaults, do: @defaults
  def max_value, do: @max_value

  @doc "Fill the kinds a dial did not name with their defaults."
  def normalize(nil), do: {:ok, @defaults}

  def normalize(input) when is_map(input) do
    if Enum.all?(input, fn {name, value} ->
         is_binary(name) and name in @names and is_binary(value) and
           byte_size(value) <= @max_value
       end) do
      {:ok, Map.merge(@defaults, input)}
    else
      {:error, :bad_constructs}
    end
  end

  def normalize(_input), do: {:error, :bad_constructs}

  @doc "The Mail-compatible channel string: values in sorted kind order, joined by 0x1f."
  def channel(constructs) when is_map(constructs) do
    full = Map.merge(@defaults, constructs)

    @names
    |> Enum.sort()
    |> Enum.map_join(<<0x1F>>, fn name -> Map.fetch!(full, name) end)
  end

  @doc "A compact, URL-safe identity for a channel (SHA-256 hex)."
  def channel_id(constructs) when is_map(constructs) do
    :crypto.hash(:sha256, channel(constructs)) |> Base.encode16(case: :lower)
  end
end
