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
end
