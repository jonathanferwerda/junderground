defmodule JGTool.Index do
  @moduledoc """
  Reads the junderground tree without compiling or booting it.

  This is the shared index behind `where.exs`, `agent_help.exs` and
  `help_audit.exs`. It parses Elixir source with `Code.string_to_quoted/2`,
  Markdown headings and the small help front matter; it never starts the
  application, opens DETS, or reads `server.key`.

  All paths in the returned tree are relative to the repository root.
  """

  @root Path.expand("..", __DIR__)

  @route_methods [:get, :post, :put, :delete, :patch, :match, :forward]

  def root, do: @root

  def tree do
    case :persistent_term.get({__MODULE__, :tree}, nil) do
      nil ->
        value = load()
        :persistent_term.put({__MODULE__, :tree}, value)
        value

      value ->
        value
    end
  end

  def load do
    ex_files = Path.wildcard(Path.join(root(), "lib/**/*.ex")) |> Enum.sort()

    {modules, parse_errors} =
      Enum.reduce(ex_files, {[], []}, fn path, {mods, errors} ->
        {found, bad} = parse_ex_file(rel(path))
        {mods ++ found, errors ++ bad}
      end)

    routes =
      modules
      |> Enum.flat_map(& &1.routes)
      |> Enum.sort_by(&{&1.path, &1.method})

    modules = Enum.sort_by(modules, & &1.name)

    tests = parse_tests(modules)
    config = parse_config()
    settings = build_settings(modules, config)
    stores =
      modules
      |> Enum.flat_map(fn m -> Enum.map(m.stores, &Map.put(&1, :module, m.name)) end)
      |> Enum.sort_by(& &1.file)
    errors = build_errors(modules)
    docs = parse_docs()
    help = parse_help()

    %{
      root: root(),
      files: Enum.map(ex_files, &rel/1),
      modules: modules,
      routes: routes,
      tests: tests,
      settings: settings,
      stores: stores,
      errors: errors,
      docs: docs,
      help: help,
      parse_errors: parse_errors
    }
  end

  # ---- public lookups -----------------------------------------------------

  def modules, do: tree().modules
  def routes, do: tree().routes
  def tests, do: tree().tests
  def settings, do: tree().settings
  def stores, do: tree().stores
  def errors, do: tree().errors
  def docs, do: tree().docs
  def help, do: tree().help
  def parse_errors, do: tree().parse_errors

  def module_named(name) do
    name = to_string(name)

    Enum.find(modules(), fn m ->
      m.name == name or last_segment(m.name) == name
    end)
  end

  def modules_named(name) do
    name = to_string(name)

    Enum.filter(modules(), fn m ->
      m.name == name or last_segment(m.name) == name
    end)
  end

  def module_for_file(file) do
    file = normalize_path(file)

    Enum.find(modules(), &(&1.file == file))
  end

  def modules_for_file(file) do
    file = normalize_path(file)

    Enum.filter(modules(), &(&1.file == file))
  end

  def defs_named(name, arity \\ nil) do
    name = to_string(name)

    for m <- modules(),
        d <- m.defs,
        d.name == name,
        is_nil(arity) or arity in d.arities do
      {m, d}
    end
  end

  def def_hits(name) do
    name = to_string(name)

    {fun_part, arity} =
      case String.split(name, "/", parts: 2) do
        [fun, value] ->
          case Integer.parse(value) do
            {n, ""} -> {fun, n}
            _ -> {fun, nil}
          end

        [fun] ->
          {fun, nil}
      end

    case String.split(fun_part, ".") do
      [fun] ->
        defs_named(fun, arity)

      parts ->
        {mod, fun} = {Enum.join(Enum.drop(parts, -1), "."), List.last(parts)}

        for m <- modules_named(mod),
            d <- m.defs,
            d.name == fun,
            is_nil(arity) or arity in d.arities do
          {m, d}
        end
    end
  end

  def route_hits(name) do
    case parse_route_query(name) do
      {:ok, method, path} ->
        Enum.filter(routes(), fn r ->
          (is_nil(method) or r.method == method) and route_path_match?(r.path, path)
        end)

      :error ->
        []
    end
  end

  def setting(name) do
    key = setting_key(name)
    Map.get(settings(), key)
  end

  def store(name) do
    name = to_string(name)

    Enum.filter(stores(), fn s ->
      s.file == name or to_string(s.table) == name or ":" <> to_string(s.table) == name
    end)
  end

  def error(atom) when is_atom(atom), do: Map.get(errors(), atom)

  def error(name) when is_binary(name) do
    raw =
      name
      |> String.trim()
      |> String.replace_prefix(":", "")
      |> String.replace_prefix("JG_", "")
      |> String.downcase()

    case existing_atom(raw) do
      nil -> nil
      atom -> Map.get(errors(), atom)
    end
  end

  def docs_named(query) do
    q = String.downcase(String.trim(to_string(query)))
    docs() |> Enum.filter(&(String.downcase(&1.title) == q or &1.anchor == q))
  end

  def docs_containing(query) do
    q = String.downcase(String.trim(to_string(query)))

    docs()
    |> Enum.filter(fn d ->
      String.contains?(String.downcase(d.title), q) or
        String.contains?(String.downcase(d.file), q)
    end)
  end

  def tests_for(files) do
    files = Enum.map(List.wrap(files), &normalize_path/1)

    Enum.filter(tests(), fn test ->
      Enum.any?(files, fn file ->
        Enum.any?(test.claims, &glob_match?(&1, file)) or
          String.contains?(test.text, file) or
          Enum.any?(test.modules, fn mod ->
            case module_named(mod) do
              nil -> false
              m -> m.file == file
            end
          end)
      end)
    end)
  end

  def topics_for_file(file) do
    file = normalize_path(file)

    help()
    |> Map.values()
    |> Enum.filter(fn topic ->
      file in topic.sources or
        Enum.any?(topic.sources, &glob_match?(&1, file))
    end)
  end

  def topics_for_route(method, path) do
    wanted = method <> " " <> path

    help()
    |> Map.values()
    |> Enum.filter(fn topic ->
      Enum.any?(topic.routes, fn r -> r == wanted or route_path_match?(r, path) end)
    end)
  end

  def topics_for_module(module) do
    case module_named(module) do
      nil ->
        []

      m ->
        help()
        |> Map.values()
        |> Enum.filter(fn topic ->
          m.file in topic.sources or
            Enum.any?(topic.sources, &glob_match?(&1, m.file))
        end)
    end
  end

  def routes_for_module(module) do
    case module_named(module) do
      nil ->
        []

      m ->
        Enum.filter(routes(), fn r ->
          Enum.any?(r.calls, &(&1.module == m.name))
        end)
    end
  end

  # ---- parsing: Elixir ----------------------------------------------------

  defp parse_ex_file(rel_path) do
    path = Path.join(root(), rel_path)
    text = File.read!(path)
    lines = String.split(text, "\n")

    case Code.string_to_quoted(text, columns: true, token_metadata: true) do
      {:ok, ast} ->
        {walk_modules(ast, nil, rel_path, lines), []}

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line), else: nil
        detail = "#{inspect(message)} #{inspect(token)}"

        {[],
         [
           %{
             file: rel_path,
             line: line,
             error: String.trim(detail)
           }
         ]}
    end
  rescue
    error ->
      {[], [%{file: rel_path, line: nil, error: Exception.message(error)}]}
  end

  defp walk_modules({:__block__, _, forms}, parent, file, lines) do
    Enum.flat_map(forms, &walk_modules(&1, parent, file, lines))
  end

  defp walk_modules({:defmodule, meta, [name_ast, [do: body]]}, parent, file, lines) do
    name = module_name(name_ast, parent)
    module = parse_module(name, meta, body, file, lines)
    [module | walk_modules(body, name, file, lines)]
  end

  defp walk_modules(_, _, _, _), do: []

  defp module_name({:__aliases__, _, parts}, nil), do: Enum.join(parts, ".")

  defp module_name({:__aliases__, _, parts}, parent) do
    name = Enum.join(parts, ".")

    cond do
      String.starts_with?(name, parent <> ".") -> name
      String.contains?(name, ".") -> name
      true -> parent <> "." <> name
    end
  end

  defp parse_module(name, meta, body, file, lines) do
    forms = forms(body)
    aliases = collect_aliases(forms)
    uses = collect_uses(forms)
    attrs = collect_attrs(forms, lines)
    {defs, _} = collect_defs(forms, name, aliases)
    routes = collect_routes(forms, name, aliases)
    moduledoc = module_doc(attrs)
    settings =
      (Enum.flat_map(defs, & &1.settings) ++ Enum.flat_map(routes, & &1.settings))
      |> dedupe_by(& &1.line)
    errors = text_errors(file, lines)
    stores = text_stores(file, lines, attrs)

    %{
      name: name,
      file: file,
      line: meta[:line],
      end_line: get_in(meta, [:end, :line]) || meta[:line],
      moduledoc: moduledoc,
      uses: uses,
      aliases: aliases,
      attrs: attrs,
      defs: defs,
      routes: routes,
      calls: Enum.flat_map(defs, & &1.calls),
      settings: settings,
      errors: errors,
      stores: stores,
      statuses: collect_statuses(forms)
    }
  end

  defp forms({:__block__, _, forms}), do: forms
  defp forms(nil), do: []
  defp forms(single), do: [single]

  defp collect_aliases(forms) do
    Enum.reduce(forms, %{}, fn
      {:alias, _, [arg]}, acc ->
        add_alias(acc, arg, [])

      {:alias, _, [arg, opts]}, acc ->
        add_alias(acc, arg, opts)

      _, acc ->
        acc
    end)
  end

  defp add_alias(acc, {{:., _, [{:__aliases__, _, base}, :{}]}, _, aliases}, _opts) do
    Enum.reduce(aliases, acc, fn
      {:__aliases__, _, parts}, inner ->
        full = base ++ parts
        Map.put(inner, List.last(parts), Enum.join(full, "."))

      _, inner ->
        inner
    end)
  end

  defp add_alias(acc, {:__aliases__, _, parts}, opts) do
    as =
      case Keyword.get(opts, :as) do
        {:__aliases__, _, as_parts} -> List.last(as_parts)
        _ -> List.last(parts)
      end

    Map.put(acc, as, Enum.join(parts, "."))
  end

  defp add_alias(acc, _, _), do: acc

  defp collect_uses(forms) do
    for {:use, _, [arg | _]} <- forms,
        {:__aliases__, _, parts} <- [arg] do
      Enum.join(parts, ".")
    end
  end

  defp collect_attrs(forms, lines) do
    Enum.reduce(forms, %{}, fn
      {:@, meta, [{name, _, args}]}, acc when is_atom(name) ->
        value =
          case args do
            [v] -> v
            _ -> nil
          end

        line = meta[:line] || 1
        text = Enum.at(lines, line - 1, "") |> String.trim()
        Map.put(acc, Atom.to_string(name), %{value: value, line: line, text: text})

      _, acc ->
        acc
    end)
  end

  defp module_doc(attrs) do
    case get_in(attrs, ["moduledoc", :value]) do
      text when is_binary(text) -> String.trim(text)
      _ -> nil
    end
  end

  defp collect_defs(forms, module, aliases) do
    {defs, _pending_doc} =
      Enum.reduce(forms, {[], nil}, fn
        {:@, _, [{:doc, _, [value]}]}, {acc, _} ->
          {acc, value}

        {kind, meta, [head, [do: body]]}, {acc, doc} when kind in [:def, :defp, :defmacro, :defguard] ->
          definition = make_def(kind, meta, head, body, doc, module, aliases)
          {[definition | acc], nil}

        _, {acc, doc} ->
          {acc, doc}
      end)

    {Enum.reverse(defs), nil}
  end

  defp make_def(kind, meta, head, body, doc, module, aliases) do
    head = unwrap_when(head)
    {name, head_meta, args} = head
    args = if is_nil(args), do: [], else: args
    arities = arities(args)
    line = head_meta[:line] || meta[:line]

    %{
      name: Atom.to_string(name),
      arity: List.last(arities),
      arities: arities,
      line: line,
      end_line: get_in(meta, [:end, :line]) || get_in(meta, [:end_of_expression, :line]) || line,
      kind: kind,
      doc: if(is_binary(doc) and String.trim(doc) != "", do: String.trim(doc), else: nil),
      signature: Macro.to_string(head),
      calls: remote_calls(body, aliases, module),
      settings: settings_in(body)
    }
  end

  defp unwrap_when({:when, _, [head, _guard]}), do: head
  defp unwrap_when(head), do: head

  defp arities(args) do
    required = Enum.count(args, &(not match?({:\\, _, _}, &1)))
    total = length(args)
    Enum.to_list(required..total)
  end

  defp collect_routes(forms, module, aliases) do
    Enum.flat_map(forms, fn
      {method, meta, [path_ast, [do: body]]} when method in @route_methods ->
        [
          %{
            method: route_method(method),
            path: route_path(path_ast),
            line: meta[:line],
            body_line: get_in(meta, [:do, :line]) || meta[:line],
            end_line: get_in(meta, [:end, :line]) || get_in(meta, [:end_of_expression, :line]) || meta[:line],
            module: module,
            calls: remote_calls(body, aliases, module),
            settings: settings_in(body)
          }
        ]

      _ ->
        []
    end)
  end

  defp route_method(:match), do: "ANY"
  defp route_method(method), do: method |> Atom.to_string() |> String.upcase()

  defp route_path(path) when is_binary(path), do: path
  defp route_path({:_, _, _}), do: "*"
  defp route_path(_), do: "*"

  defp remote_calls(ast, aliases, current) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, parts}, fun]}, meta, args} = node, acc when is_atom(fun) ->
          arity = if is_list(args), do: length(args), else: 0
          module = resolve_parts(parts, aliases)

          {node,
           [
             %{module: module, fun: Atom.to_string(fun), arity: arity, line: meta[:line]}
             | acc
           ]}

        {{:., _, [{:__MODULE__, _, _}, fun]}, meta, args} = node, acc when is_atom(fun) ->
          arity = if is_list(args), do: length(args), else: 0
          {node, [%{module: current, fun: Atom.to_string(fun), arity: arity, line: meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp resolve_parts([first | rest], aliases) do
    case Map.get(aliases, first) do
      nil -> Enum.join([first | rest], ".")
      base -> Enum.join([base | rest], ".")
    end
  end

  defp settings_in(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Application]}, :get_env]}, meta, [:junderground, key | rest]} = node, acc
        when is_atom(key) ->
          default =
            case rest do
              [value | _] -> literal(value)
              [] -> nil
            end

          {node, [%{key: key, line: meta[:line], default: default, via: :get_env} | acc]}

        {{:., _, [{:__aliases__, _, [:Application]}, :fetch_env!]}, meta, [:junderground, key]} = node, acc
        when is_atom(key) ->
          {node, [%{key: key, line: meta[:line], default: nil, via: :fetch_env} | acc]}

        {:env, meta, [key]} = node, acc when is_atom(key) ->
          {node, [%{key: key, line: meta[:line], default: nil, via: :env_helper} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp literal(value) when is_binary(value) or is_integer(value) or is_atom(value), do: value
  defp literal(value) when is_list(value), do: value
  defp literal(_), do: :dynamic

  defp collect_statuses(forms) do
    Enum.flat_map(forms, fn
      {:defp, _, [head, [do: status]]} when is_integer(status) ->
        status_entries(head, status)

      _ ->
        []
    end)
  end

  defp status_entries({:when, _, [{:status_for, meta, [_]}, {:in, _, [_, list]}]}, status) do
    for atom <- atoms_in(list) do
      %{atom: atom, status: status, line: meta[:line]}
    end
  end

  defp status_entries({:status_for, meta, [atom]}, status) when is_atom(atom) do
    [%{atom: atom, status: status, line: meta[:line]}]
  end

  defp status_entries(_, _), do: []

  defp atoms_in({:__block__, _, values}), do: Enum.flat_map(values, &atoms_in/1)
  defp atoms_in(atom) when is_atom(atom), do: [atom]
  defp atoms_in(list) when is_list(list), do: Enum.flat_map(list, &atoms_in/1)
  defp atoms_in(_), do: []

  defp text_errors(file, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      Regex.scan(~r/\{:error,\s*:([a-z_][a-z0-9_]*)/, line)
      |> Enum.map(fn [_, atom] -> %{atom: String.to_atom(atom), line: number, file: file} end)
    end)
    |> Enum.uniq_by(&{&1.atom, &1.line})
  end

  defp text_stores(file, lines, attrs) do
    table =
      case get_in(attrs, ["table", :value]) do
        atom when is_atom(atom) -> atom
        _ -> nil
      end

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      Regex.scan(~r/Path\.join\(dir,\s*"([^"]+)"\)/, line)
      |> Enum.map(fn [_, name] ->
        %{file: name, table: table, line: number, module: nil, source: file}
      end)
    end)
  end

  # ---- parsing: tests -----------------------------------------------------

  defp parse_tests(modules) do
    Path.wildcard(Path.join(root(), "test/**/*_test.exs"))
    |> Enum.sort()
    |> Enum.map(&parse_test(&1, modules))
  end

  defp parse_test(path, _modules) do
    rel_path = rel(path)
    text = File.read!(path)
    lines = String.split(text, "\n")
    claims = header_claims(lines)

    {module_name, aliases, names} =
      case Code.string_to_quoted(text, columns: true, token_metadata: true) do
        {:ok, ast} ->
          mod =
            Macro.prewalk(ast, nil, fn
              {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, nil ->
                {node, Enum.join(parts, ".")}

              node, acc ->
                {node, acc}
            end)
            |> elem(1)

          aliases =
            Macro.prewalk(ast, %{}, fn
              {:alias, _, [arg]}, acc -> {arg, add_alias(acc, arg, [])}
              {:alias, _, [arg, opts]}, acc -> {arg, add_alias(acc, arg, opts)}
              node, acc -> {node, acc}
            end)
            |> elem(1)

          names =
            Macro.prewalk(ast, [], fn
              {:test, meta, [name | _]} = node, acc when is_binary(name) ->
                {node, [%{name: name, line: meta[:line]} | acc]}

              node, acc ->
                {node, acc}
            end)
            |> elem(1)

          {mod, aliases, Enum.reverse(names)}

        _ ->
          {nil, %{}, []}
      end

    modules_in_file =
      aliases
      |> Map.values()
      |> Enum.filter(&String.starts_with?(&1, "Junderground"))
      |> Kernel.++(
        Regex.scan(~r/Junderground(?:\.[A-Z][A-Za-z0-9_]*)+/, text)
        |> Enum.map(fn [m] -> m end)
      )
      |> Enum.uniq()

    %{
      file: rel_path,
      module: module_name,
      line: 1,
      claims: claims,
      aliases: aliases,
      modules: modules_in_file,
      tests: names,
      text: text
    }
  rescue
    error ->
      %{
        file: rel(path),
        module: nil,
        line: 1,
        claims: [],
        aliases: %{},
        modules: [],
        tests: [],
        text: "",
        error: Exception.message(error)
      }
  end

  defp header_claims(lines) do
    lines
    |> Enum.take(40)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^#\s*tests-for:\s*(.+)$/, line) do
        [_, value] -> String.split(value, ~r/\s+/, trim: true)
        _ -> []
      end
    end)
  end

  # ---- parsing: config ----------------------------------------------------

  defp parse_config do
    path = Path.join(root(), "config/runtime.exs")

    if File.exists?(path) do
      text = File.read!(path)

      case Code.string_to_quoted(text, columns: true, token_metadata: true) do
        {:ok, ast} ->
          {_, entries} =
            Macro.prewalk(ast, [], fn
              {:config, meta, [:junderground, kw]} = node, acc when is_list(kw) ->
                rows =
                  if Keyword.keyword?(kw) do
                    for {key, value} <- kw do
                      envs = env_names(value)

                      %{
                        key: key,
                        env: List.first(envs),
                        envs: envs,
                        default: literal(value),
                        line: ast_line(value) || meta[:line],
                        file: "config/runtime.exs"
                      }
                    end
                  else
                    []
                  end

                {node, rows ++ acc}

              node, acc ->
                {node, acc}
            end)

          Enum.reverse(entries)

        _ ->
          []
      end
    else
      []
    end
  end

  defp env_names(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:System]}, :get_env]}, _, [name | _]} = node, acc
        when is_binary(name) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(names)
  end

  defp ast_line({_, meta, _}) when is_list(meta), do: meta[:line]
  defp ast_line(_), do: nil

  defp build_settings(modules, config) do
    readers =
      for m <- modules, s <- m.settings do
        Map.merge(s, %{module: m.name, file: m.file})
      end

    base =
      Enum.reduce(config, %{}, fn c, acc ->
        Map.put(acc, c.key, %{
          key: c.key,
          env: c.env,
          envs: c.envs,
          default: c.default,
          config_file: c.file,
          config_line: c.line,
          readers: [],
          readme: nil
        })
      end)

    base =
      Enum.reduce(readers, base, fn r, acc ->
        Map.update(
          acc,
          r.key,
          %{
            key: r.key,
            env: nil,
            envs: [],
            default: r.default,
            config_file: nil,
            config_line: nil,
            readers: [r],
            readme: nil
          },
          fn setting -> Map.update(setting, :readers, [r], &[r | &1]) end
        )
      end)

    readme = readme_envs()

    Enum.reduce(readme, base, fn row, acc ->
      key = env_key(row.env)

      Map.update(
        acc,
        key,
        %{
          key: key,
          env: row.env,
          envs: [row.env],
          default: row.default,
          config_file: nil,
          config_line: nil,
          readers: [],
          readme: row
        },
        fn setting -> Map.put(setting, :readme, row) end
      )
    end)
  end

  defp readme_envs do
    path = Path.join(root(), "README.md")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, number} ->
        case Regex.run(~r/^\|\s*`(JG_[A-Z0-9_]+|PORT)`\s*\|\s*`?([^|`]*)`?\s*\|\s*([^|]*)\|/, line) do
          [_, env, default, meaning] ->
            [
              %{
                env: env,
                default: String.trim(default),
                meaning: String.trim(meaning),
                line: number,
                file: "README.md"
              }
            ]

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  defp env_key(env) do
    env
    |> String.replace_prefix("JG_", "")
    |> String.downcase()
    |> String.to_atom()
  end

  # ---- parsing: errors ----------------------------------------------------

  defp build_errors(modules) do
    statuses =
      for m <- modules, s <- m.statuses do
        %{
          atom: s.atom,
          status: s.status,
          status_file: m.file,
          status_line: s.line
        }
      end

    producers =
      for m <- modules, e <- m.errors do
        %{atom: e.atom, file: e.file, line: e.line, module: m.name}
      end

    Enum.reduce(statuses ++ producers, %{}, fn
      %{status: status} = s, acc when is_integer(status) ->
        Map.update(
          acc,
          s.atom,
          %{
            atom: s.atom,
            status: status,
            status_file: s.status_file,
            status_line: s.status_line,
            producers: []
          },
          fn entry ->
            Map.merge(entry, %{
              status: status,
              status_file: s.status_file,
              status_line: s.status_line
            })
          end
        )

      p, acc ->
        Map.update(
          acc,
          p.atom,
          %{
            atom: p.atom,
            status: nil,
            status_file: nil,
            status_line: nil,
            producers: [%{file: p.file, line: p.line, module: p.module}]
          },
          fn entry ->
            Map.update(
              entry,
              :producers,
              [%{file: p.file, line: p.line, module: p.module}],
              &[%{file: p.file, line: p.line, module: p.module} | &1]
            )
          end
        )
    end)
  end

  # ---- parsing: Markdown --------------------------------------------------

  defp parse_docs do
    files =
      (Path.wildcard(Path.join(root(), "docs/**/*.md")) ++
         [Path.join(root(), "README.md"), Path.join(root(), "AGENTS.md")])
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(files, &parse_doc_file/1)
  end

  defp parse_doc_file(path) do
    rel_path = rel(path)
    text = File.read!(path)

    {entries, _fence} =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {line, number}, {acc, fence} ->
        trimmed = String.trim(line)

        cond do
          String.starts_with?(trimmed, "```") ->
            {acc, if(fence, do: nil, else: "```")}

          not is_nil(fence) ->
            {acc, fence}

          true ->
            case Regex.run(~r/^(#+)\s+(.+?)\s*#*\s*$/, line) do
              [_, hashes, title] ->
                title = String.trim(title)
                routes = heading_routes(title)

                entry = %{
                  file: rel_path,
                  line: number,
                  level: String.length(hashes),
                  title: title,
                  anchor: slug(title),
                  routes: routes
                }

                {[entry | acc], fence}

              _ ->
                {acc, fence}
            end
        end
      end)

    Enum.reverse(entries)
  end

  defp heading_routes(title) do
    Regex.scan(~r/`(GET|POST|PUT|DELETE|PATCH|ANY)\s+(\/[^`\s]*)`/, title)
    |> Enum.map(fn [_, method, path] -> %{method: method, path: path} end)
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end

  # ---- parsing: help topics ----------------------------------------------

  defp parse_help do
    Path.wildcard(Path.join(root(), "docs/help/*.md"))
    |> Enum.reject(&(Path.basename(&1) == "README.md"))
    |> Enum.sort()
    |> Enum.map(&parse_topic/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.id, &1})
  end

  defp parse_topic(path) do
    text = File.read!(path)
    lines = String.split(text, "\n")

    case lines do
      ["---" | rest] ->
        {head, tail} = Enum.split_while(rest, &(&1 != "---"))
        body = case tail do ["---" | more] -> Enum.join(more, "\n"); _ -> "" end
        fields = topic_fields(head)
        id = String.trim(Map.get(fields, "id", ""))

        if id == "" do
          nil
        else
          routes =
            fields
            |> Map.get("routes", "")
            |> split_list(";")
            |> Enum.flat_map(&parse_route_line/1)

          %{
            id: id,
            title: Map.get(fields, "title", id),
            summary: Map.get(fields, "summary", ""),
            sources: split_list(Map.get(fields, "sources", ""), ","),
            routes: routes,
            settings: split_list(Map.get(fields, "settings", ""), ";"),
            stores: split_list(Map.get(fields, "stores", ""), ";"),
            errors: split_list(Map.get(fields, "errors", ""), ";"),
            related: split_list(Map.get(fields, "related", ""), ";"),
            verified: Map.get(fields, "verified", ""),
            body: body,
            file: rel(path),
            line: 1
          }
        end

      _ ->
        nil
    end
  end

  defp topic_fields(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp split_list(value, separator) do
    value
    |> String.split(separator)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_route_line(line) do
    case Regex.run(~r/^(GET|POST|PUT|DELETE|PATCH|ANY)\s+(\S+)$/, line) do
      [_, method, path] -> [method <> " " <> path]
      _ -> [line]
    end
  end

  # ---- small helpers ------------------------------------------------------

  defp rel(path), do: Path.relative_to(path, root())

  defp normalize_path(path) do
    path
    |> to_string()
    |> String.trim()
    |> String.replace_prefix("./", "")
  end

  defp last_segment(name), do: name |> String.split(".") |> List.last()

  defp setting_key(name) do
    raw =
      name
      |> to_string()
      |> String.trim()
      |> String.replace_prefix(":", "")
      |> String.replace_prefix("JG_", "")
      |> String.downcase()

    case existing_atom(raw) do
      nil -> nil
      atom -> if Map.has_key?(settings(), atom), do: atom, else: nil
    end
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp parse_route_query(name) do
    name = String.trim(to_string(name))

    {method, path} =
      case Regex.run(~r/^(GET|POST|PUT|DELETE|PATCH|ANY)\s+(.+)$/, name) do
        [_, method, path] -> {method, String.trim(path)}
        _ -> {nil, name}
      end

    if path == "*" or String.starts_with?(path, "/") do
      {:ok, method, path}
    else
      :error
    end
  end

  defp route_path_match?(route_path, query) do
    cond do
      query == "*" -> true
      String.ends_with?(query, "*") -> String.starts_with?(route_path, String.trim_trailing(query, "*"))
      true -> route_path == query
    end
  end

  defp glob_match?(glob, path) do
    glob = if String.ends_with?(glob, "/"), do: glob <> "**", else: glob

    pattern =
      glob
      |> String.split("/")
      |> Enum.map(fn
        "**" -> ".*"
        part -> part |> Regex.escape() |> String.replace("\\*", "[^/]*")
      end)
      |> Enum.join("/")

    Regex.match?(Regex.compile!("^" <> pattern <> "$"), path)
  rescue
    _ -> false
  end

  defp dedupe_by(list, fun) do
    list
    |> Enum.reduce({[], MapSet.new()}, fn item, {acc, seen} ->
      key = fun.(item)

      case MapSet.member?(seen, key) do
        true -> {acc, seen}
        false -> {[item | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
