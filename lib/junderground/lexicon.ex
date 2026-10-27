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

  # The interface languages jawnos ships. The switch's own language is the
  # administrator's: it decides the *name* shown for a slug, never the slug
  # itself, so a later language change cannot split a room that already exists.
  @languages ~w(en zh fr es de pt hi ar bn ru ja pa id ko it tr)

  @names %{
    "events" => %{
      "christmas" => %{
        "en" => "Christmas",
        "zh" => "圣诞节",
        "fr" => "Noël",
        "es" => "Navidad",
        "de" => "Weihnachten",
        "pt" => "Natal",
        "hi" => "क्रिसमस",
        "ar" => "عيد الميلاد",
        "bn" => "বড়দিন",
        "ru" => "Рождество",
        "ja" => "クリスマス",
        "pa" => "ਕ੍ਰਿਸਮਸ",
        "id" => "Natal",
        "ko" => "크리스마스",
        "it" => "Natale",
        "tr" => "Noel"
      },
      "new_year" => %{
        "en" => "New Year",
        "zh" => "新年",
        "fr" => "Nouvel An",
        "es" => "Año Nuevo",
        "de" => "Neujahr",
        "pt" => "Ano Novo",
        "hi" => "नया साल",
        "ar" => "رأس السنة",
        "bn" => "নববর্ষ",
        "ru" => "Новый год",
        "ja" => "お正月",
        "pa" => "ਨਵਾਂ ਸਾਲ",
        "id" => "Tahun Baru",
        "ko" => "새해",
        "it" => "Capodanno",
        "tr" => "Yılbaşı"
      },
      "halloween" => %{
        "en" => "Halloween",
        "zh" => "万圣节",
        "fr" => "Halloween",
        "es" => "Halloween",
        "de" => "Halloween",
        "pt" => "Halloween",
        "ru" => "Хэллоуин",
        "ja" => "ハロウィン",
        "ko" => "할로윈",
        "it" => "Halloween"
      }
    }
  }

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

  @doc "The administrator's language."
  def language, do: GenServer.call(__MODULE__, :language)

  @doc "The 16 interface languages the switch will accept as its own."
  def languages, do: @languages

  def set_language(lang), do: GenServer.call(__MODULE__, {:set_language, lang})

  @doc "Like `scope/1`, but also says which values the lexicon did not know."
  def scope_detail(scope), do: GenServer.call(__MODULE__, {:scope_detail, scope})

  @doc "The display word for each canonical value, in the switch's language."
  def names(scope), do: GenServer.call(__MODULE__, {:names, scope})

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
    |> then(fn table ->
      language =
        case :dets.lookup(@table, {:setting, :language}) do
          [{{:setting, :language}, lang}] when is_binary(lang) and lang != "" -> lang
          _ -> Application.get_env(:junderground, :language, "en")
        end

      {:ok, %{table: table, language: language}}
    end)
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

  def handle_call(:language, _from, state), do: {:reply, state.language, state}

  def handle_call({:set_language, lang}, _from, state) do
    key = lang |> to_string() |> String.downcase()

    if key in @languages do
      :dets.insert(@table, {{:setting, :language}, key})
      {:reply, {:ok, key}, %{state | language: key}}
    else
      {:reply, {:error, :bad_language}, state}
    end
  end

  def handle_call({:scope_detail, scope}, _from, state) do
    {canonical, unknown} =
      Enum.reduce(scope, {%{}, %{}}, fn {kind, value}, {canon, unk} ->
        key = normalize(value)

        case Map.get(state.table, {kind, key}) do
          nil -> {Map.put(canon, kind, key), Map.put(unk, kind, value)}
          slug -> {Map.put(canon, kind, slug), unk}
        end
      end)

    {:reply, {canonical, unknown}, state}
  end

  def handle_call({:names, scope}, _from, state) do
    names = Map.new(scope, fn {kind, slug} -> {kind, display_name(kind, slug, state.language)} end)
    {:reply, names, state}
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

  defp display_name(kind, slug, language) do
    words = get_in(@names, [kind, slug])

    cond do
      is_map(words) -> Map.get(words, language) || Map.get(words, "en") || slug
      true -> slug
    end
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
