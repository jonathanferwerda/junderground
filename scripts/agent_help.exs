# A tier-2 brief for an agent: what an app is made of, read straight from the
# tree. The tier-1 (user) guide lives in docs/help; this is the generated view.
#
#   elixir scripts/agent_help.exs Junderground.Rooms
#   elixir scripts/agent_help.exs Rooms
#   elixir scripts/agent_help.exs lib/junderground/rooms.ex
#   elixir scripts/agent_help.exs sfu
#   elixir scripts/agent_help.exs --routes rooms
#   elixir scripts/agent_help.exs --list
#   elixir scripts/agent_help.exs --config
#   elixir scripts/agent_help.exs --stores
#   elixir scripts/agent_help.exs --index
#   elixir scripts/agent_help.exs --write-index
#   elixir scripts/agent_help.exs --check
#
# The index is read from the tree, never loaded: scripts/jg_index.exs parses
# Elixir with Code.string_to_quoted/2, so this works even when the project does
# not compile. It never boots the app, opens DETS, or requires Mix.

Code.require_file("jg_index.exs", __DIR__)

defmodule JGTool.AgentHelp do
  @moduledoc """
  Prints the brief an agent needs before touching an app.

  A name resolves, in order, to a help topic id, a module, a file, or a domain
  that is a prefix of module names (`sfu` -> `Junderground.Sfu*`). The brief
  joins the sources, routes, stores, settings, public API, error atoms, tests
  and docs the index already knows about.
  """

  alias JGTool.Index

  @index_path "docs/AGENT-INDEX.md"
  @api_limit 20
  @doc_limit 8
  @note_limit 6

  def main(argv) do
    {opts, names, invalid} =
      OptionParser.parse(argv,
        strict: [
          list: :boolean,
          index: :boolean,
          write_index: :boolean,
          check: :boolean,
          config: :boolean,
          stores: :boolean,
          routes: :boolean,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    cond do
      invalid != [] ->
        usage(2)

      opts[:help] ->
        usage(0)

      opts[:list] ->
        list()
        System.halt(0)

      opts[:index] ->
        IO.write(index_text())
        System.halt(0)

      opts[:write_index] ->
        System.halt(write_index())

      opts[:check] ->
        System.halt(check())

      opts[:config] ->
        print_config()
        System.halt(0)

      opts[:stores] ->
        print_stores()
        System.halt(0)

      opts[:routes] && names == [] ->
        IO.puts(route_rows_text(Index.routes(), MapSet.new()))
        System.halt(0)

      names == [] ->
        usage(2)

      opts[:routes] ->
        System.halt(routes_command(names))

      true ->
        System.halt(briefs(names, opts))
    end
  end

  # ---- resolution ---------------------------------------------------------

  defp resolve(input) do
    name = String.trim(input)

    cond do
      name == "" ->
        :error

      topic = Map.get(Index.help(), name) ->
        from_topic(name, topic, [topic])

      true ->
        case Index.modules_named(name) do
          [] -> resolve_file_or_domain(name)
          modules -> from_modules(name, modules)
        end
    end
  end

  defp resolve_file_or_domain(name) do
    file = normalize(name)
    modules = Index.modules_for_file(file)
    topic = topic_for_file(file)
    topics = Index.topics_for_file(file)
    domain = domain_modules(name)

    cond do
      modules != [] -> from_modules(name, modules)
      topic -> from_topic(name, topic, [topic])
      topics != [] -> from_topic(name, Enum.sort_by(topics, & &1.id) |> hd(), topics)
      domain != [] -> from_modules(name, domain)
      true -> :error
    end
  end

  defp topic_for_file(file) do
    Index.help()
    |> Map.values()
    |> Enum.find(&(&1.file == file))
  end

  defp domain_modules(name) do
    down = String.downcase(name)

    cap =
      name
      |> String.split(~r/[^A-Za-z0-9_]+/, trim: true)
      |> Enum.map_join("", &Macro.camelize/1)

    prefix = "Junderground." <> cap

    Enum.filter(Index.modules(), fn module ->
      String.starts_with?(module.name, prefix) or
        String.starts_with?(String.downcase(short_name(module.name)), down)
    end)
  end

  defp from_topic(input, topic, topics) do
    sources = topic_sources(topic)
    modules = modules_for_files(sources)

    build(input, topic, topic, topics, modules, sources)
  end

  defp from_modules(input, modules) do
    modules = Enum.uniq_by(modules, & &1.name) |> Enum.sort_by(& &1.name)
    topics = related_topics(modules)
    related = best_topic(input, topics, modules)
    sources = modules |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.sort()

    build(input, nil, related, topics, modules, sources)
  end

  defp build(input, topic, related, topics, modules, sources) do
    modules = Enum.uniq_by(modules, & &1.name) |> Enum.sort_by(& &1.name)
    sources = Enum.uniq(sources) |> Enum.sort()
    module_names = MapSet.new(modules, & &1.name)

    %{
      input: input,
      topic: topic,
      related: related,
      title: title_for(topic, modules),
      topics: topics,
      modules: modules,
      module_names: module_names,
      sources: sources,
      routes: selected_routes(modules, module_names, topic)
    }
  end

  # A module may be covered by more than one topic. Prefer the one whose id or
  # title names the domain; a topic that merely lists the source file is not a
  # claim on the module.
  defp best_topic(input, topics, modules) do
    terms =
      [input | Enum.map(modules, &short_name(&1.name))]
      |> Enum.map(&(to_string(&1) |> String.downcase() |> String.trim()))
      |> Enum.reject(&(String.length(&1) < 3))
      |> Enum.uniq()

    topics
    |> Enum.map(fn topic -> {topic_score(topic, terms), topic} end)
    |> Enum.filter(fn {score, _} -> score > 0 end)
    |> Enum.sort_by(fn {score, topic} -> {-score, topic.id} end)
    |> Enum.map(fn {_, topic} -> topic end)
    |> List.first()
  end

  defp topic_score(topic, terms) do
    id = String.downcase(topic.id)
    title = String.downcase(topic.title)

    Enum.reduce(terms, 0, fn term, score ->
      cond do
        String.contains?(id, term) -> score + 3
        String.contains?(title, term) -> score + 1
        true -> score
      end
    end)
  end

  defp related_topics(modules) do
    modules
    |> Enum.flat_map(&Index.topics_for_module(&1.name))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp topic_sources(topic) do
    topic.sources
    |> Enum.flat_map(&expand_source/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expand_source(source) do
    source = normalize(source)
    path = Path.join(Index.root(), source)

    if String.contains?(source, ["*", "?", "["]) do
      path
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, Index.root()))
      |> Enum.sort()
    else
      if File.exists?(path), do: [source], else: []
    end
  end

  defp modules_for_files(files) do
    files
    |> Enum.flat_map(&Index.modules_for_file/1)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  defp selected_routes(_modules, module_names, topic) do
    by_call =
      Enum.filter(Index.routes(), fn route ->
        Enum.any?(route.calls, &MapSet.member?(module_names, &1.module))
      end)

    by_topic =
      case topic do
        nil -> []
        topic -> Enum.flat_map(topic.routes, &Index.route_hits/1)
      end

    (by_call ++ by_topic)
    |> Enum.uniq_by(&{&1.method, &1.path, &1.line})
    |> Enum.sort_by(&{&1.method, &1.path, &1.line})
  end

  # ---- the brief ----------------------------------------------------------

  defp briefs(names, opts) do
    misses =
      Enum.reduce(names, [], fn name, misses ->
        case resolve(name) do
          :error ->
            IO.puts(:stderr, "no such name: #{name}")
            [name | misses]

          ctx ->
            IO.puts(brief(ctx, opts))
            misses
        end
      end)

    if misses == [], do: 0, else: 1
  end

  defp brief(ctx, opts) do
    [
      "#{ctx.input} — #{ctx.title}",
      tier_line(ctx),
      "",
      sources_section(ctx),
      "",
      routes_section(ctx, opts),
      "",
      stores_section(ctx),
      "",
      settings_section(ctx),
      "",
      api_section(ctx),
      "",
      errors_section(ctx),
      "",
      tests_section(ctx),
      "",
      docs_section(ctx),
      "",
      notes_section(ctx)
    ]
    |> Enum.join("\n")
  end

  defp title_for(%{title: title}, _modules), do: title

  defp title_for(nil, modules) do
    names = Enum.map(modules, & &1.name)

    case names do
      [] -> "nothing"
      [one] -> one
      [first | _] ->
        if Enum.all?(names, &String.starts_with?(&1, first)) do
          first <> "*"
        else
          Enum.join(names, ", ")
        end
    end
  end

  defp tier_line(ctx) do
    case ctx.related || ctx.topic do
      nil ->
        "tier 1: none — no help topic yet"

      topic ->
        vetted = if topic.verified in [nil, ""], do: "unvetted", else: topic.verified
        base = "tier 1: help topic '#{topic.id}' (vetted #{vetted})"

        others =
          ctx.topics
          |> Enum.map(& &1.id)
          |> Enum.reject(&(&1 == topic.id))
          |> Enum.sort()

        if others == [], do: base, else: base <> "; also: " <> Enum.join(others, ", ")
    end
  end

  defp sources_section(ctx) do
    header = "sources (#{length(ctx.sources)})"

    if ctx.sources == [] do
      header <> "\n  none"
    else
      body =
        Enum.map(ctx.sources, fn file ->
          modules = Index.modules_for_file(file) |> Enum.map(&short_name(&1.name))
          suffix = if modules == [], do: "", else: "  (" <> Enum.join(modules, ", ") <> ")"
          "  " <> file <> suffix
        end)

      Enum.join([header | body], "\n")
    end
  end

  defp routes_section(ctx, opts) do
    header = "routes (#{length(ctx.routes)})"

    cond do
      ctx.routes == [] ->
        header <> "\n  none"

      opts[:routes] ->
        header <> " — exact rows\n" <> route_rows_text(ctx.routes, ctx.module_names)

      true ->
        body =
          ctx.routes
          |> compressed_routes()
          |> Enum.map(&("  " <> &1))

        Enum.join(
          [header <> " — compressed, grouped by method (--routes for exact rows)" | body],
          "\n"
        )
    end
  end

  defp stores_section(ctx) do
    stores = selected_stores(ctx)
    header = "stores (#{length(stores)})"

    if stores == [] do
      header <> "\n  none"
    else
      body =
        Enum.map(stores, fn store ->
          "  #{store.file}  #{store_table(store)}  #{store.module}  #{store.source}:#{store.line}"
        end)

      Enum.join([header | body], "\n")
    end
  end

  defp settings_section(ctx) do
    settings = selected_settings(ctx)
    header = "settings (#{length(settings)})"
    source_set = MapSet.new(ctx.sources)

    if settings == [] do
      header <> "\n  none"
    else
      body =
        Enum.map(settings, fn {key, setting} ->
          readers = Enum.count(setting.readers, &MapSet.member?(source_set, &1.file))

          "  #{key}  #{env_label(setting)}  #{config_label(setting)}  readers: #{readers}"
        end)

      Enum.join([header | body], "\n")
    end
  end

  defp api_section(ctx) do
    defs = api_defs(ctx)
    header = "public api (#{length(defs)})"

    if defs == [] do
      header <> "\n  none"
    else
      shown = Enum.take(defs, @api_limit)
      more = length(defs) - length(shown)

      body =
        Enum.map(shown, fn {module, definition} ->
          doc = if definition.doc, do: "  " <> first_line(definition.doc), else: ""
          arities = definition.arities |> Enum.uniq() |> Enum.join(",")

          "  #{short_name(module.name)}.#{definition.name}/#{arities}  " <>
            "#{module.file}:#{definition.line}#{doc}"
        end)

      tail = if more > 0, do: ["  ... #{more} more"], else: []
      Enum.join([header | body] ++ tail, "\n")
    end
  end

  defp api_defs(ctx) do
    ctx.modules
    |> Enum.sort_by(& &1.name)
    |> Enum.flat_map(fn module ->
      module.defs
      |> Enum.filter(&(&1.kind == :def))
      |> Enum.map(&{module, &1})
    end)
    |> Enum.uniq_by(fn {module, definition} ->
      {module.name, definition.name, definition.arities}
    end)
  end

  defp errors_section(ctx) do
    errors = selected_errors(ctx)
    header = "errors (#{length(errors)})"

    if errors == [] do
      header <> "\n  none"
    else
      body =
        Enum.map(errors, fn {atom, error} ->
          "  :#{atom}  " <> status_label(error)
        end)

      Enum.join([header | body], "\n")
    end
  end

  defp status_label(%{status: nil}), do: "status none"

  defp status_label(%{status: status, status_file: file, status_line: line}) do
    "#{status} (#{file}:#{line})"
  end

  defp tests_section(ctx) do
    tests = Index.tests_for(ctx.sources) |> Enum.sort_by(& &1.file)
    header = "tests that claim these files (#{length(tests)})"

    if tests == [] do
      header <> "\n  none — no test claims these files yet"
    else
      body = Enum.map(tests, &("  " <> &1.file))
      Enum.join([header | body], "\n")
    end
  end

  defp docs_section(ctx) do
    docs = selected_docs(ctx)
    header = "docs (#{length(docs)})"

    if docs == [] do
      header <> "\n  none"
    else
      body =
        Enum.map(docs, fn doc ->
          "  #{doc.file}:#{doc.line}  #{doc.title}"
        end)

      Enum.join([header | body], "\n")
    end
  end

  defp notes_section(ctx) do
    lines = notes_lines(ctx.modules)
    header = "notes from the sources (#{length(lines)} lines)"

    if lines == [] do
      header <> "\n  none"
    else
      body = Enum.map(lines, &("  " <> &1))
      Enum.join([header | body], "\n")
    end
  end

  # ---- brief lookups ------------------------------------------------------

  defp selected_stores(ctx) do
    source_set = MapSet.new(ctx.sources)

    named =
      case ctx.topic do
        nil -> []
        topic -> Enum.flat_map(topic.stores, &Index.store/1)
      end

    (Enum.filter(Index.stores(), fn store ->
       MapSet.member?(ctx.module_names, store.module) or
         MapSet.member?(source_set, store.source)
     end) ++ named)
    |> Enum.uniq_by(&{&1.file, &1.source, &1.line})
    |> Enum.sort_by(& &1.file)
  end

  defp selected_settings(ctx) do
    source_set = MapSet.new(ctx.sources)

    named =
      case ctx.topic do
        nil -> MapSet.new()
        topic -> MapSet.new(topic.settings, &setting_name/1)
      end

    Index.settings()
    |> Enum.filter(fn {key, setting} ->
      MapSet.member?(named, to_string(key)) or
        Enum.any?(setting.readers, &MapSet.member?(source_set, &1.file))
    end)
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
  end

  defp selected_errors(ctx) do
    source_set = MapSet.new(ctx.sources)

    named =
      case ctx.topic do
        nil -> MapSet.new()
        topic -> MapSet.new(topic.errors, &error_name/1)
      end

    Index.errors()
    |> Enum.filter(fn {atom, error} ->
      MapSet.member?(named, to_string(atom)) or
        Enum.any?(error.producers, &MapSet.member?(source_set, &1.file))
    end)
    |> Enum.sort_by(fn {atom, _} -> to_string(atom) end)
  end

  defp selected_docs(ctx) do
    route_paths = MapSet.new(ctx.routes, & &1.path)

    terms =
      [ctx.input, ctx.title, ctx.topic && ctx.topic.id, ctx.related && ctx.related.id] ++
        Enum.map(ctx.modules, &short_name(&1.name))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&(to_string(&1) |> String.downcase() |> String.trim()))
      |> Enum.reject(&(String.length(&1) < 3))
      |> Enum.uniq()

    repo_docs()
    |> Enum.filter(fn doc ->
      Enum.any?(doc.routes, &MapSet.member?(route_paths, &1.path)) or
        Enum.any?(terms, &String.contains?(String.downcase(doc.title), &1))
    end)
    |> Enum.sort_by(fn doc ->
      {if(doc.file == "docs/API.md", do: 0, else: 1), doc.file, doc.line}
    end)
    |> Enum.take(@doc_limit)
  end

  defp notes_lines(modules) do
    per_module = if length(modules) == 1, do: 4, else: 2

    modules
    |> Enum.sort_by(& &1.name)
    |> Enum.flat_map(fn module ->
      case module.moduledoc do
        nil ->
          []

        doc ->
          doc
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(per_module)
          |> Enum.map(&"#{module.name}: #{&1}")
      end
    end)
    |> Enum.take(@note_limit)
  end

  defp repo_docs, do: Enum.reject(Index.docs(), &(&1.file == @index_path))

  # ---- route rows and compression ----------------------------------------

  defp compressed_routes(routes) do
    routes
    |> Enum.group_by(& &1.method)
    |> Enum.sort_by(fn {method, _} -> method end)
    |> Enum.flat_map(fn {method, group} ->
      paths = group |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()
      Enum.map(compress_paths(paths), &(method <> " " <> &1))
    end)
  end

  defp compress_paths(paths) do
    tree =
      Enum.reduce(paths, %{}, fn path, acc ->
        insert_path(acc, path_segments(path))
      end)

    tree
    |> child_keys()
    |> Enum.map(fn segment -> render_node(segment, Map.fetch!(tree, segment)) end)
  end

  defp path_segments(path) do
    path
    |> String.trim()
    |> String.split("/", trim: true)
  end

  defp insert_path(tree, []), do: Map.put(tree, :terminal, true)

  defp insert_path(tree, [segment | rest]) do
    Map.update(tree, segment, insert_path(%{}, rest), &insert_path(&1, rest))
  end

  defp child_keys(tree) do
    tree
    |> Map.keys()
    |> Enum.reject(&(&1 == :terminal))
    |> Enum.sort()
  end

  defp render_node(segment, children) do
    keys = child_keys(children)
    terminal? = Map.get(children, :terminal, false)

    case {keys, terminal?} do
      {[], _} ->
        "/" <> segment

      {[only], false} ->
        "/" <> segment <> render_node(only, Map.fetch!(children, only))

      _ ->
        inner =
          keys
          |> Enum.map(&render_node(&1, Map.fetch!(children, &1)))
          |> Enum.join(",")

        "/" <> segment <> "{" <> inner <> "}"
    end
  end

  defp route_rows_text(routes, module_names) do
    routes = Enum.sort_by(routes, &{&1.method, &1.path, &1.line})

    if routes == [] do
      "  none"
    else
      Enum.map_join(routes, "\n", &route_row(&1, module_names))
    end
  end

  defp route_row(route, module_names) do
    file =
      case Enum.find(Index.modules(), &(&1.name == route.module)) do
        nil -> "lib/junderground/router.ex"
        module -> module.file
      end

    "  #{route.method} #{route.path}  #{file}:#{route.line} -> #{route_target(route, module_names)}"
  end

  defp route_target(route, module_names) do
    call =
      Enum.find(route.calls, &MapSet.member?(module_names, &1.module)) ||
        Enum.find(route.calls, fn call ->
          call.module != route.module and String.starts_with?(call.module, "Junderground.")
        end) ||
        Enum.find(route.calls, &(&1.module != route.module)) ||
        List.first(route.calls)

    case call do
      nil -> short_name(route.module)
      call -> "#{call.module}.#{call.fun}/#{call.arity}"
    end
  end

  defp routes_command(names) do
    {routes, misses} =
      Enum.reduce(names, {[], []}, fn name, {routes, misses} ->
        case resolve(name) do
          :error ->
            IO.puts(:stderr, "no such name: #{name}")
            {routes, [name | misses]}

          ctx ->
            {routes ++ ctx.routes, misses}
        end
      end)

    {module_names, _} =
      Enum.reduce(names, {MapSet.new(), []}, fn name, {set, _} ->
        case resolve(name) do
          :error -> {set, []}
          ctx -> {MapSet.union(set, ctx.module_names), []}
        end
      end)

    routes =
      routes
      |> Enum.uniq_by(&{&1.method, &1.path, &1.line})
      |> Enum.sort_by(&{&1.method, &1.path, &1.line})

    IO.puts("routes (#{length(routes)})")
    IO.puts(route_rows_text(routes, module_names))
    if misses == [], do: 0, else: 1
  end

  # ---- repository index ---------------------------------------------------

  def index_text do
    modules = Index.modules()
    routes = Index.routes()

    lines =
      [
        "# junderground agent index (generated)",
        "",
        "Generated by `elixir scripts/agent_help.exs --write-index`; do not edit by hand. " <>
          "Ask for a brief with `elixir scripts/agent_help.exs NAME`; ask where one name lives " <>
          "with `elixir scripts/where.exs NAME`. Regenerate and compare with `--check`.",
        "",
        "## modules",
        ""
      ] ++
        module_lines(modules) ++
        ["", "## routes", "", "#{length(routes)} routes", ""] ++
        route_group_lines(routes) ++
        ["", "## stores", ""] ++
        store_lines() ++
        ["", "## settings", ""] ++
        setting_lines() ++
        ["", "## tests", ""] ++
        test_lines() ++
        ["", "## docs", ""] ++
        doc_lines() ++
        ["", "## commands", ""] ++
        command_lines()

    Enum.join(lines, "\n") <> "\n"
  end

  defp module_lines(modules) do
    Enum.map(modules, fn module ->
      public = Enum.count(module.defs, &(&1.kind == :def))
      private = Enum.count(module.defs, &(&1.kind == :defp))
      topics = Index.topics_for_module(module.name) |> Enum.map(& &1.id) |> Enum.sort()
      routes = Index.routes_for_module(module.name) |> length()
      tests = Index.tests_for([module.file]) |> length()

      "#{module.name}  #{module.file}  #{public}/#{private} defs  " <>
        "topics: #{list_or_dash(topics)}  routes: #{routes}  tests: #{tests}"
    end)
  end

  defp route_group_lines(routes) do
    routes
    |> Enum.group_by(&route_group(&1.path))
    |> Enum.sort_by(fn {group, group_routes} -> {-length(group_routes), group} end)
    |> Enum.map(fn {group, group_routes} -> "#{group}  #{length(group_routes)}" end)
  end

  defp route_group(path) do
    case String.split(path, "/", trim: true) do
      ["v1", first | _] -> "/v1/" <> first
      [first | _] -> "/" <> first
      [] -> "(root)"
    end
  end

  defp store_lines do
    Index.stores()
    |> Enum.sort_by(& &1.file)
    |> Enum.map(fn store ->
      "#{store.file}  #{store_table(store)}  #{store.module}  #{store.source}:#{store.line}"
    end)
  end

  defp setting_lines do
    Index.settings()
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map(fn {key, setting} ->
      "#{key}  #{env_label(setting)}  #{config_label(setting)}  readers: #{length(setting.readers)}"
    end)
  end

  defp test_lines do
    Index.tests()
    |> Enum.sort_by(& &1.file)
    |> Enum.map(fn test ->
      "#{test.file}  #{length(test.claims)} claims  #{length(test.tests)} tests"
    end)
  end

  defp doc_lines do
    repo_docs()
    |> Enum.group_by(& &1.file)
    |> Enum.sort_by(fn {file, _} -> file end)
    |> Enum.map(fn {file, headings} -> "#{file}  #{length(headings)} headings" end)
  end

  defp command_lines do
    [
      "elixir scripts/where.exs NAME",
      "elixir scripts/where.exs --outline FILE",
      "elixir scripts/agent_help.exs NAME [--routes]",
      "elixir scripts/agent_help.exs --list",
      "elixir scripts/agent_help.exs --config",
      "elixir scripts/agent_help.exs --stores",
      "elixir scripts/agent_help.exs --index",
      "elixir scripts/agent_help.exs --write-index",
      "elixir scripts/agent_help.exs --check",
      "elixir scripts/help_audit.exs --check"
    ]
  end

  defp write_index do
    content = index_text()
    path = Path.join(Index.root(), @index_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    IO.puts("wrote #{@index_path} (#{length(String.split(content, "\n"))} lines)")

    if String.length(content) > 0, do: 0, else: 1
  end

  defp check do
    path = Path.join(Index.root(), @index_path)
    expected = index_text()

    case File.read(path) do
      {:ok, ^expected} ->
        IO.puts("#{@index_path} is up to date")
        0

      {:ok, _} ->
        IO.puts(:stderr, "#{@index_path} is out of date; run --write-index")
        1

      {:error, _} ->
        IO.puts(:stderr, "#{@index_path} is missing; run --write-index")
        1
    end
  end

  # ---- global listings ----------------------------------------------------

  defp list do
    topics =
      Index.help()
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn topic -> "topic  #{topic.id}  #{topic.title}  #{topic.file}" end)

    modules =
      Index.modules()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn module -> "module  #{module.name}  #{module.file}" end)

    domains =
      Index.modules()
      |> Enum.map(fn module ->
        case String.split(module.name, ".") do
          ["Junderground", second | _] -> String.downcase(second)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {domain, _} -> domain end)
      |> Enum.map(fn {domain, count} ->
        noun = if count == 1, do: "module", else: "modules"
        "domain  #{domain}  #{count} #{noun}"
      end)

    Enum.each(topics ++ modules ++ domains, &IO.puts/1)
  end

  defp print_config do
    settings =
      Index.settings()
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)

    IO.puts("settings (#{length(settings)})")

    Enum.each(settings, fn {key, setting} ->
      IO.puts(
        "#{key}  #{env_label(setting)}  default: #{default_label(setting)}  " <>
          "#{config_label(setting)}  readme: #{readme_label(setting)}  " <>
          "readers: #{length(setting.readers)}"
      )
    end)
  end

  defp print_stores do
    stores = Index.stores() |> Enum.sort_by(& &1.file)

    IO.puts("stores (#{length(stores)})")

    Enum.each(stores, fn store ->
      IO.puts(
        "#{store.file}  #{store_table(store)}  #{store.module}  " <>
          "#{store.source}:#{store.line}"
      )
    end)
  end

  # ---- small helpers ------------------------------------------------------

  defp short_name(name), do: name |> String.split(".") |> List.last()

  defp store_table(%{table: nil}), do: "-"
  defp store_table(%{table: table}), do: inspect(table)

  defp env_label(setting) do
    case Map.get(setting, :env) do
      nil -> "(none)"
      "" -> "(none)"
      env -> env
    end
  end

  defp config_label(setting) do
    case Map.get(setting, :config_file) do
      nil -> "-"
      file -> "#{file}:#{Map.get(setting, :config_line)}"
    end
  end

  defp readme_label(%{readme: nil}), do: "-"
  defp readme_label(%{readme: readme}), do: "#{readme.file}:#{readme.line}"

  defp default_label(%{default: :dynamic}), do: "dynamic"
  defp default_label(%{default: default}), do: inspect(default)

  defp setting_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace_prefix(":", "")
    |> String.downcase()
  end

  defp error_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace_prefix(":", "")
    |> String.downcase()
  end

  defp first_line(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp list_or_dash([]), do: "-"
  defp list_or_dash(values), do: Enum.join(values, ",")

  defp normalize(path) do
    path = path |> to_string() |> String.trim() |> String.replace_prefix("./", "")

    if String.starts_with?(path, Index.root() <> "/") do
      Path.relative_to(path, Index.root())
    else
      path
    end
  end

  defp usage(code) do
    IO.puts("""
    usage: elixir scripts/agent_help.exs [options] NAME...

      NAME   a help topic id, a module (Junderground.Rooms or Rooms), a file
             (lib/junderground/rooms.ex), or a domain prefix of module names
             (sfu -> Junderground.Sfu*).

      --routes         exact route rows instead of the compressed form
      --list           every topic, module and domain this script accepts
      --config         every setting with its ENV, default and config line
      --stores         every store with its table, module and line
      --index          print the repository index to stdout
      --write-index    write it to docs/AGENT-INDEX.md
      --check          fail when docs/AGENT-INDEX.md is missing or stale
    """)

    System.halt(code)
  end
end

JGTool.AgentHelp.main(System.argv())
