# tests-for: scripts/jg_index.exs
defmodule JGTool.IndexTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.expand("../../scripts/jg_index.exs", __DIR__))

  alias JGTool.Index

  test "the parsed tree is clean and has the expected shape" do
    assert Index.parse_errors() == []
    assert length(Index.modules()) == 31
    assert length(Index.routes()) == 54
    assert length(Index.stores()) == 9
    assert map_size(Index.settings()) == 21

    # The 18 application test files are what this repo ships; tooling tests
    # live under test/tooling/ and are counted too. Other agents may add
    # tooling tests concurrently, so assert the 18 rather than a brittle
    # grand total, and check the index covers every test file on disk.
    application_tests =
      Enum.reject(Index.tests(), &String.starts_with?(&1.file, "test/tooling/"))

    assert length(application_tests) == 18

    on_disk =
      Path.wildcard(Path.join(Index.root(), "test/**/*_test.exs"))
      |> Enum.map(&Path.relative_to(&1, Index.root()))

    indexed = Index.tests() |> Enum.map(& &1.file)
    assert Enum.all?(on_disk, &(&1 in indexed))
  end

  test "a function lookup resolves its file, line and arity" do
    assert [{module, definition}] = Index.def_hits("Rooms.grant")

    assert module.file == "lib/junderground/rooms.ex"
    assert definition.line == 75
    assert 4 in definition.arities
  end

  test "a route lookup carries its line and the calls its body makes" do
    assert [route] = Index.route_hits("POST /v1/rooms/:handle/:room/token")

    assert route.line == 411

    assert Enum.any?(route.calls, fn call ->
             call.module == "Junderground.Rooms" and call.fun == "grant" and call.arity == 4
           end)
  end

  test "an error atom joins its status clause to its producers" do
    error = Index.error(:ticket_spent)

    assert error.status == 409
    assert error.status_line == 1247
  end

  test "a setting joins its config entry to the code that reads it" do
    setting = Index.setting("JG_SFU_URL")

    assert setting.env == "JG_SFU_URL"
    assert setting.config_line == 21
    assert setting.readers != []
  end

  test "a DETS store resolves to its file, table and module" do
    assert [store] = Index.store("rooms.dets")
    assert store.table == :junderground_rooms
    assert store.module == "Junderground.Rooms"
  end

  test "Markdown headings are indexed with their line and anchor" do
    assert Enum.any?(Index.docs_named("8. Grants and capabilities"), fn doc ->
             doc.file == "docs/API.md" and doc.line == 947
           end)
  end

  test "every application test file claims at least one source file" do
    application_tests =
      Enum.reject(Index.tests(), &String.starts_with?(&1.file, "test/tooling/"))

    unclaimed =
      application_tests
      |> Enum.reject(&(&1.claims != []))
      |> Enum.map(& &1.file)

    assert unclaimed == []

    # These two tooling tests carry their own headers; other agents' tooling
    # tests are outside this claim set.
    for file <- ["test/tooling/index_test.exs", "test/tooling/where_test.exs"] do
      assert Enum.any?(Index.tests(), &(&1.file == file and &1.claims != []))
    end
  end
end
