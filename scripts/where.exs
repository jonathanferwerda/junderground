# Where does a name live? One line, instead of reading a 1,000-line router or
# grepping nine modules to find one function.
#
#   elixir scripts/where.exs Rooms.grant
#   elixir scripts/where.exs "POST /v1/rooms/:handle/:room/token"
#   elixir scripts/where.exs :ticket_spent
#   elixir scripts/where.exs sfu_url
#   elixir scripts/where.exs docs/API.md#8-grants-and-capabilities
#   elixir scripts/where.exs lib/junderground/rooms.ex
#   elixir scripts/where.exs --outline lib/junderground/router.ex
#
# The index is read from the tree, never loaded: scripts/jg_index.exs parses
# Elixir with Code.string_to_quoted/2, so this works even when the project does
# not compile. It never boots the app or opens DETS.

Code.require_file("jg_index.exs", __DIR__)

defmodule JGTool.Where do
  alias JGTool.Index

  def main(argv) do
    {opts, names, invalid} =
      OptionParser.parse(argv,
        strict: [
          terse: :boolean,
          context: :integer,
          limit: :integer,
          outline: :string,
          body: :boolean,
          json: :boolean,
          help: :boolean,
          no_log: :boolean
        ]
      )

    cond do
      invalid != [] ->
        usage(2)

      opts[:help] ->
        usage(0)

      is_binary(opts[:outline]) ->
        outline(opts[:outline], opts)

      names == [] ->
        usage(2)

      true ->
        names = join_route_args(names)

        {hits, misses} =
          Enum.reduce(names, {[], []}, fn name, {hits, misses} ->
            case lookup(name) do
              [] -> {hits, misses ++ [name]}
              found -> {hits ++ found, misses}
            end
          end)

        print(hits, opts)
        for name <- misses, do: miss(name, opts)

        if hits == [] do
          System.halt(1)
        else
          System.halt(0)
        end
    end
  end

  # ---- resolution ---------------------------------------------------------

  def lookup(name) do
    name = String.trim(to_string(name))

    if name == "" do
      []
    else
      some([
        fn -> route_hits(Index.route_hits(name)) end,
        fn -> module_hits(Index.modules_named(name)) end,
        fn -> def_hits(Index.def_hits(name)) end,
        fn -> setting_hits(Index.setting(name)) end,
        fn -> store_hits(Index.store(name)) end,
        fn -> error_hits(Index.error(name)) end,
        fn -> doc_hits(name) end,
        fn -> test_hits(name) end,
        fn -> file_hits(name) end
      ]) || mention_hits(name, 8)
    end
  end

  defp some(funs) do
    Enum.find_value(funs, fn fun ->
      case fun.() do
        nil -> nil
        [] -> nil
        value -> value
      end
    end)
  end

  defp join_route_args([method, path | rest]) when method in ~w(GET POST PUT DELETE PATCH ANY) do
    if String.starts_with?(path, "/") do
      [method <> " " <> path | rest]
    else
      [method, path | rest]
    end
  end

  defp join_route_args(names), do: names

  defp route_hits(routes) do
    Enum.map(routes, fn r ->
      file = module_file(r.module) || "lib/junderground/router.ex"

      %{
        kind: :route,
        file: file,
        line: r.line,
        end_line: r.end_line,
        label: "#{r.method} #{r.path}" <> route_call_label(r.calls)
      }
    end)
  end

  defp route_call_label([]), do: ""
  defp route_call_label(calls) do
    names =
      calls
      |> Enum.filter(&String.starts_with?(&1.module, "Junderground."))
      |> Enum.map(&"#{short_module(&1.module)}.#{&1.fun}/#{&1.arity}")
      |> Enum.uniq()
      |> Enum.take(4)

    case names do
      [] -> ""
      _ -> "  -> " <> Enum.join(names, ", ")
    end
  end

  defp module_hits(modules) do
    Enum.map(modules, fn m ->
      %{
        kind: :module,
        file: m.file,
        line: m.line,
        end_line: m.end_line,
        label:
          "module #{m.name} (#{Enum.count(m.defs, &(&1.kind == :def))} public, " <>
            "#{Enum.count(m.defs, &(&1.kind == :defp))} private)",
        extra: module_extra(m)
      }
    end)
  end

  defp module_extra(m) do
    topics =
      Index.topics_for_module(m.name)
      |> Enum.map(& &1.id)

    routes = Index.routes_for_module(m.name) |> length()

    [
      if(topics != [], do: "topics: " <> Enum.join(topics, ", ")),
      if(routes > 0, do: "routes reaching it: #{routes}")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp def_hits(defs) do
    Enum.map(defs, fn {m, d} ->
      arities =
        case d.arities do
          [one] -> "#{one}"
          many -> Enum.join(many, ",")
        end

      %{
        kind: :function,
        file: m.file,
        line: d.line,
        end_line: d.end_line,
        label: "#{short_module(m.name)}.#{d.name}/#{arities}",
        extra: if(d.doc, do: ["doc: " <> first_line(d.doc)], else: [])
      }
    end)
  end

  defp setting_hits(nil), do: []

  defp setting_hits(setting) do
    base =
      if setting.config_file do
        [
          %{
            kind: :setting,
            file: setting.config_file,
            line: setting.config_line,
            label:
              "setting :#{setting.key}" <>
                if(setting.env, do: " (#{setting.env})", else: "")
          }
        ]
      else
        []
      end

    readers =
      Enum.map(setting.readers, fn r ->
        %{
          kind: :reader,
          file: r.file,
          line: r.line,
          label: "reader of :#{setting.key} in #{short_module(r.module)}"
        }
      end)

    readme =
      case setting.readme do
        nil ->
          []

        row ->
          [
            %{
              kind: :doc,
              file: row.file,
              line: row.line,
              label: "config table: #{row.env}"
            }
          ]
      end

    base ++ readers ++ readme
  end

  defp store_hits(stores) do
    Enum.map(stores, fn s ->
      table = if s.table, do: " table #{inspect(s.table)}", else: ""

      %{
        kind: :store,
        file: s.source,
        line: s.line,
        label: "#{s.file}#{table} (#{short_module(s.module)})"
      }
    end)
  end

  defp error_hits(nil), do: []

  defp error_hits(error) do
    status =
      if error.status do
        " -> #{error.status}"
      else
        " (no status_for clause)"
      end

    head =
      %{
        kind: :error,
        file: error.status_file || "lib/junderground/router.ex",
        line: error.status_line || 1,
        label: ":#{error.atom}#{status}"
      }

    producers =
      Enum.map(error.producers, fn p ->
        %{
          kind: :error_producer,
          file: p.file,
          line: p.line,
          label: "producer in #{short_module(p.module)}"
        }
      end)

    [head | producers]
  end

  defp doc_hits(name) do
    cond do
      String.contains?(name, "#") and String.starts_with?(name, "docs/") ->
        [file, anchor] = String.split(name, "#", parts: 2)

        Index.docs()
        |> Enum.filter(&(&1.file == file and &1.anchor == anchor))
        |> Enum.map(&doc_hit/1)

      String.ends_with?(name, ".md") and File.exists?(Path.join(Index.root(), name)) ->
        file_hits(name)

      true ->
        exact = Index.docs_named(name)
        found = if exact == [], do: Index.docs_containing(name), else: exact

        case found do
          [] -> nil
          docs -> Enum.map(docs, &doc_hit/1)
        end
    end
  end

  defp doc_hit(doc) do
    routes =
      case doc.routes do
        [] -> []
        list -> ["routes: " <> Enum.map_join(list, ", ", &"#{&1.method} #{&1.path}")]
      end

    %{
      kind: :doc,
      file: doc.file,
      line: doc.line,
      label: "#{doc.title} (##{doc.anchor})",
      extra: routes
    }
  end

  defp test_hits(name) do
    tests = Index.tests()

    found =
      cond do
        String.starts_with?(name, "test/") ->
          Enum.filter(tests, &(&1.file == name))

        String.ends_with?(name, "_test.exs") ->
          Enum.filter(tests, &(Path.basename(&1.file) == name))

        true ->
          Enum.filter(tests, &(&1.module == name))
      end

    case found do
      [] ->
        nil

      list ->
        Enum.map(list, fn t ->
          %{
            kind: :test,
            file: t.file,
            line: t.line,
            label: "#{t.module || "test"} (#{length(t.tests)} test cases)",
            extra:
              if(t.claims == [],
                do: ["no # tests-for: header"],
                else: ["tests-for: " <> Enum.join(t.claims, " ")]
              )
          }
        end)
    end
  end

  defp file_hits(name) do
    path = Path.join(Index.root(), name)

    if File.exists?(path) and File.regular?(path) do
      rel = Path.relative_to(path, Index.root())

      case Index.modules_for_file(rel) do
        [] ->
          reverse_file_hits(rel)

        modules ->
          Enum.flat_map(modules, &module_hits([&1])) ++
            topic_hits(rel) ++
            test_hits_for(rel)
      end
    else
      nil
    end
  end

  defp reverse_file_hits(rel) do
    case Enum.find(Index.help(), fn {_id, topic} -> topic.file == rel end) do
      {_id, topic} ->
        [
          %{
            kind: :file,
            file: rel,
            line: 1,
            label: "help topic '#{topic.id}' - #{topic.title}"
          }
        ]

      nil ->
        cond do
          String.ends_with?(rel, ".md") ->
            headings =
              Index.docs()
              |> Enum.filter(&(&1.file == rel))

            heading_hits =
              headings
              |> Enum.take(12)
              |> Enum.map(fn h ->
                %{kind: :doc, file: h.file, line: h.line, label: "##{h.level} #{h.title}"}
              end)

            [
              %{
                kind: :file,
                file: rel,
                line: 1,
                label: "document (#{length(headings)} headings)"
              }
            ] ++ heading_hits

          true ->
            [
              %{
                kind: :file,
                file: rel,
                line: 1,
                label: "file (#{line_count(rel)} lines)"
              }
            ]
        end
    end
  end

  defp topic_hits(rel) do
    Index.topics_for_file(rel)
    |> Enum.map(fn topic ->
      %{
        kind: :topic,
        file: topic.file,
        line: 1,
        label: "topic '#{topic.id}' - #{topic.title}"
      }
    end)
  end

  defp test_hits_for(rel) do
    Index.tests_for(rel)
    |> Enum.map(fn t ->
      %{
        kind: :test,
        file: t.file,
        line: t.line,
        label: "test #{t.module || Path.basename(t.file)}"
      }
    end)
  end

  defp mention_hits(query, limit) do
    query = String.downcase(query)

    files()
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, number} ->
        if String.contains?(String.downcase(line), query) do
          [
            %{
              kind: :mention,
              file: file,
              line: number,
              label: trim_line(line)
            }
          ]
        else
          []
        end
      end)
    end)
    |> Enum.take(limit)
  end

  defp files do
    (Path.wildcard(Path.join(Index.root(), "lib/**/*.ex")) ++
       Path.wildcard(Path.join(Index.root(), "test/**/*.exs")) ++
       Path.wildcard(Path.join(Index.root(), "config/*.exs")) ++
       Path.wildcard(Path.join(Index.root(), "docs/**/*.md")) ++
       [Path.join(Index.root(), "README.md"), Path.join(Index.root(), "AGENTS.md")])
    |> Enum.map(&Path.relative_to(&1, Index.root()))
  end

  # ---- outline ------------------------------------------------------------

  def outline(file, _opts) do
    rel = file
    path = Path.join(Index.root(), rel)

    if File.exists?(path) do
      rows =
        cond do
          String.ends_with?(rel, ".ex") ->
            Index.modules_for_file(rel)
            |> Enum.flat_map(fn m ->
              [
                %{line: m.line, kind: "module", name: m.name}
              ] ++
                Enum.map(m.defs, fn d ->
                  %{line: d.line, kind: Atom.to_string(d.kind), name: "#{d.name}/#{Enum.join(d.arities, ",")}"}
                end) ++
                Enum.map(m.routes, fn r ->
                  %{line: r.line, kind: "route", name: "#{r.method} #{r.path}"}
                end)
            end)

          String.ends_with?(rel, ".md") ->
            Index.docs()
            |> Enum.filter(&(&1.file == rel))
            |> Enum.map(fn d -> %{line: d.line, kind: "heading", name: "##{d.level} #{d.title}"} end)

          String.ends_with?(rel, "_test.exs") ->
            case Enum.find(Index.tests(), &(&1.file == rel)) do
              nil ->
                []

              t ->
                [%{line: 1, kind: "test-module", name: t.module || ""}] ++
                  Enum.map(t.tests, fn n -> %{line: n.line, kind: "test", name: n.name} end)
            end

          true ->
            []
        end

      rows
      |> Enum.sort_by(& &1.line)
      |> Enum.each(fn row ->
        IO.puts("#{row.line}\t#{row.kind} #{row.name}")
      end)

      System.halt(0)
    else
      IO.puts(:stderr, "where: no such file: #{rel}")
      System.halt(1)
    end
  end

  # ---- printing -----------------------------------------------------------

  defp print(hits, opts) do
    Enum.each(hits, fn hit ->
      if opts[:json] do
        IO.puts(JSON.encode!(hit))
      else
        location = "#{hit.file}:#{hit.line}"

        if opts[:terse] do
          IO.puts(location)
        else
          IO.puts("#{location}  #{hit.label}")
        end

        if opts[:body] && hit[:end_line] do
          print_body(hit.file, hit.line, hit.end_line)
        end

        if opts[:context] && opts[:context] > 0 do
          print_context(hit.file, hit.line, opts[:context])
        end

        unless opts[:terse] do
          Enum.each(Map.get(hit, :extra, []), fn line -> IO.puts("  #{line}") end)
        end
      end
    end)
  end

  defp print_body(file, line, end_line) do
    text = File.read!(Path.join(Index.root(), file))
    lines = String.split(text, "\n")

    lines
    |> Enum.slice((line - 1)..(min(end_line, line + 60) - 1))
    |> Enum.each(fn l -> IO.puts("  #{l}") end)
  end

  defp print_context(file, line, count) do
    text = File.read!(Path.join(Index.root(), file))
    lines = String.split(text, "\n")

    lines
    |> Enum.slice((line - 1)..min(line - 1 + count, length(lines) - 1))
    |> Enum.each(fn l -> IO.puts("  #{l}") end)
  end

  defp miss(name, opts) do
    if opts[:json] do
      IO.puts(JSON.encode!(%{miss: name, near: near(name), mentions: mention_hits(name, opts[:limit] || 8)}))
    else
      IO.puts(:stderr, "where: no symbol, route, setting, error, document or test named '#{name}'")

      case near(name) do
        [] ->
          :ok

        candidates ->
          Enum.each(candidates, fn c ->
            IO.puts(:stderr, "  near  #{c.name}  (#{c.file}:#{c.line})")
          end)
      end

      mentions = mention_hits(name, opts[:limit] || 8)

      if mentions != [] do
        IO.puts(:stderr, "  mentions")

        Enum.each(mentions, fn m ->
          IO.puts(:stderr, "  #{m.file}:#{m.line}  #{m.label}")
        end)
      end
    end
  end

  # ---- near misses --------------------------------------------------------

  defp near(name) do
    name = to_string(name)
    target = String.downcase(name)
    words = words(target)
    max = max(2, div(String.length(target), 3))

    candidates()
    |> Enum.map(fn c ->
      distance = edit_distance(target, String.downcase(c.name))
      shared = MapSet.intersection(words, words(c.name)) |> MapSet.size()
      {c, distance, shared}
    end)
    |> Enum.filter(fn {c, distance, shared} ->
      String.downcase(c.name) != target and
        (distance <= max or (shared > 0 and String.length(target) > 2))
    end)
    |> Enum.sort_by(fn {c, distance, shared} -> {distance, -shared, String.length(c.name)} end)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 0))
  end

  defp candidates do
    modules =
      for m <- Index.modules() do
        %{name: m.name, file: m.file, line: m.line}
      end

    short_modules =
      for m <- Index.modules() do
        %{name: short_module(m.name), file: m.file, line: m.line}
      end

    defs =
      for m <- Index.modules(), d <- m.defs do
        %{
          name: "#{short_module(m.name)}.#{d.name}/#{d.arity}",
          file: m.file,
          line: d.line
        }
      end

    routes =
      for r <- Index.routes() do
        %{
          name: "#{r.method} #{r.path}",
          file: module_file(r.module) || "lib/junderground/router.ex",
          line: r.line
        }
      end

    settings =
      for {key, s} <- Index.settings() do
        %{
          name: "#{key}",
          file: s.config_file || "config/runtime.exs",
          line: s.config_line || 1
        }
      end

    stores =
      for s <- Index.stores() do
        %{name: s.file, file: s.source, line: s.line}
      end

    errors =
      for {atom, e} <- Index.errors() do
        %{
          name: ":#{atom}",
          file: e.status_file || "lib/junderground/router.ex",
          line: e.status_line || 1
        }
      end

    docs =
      for d <- Index.docs() do
        %{name: d.title, file: d.file, line: d.line}
      end

    tests =
      for t <- Index.tests() do
        %{name: t.file, file: t.file, line: t.line}
      end

    (modules ++ short_modules ++ defs ++ routes ++ settings ++ stores ++ errors ++ docs ++ tests)
    |> Enum.uniq_by(&{&1.name, &1.file, &1.line})
  end

  defp words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> MapSet.new()
  end

  defp edit_distance(a, b) do
    a = String.graphemes(a)
    b = String.graphemes(b)

    Enum.reduce(Enum.with_index(b, 1), Enum.to_list(0..length(a)), fn {char, i}, previous ->
      {row, _} =
        Enum.reduce(Enum.with_index(a, 1), {[i], nil}, fn {char_a, j}, {row, _} ->
          cost = if char_a == char, do: 0, else: 1
          above = Enum.at(previous, j)
          left = List.last(row)
          diagonal = Enum.at(previous, j - 1)
          value = min(min(left + 1, above + 1), diagonal + cost)
          {row ++ [value], nil}
        end)

      row
    end)
    |> List.last()
  end

  # ---- helpers ------------------------------------------------------------

  defp module_file(name) do
    case Index.module_named(name) do
      nil -> nil
      m -> m.file
    end
  end

  defp short_module(name), do: name |> String.split(".") |> List.last()

  defp first_line(text) do
    text
    |> String.split("\n")
    |> List.first()
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp trim_line(line) do
    line
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp line_count(rel) do
    Path.join(Index.root(), rel)
    |> File.read!()
    |> String.split("\n")
    |> length()
  end

  defp usage(code) do
    IO.puts("""
    usage: elixir scripts/where.exs [options] NAME...

      NAME   a module (Junderground.Rooms or Rooms), a function (Rooms.grant,
             Rooms.grant/4 or grant/4), a route
             ("POST /v1/rooms/:handle/:room/token" or "/v1/rooms/*"), a setting
             (sfu_url or JG_SFU_URL), a DETS store (rooms.dets), an error atom
             (:ticket_spent), a document heading, a test file, or a file path
             (which reports the module, help topics, routes and tests around it).

      --outline FILE   print "line<TAB>kind name" for every declaration in FILE
      --body           print the declaration after a hit
      --context N      print N lines after a hit
      --terse          print only file:line
      --limit N        cap mention lines on a miss (default 8)
      --json           one JSON object per hit
    """)

    System.halt(code)
  end
end

JGTool.Where.main(System.argv())
