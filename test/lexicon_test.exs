# tests-for: lib/junderground/lexicon.ex lib/junderground/constructs.ex
defmodule Junderground.LexiconTest do
  use ExUnit.Case, async: false

  alias Junderground.Lexicon

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-lex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    start_supervised!({Lexicon, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  test "Christmas is one room in many languages" do
    for word <- [
          "christmas",
          "Christmas",
          "Xmas",
          "Noël",
          "noel",
          "navidad",
          "Navidad",
          "weihnachten",
          "Weihnachten",
          "圣诞节",
          "クリスマス",
          "크리스마스",
          "рождество",
          "Χριστούγεννα",
          "χριστουγεννα",
          "عيد الميلاد",
          "বড়দিন",
          "क्रिसमस",
          "ਕ੍ਰਿਸਮਸ"
        ] do
      assert Lexicon.canonical("events", word) == "christmas", "failed for #{word}"
    end
  end

  test "new year and case/separator noise normalize" do
    assert Lexicon.canonical("events", "New Year") == "new_year"
    assert Lexicon.canonical("events", "new-year") == "new_year"
    assert Lexicon.canonical("events", "Año Nuevo") == "new_year"
  end

  test "a scope is canonicalized as a whole" do
    assert Lexicon.scope(%{"events" => "Navidad", "communities" => "Harbour"}) == %{
             "events" => "christmas",
             "communities" => "harbour"
           }
  end

  test "a room alias is learned, first wins" do
    assert {:ok, 1} = Lexicon.learn("events", "rock_show", ["le_spectacle"])
    assert Lexicon.canonical("events", "Le Spectacle") == "rock_show"
    assert {:ok, 0} = Lexicon.learn("events", "something_else", ["le_spectacle"])
    assert Lexicon.canonical("events", "le spectacle") == "rock_show"
  end

  test "the administrator's language names the room, not its identity" do
    assert Lexicon.language() == "en"
    assert Lexicon.names(%{"events" => "christmas"}) == %{"events" => "Christmas"}

    assert {:ok, "de"} = Lexicon.set_language("de")

    assert Lexicon.names(%{"events" => "christmas", "communities" => "munich"}) ==
             %{"events" => "Weihnachten", "communities" => "munich"}

    # identity never moves with the language
    assert Lexicon.canonical("events", "Weihnachten") == "christmas"
    assert Lexicon.scope(%{"events" => "圣诞节"}) == %{"events" => "christmas"}
  end

  test "a value the lexicon does not know is reported, not hidden" do
    assert {canonical, unknown} =
             Lexicon.scope_detail(%{"events" => "Christmas", "communities" => "München"})

    assert canonical == %{"events" => "christmas", "communities" => "munchen"}
    assert unknown == %{"communities" => "München"}
  end

  test "an unknown language is refused" do
    assert {:error, :bad_language} = Lexicon.set_language("klingon")
  end
end
