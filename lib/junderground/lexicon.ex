defmodule Junderground.Lexicon do
  @moduledoc """
  Canonical room vocabulary.

  A room's construct values are **canonical slugs**, and a dial may use a
  language's own word for it. `Lexicon` maps the aliases back to the slug, so
  `events=christmas`, `events=圣诞节`, `events=navidad`, `events=weihnachten`
  and `events=Χριστούγεννα` all name the same room.

  The seed is deliberately small and shared: it is a compatibility contract
  between jundergrounds, so two switches agree on what Christmas is called.
  A room may add its own aliases in the signed record (`"aliases"`), but an
  alias that already means something else is refused by first-wins ordering.
  Display names and in-room translation stay with the house's Guide; the switch
  only decides identity.
  """

  use GenServer

  @table :junderground_lexicon

  @seed %{
    "events" => %{
      "christmas" => [
        "christmas",
        "xmas",
        "noel",
        "navidad",
        "weihnachten",
        "natal",
        "natale",
        "圣诞节",
        "聖誕節",
        "クリスマス",
        "크리스마스",
        "рождество",
        "χριστούγεννα",
        "क्रिसमस",
        "عيد الميلاد",
        "বড়দিন",
        "ਕ੍ਰਿਸਮਸ"
      ],
      "new_year" => [
        "new_year",
        "new year",
        "ano nuevo",
        "año nuevo",
        "neujahr",
        "anno nuovo",
        "новый год",
        "新年",
        "お正月",
        "새해",
        "naya saal",
        "رأس السنة"
      ],
      "halloween" => [
        "halloween",
        "хэллоуин",
        "万圣节",
        "ハロウィン",
        "할로윈"
      ]
    }
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def canonical(kind, value), do: GenServer.call(__MODULE__, {:canonical, kind, value})
  def scope(scope), do: GenServer.call(__MODULE__, {:scope, scope})
  def all, do: GenServer.call(__MODULE__, :all)

  def learn(kind, canonical, aliases),
    do: GenServer.call(__MODULE__, {:learn, kind, canonical, aliases})

  @doc "A normalized lookup key: no case, accents, or separator noise."
  def normalize(value) when is_binary(value) do
    value
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}+/u, "")
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.replace(~r/[\s_\-]+/u, "_")
    |> String.trim("_")
  end

  def normalize(_value), do: ""

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.get_env(:junderground, :data_dir, "data"))
    File.mkdir_p!(dir)
    path = Path.join(dir, "lexicon.dets")

    :dets.close(@table)

    {:ok, _} =
      :dets.open_file(@table, file: String.to_charlist(path), type: :set, auto_save: 2_000)

    table = build_table(@seed)

    # Anything an administrator added lives in DETS and wins over the seed.
    :dets.foldl(
      fn
        {{:alias, kind, alias_key}, canonical}, acc ->
          Map.put(acc, {kind, alias_key}, canonical)

        _other, acc ->
          acc
      end,
      table,
      @table
    )
    |> then(&{:ok, %{table: &1}})
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @impl true
  def handle_call({:canonical, kind, value}, _from, state) do
    key = normalize(value)
    {:reply, Map.get(state.table, {kind, key}, key), state}
  end

  def handle_call({:scope, scope}, _from, state) do
    canonical =
      Map.new(scope, fn {kind, value} ->
        key = normalize(value)
        {kind, Map.get(state.table, {kind, key}, key)}
      end)

    {:reply, canonical, state}
  end

  def handle_call(:all, _from, state) do
    grouped =
      Enum.reduce(state.table, %{}, fn {kind, canonical}, acc ->
        Map.update(acc, kind, %{canonical => []}, fn m ->
          Map.update(m, canonical, [], & &1)
        end)
      end)

    {:reply, grouped, state}
  end

  def handle_call({:learn, kind, canonical, aliases}, _from, state) do
    {table, added} =
      Enum.reduce(List.wrap(aliases), {state.table, 0}, fn alias, {table, n} ->
        key = normalize(alias)

        cond do
          key == "" ->
            {table, n}

          Map.has_key?(table, {kind, key}) ->
            {table, n}

          true ->
            :dets.insert(@table, {{:alias, kind, key}, canonical})
            {Map.put(table, {kind, key}, canonical), n + 1}
        end
      end)

    {:reply, {:ok, added}, %{state | table: table}}
  end

  defp build_table(seed) do
    Enum.reduce(seed, %{}, fn {kind, canonicals}, acc ->
      Enum.reduce(canonicals, acc, fn {canonical, aliases}, acc ->
        Enum.reduce([canonical | aliases], acc, fn alias, acc ->
          key = normalize(alias)
          if key == "", do: acc, else: Map.put_new(acc, {kind, key}, canonical)
        end)
      end)
    end)
  end
end
