# Audit the tier-1 help topics against the tree they describe.
#
#   elixir scripts/help_audit.exs
#   elixir scripts/help_audit.exs --quiet
#   elixir scripts/help_audit.exs --strict
#   elixir scripts/help_audit.exs --all
#   elixir scripts/help_audit.exs --json
#
# It reads the same tree as where.exs and agent_help.exs, so it never boots the
# application or opens a DETS file. Hard errors are broken bindings (a source,
# route, setting, store, error atom or related id that does not exist), an
# uncovered router route, a duplicate topic id, or a test without a
# `# tests-for:` header. A stale `verified` date, a setting with no runtime
# entry or README row, and version drift are warnings; --strict makes them fail.

Code.require_file("jg_index.exs", __DIR__)

defmodule JGTool.HelpAudit do
  alias JGTool.Index

  @known_gap MapSet.new([])

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          quiet: :boolean,
          strict: :boolean,
          all: :boolean,
          json: :boolean,
          check: :boolean,
          help: :boolean
        ]
      )

    cond do
      invalid != [] or args != [] ->
        usage(2)

      opts[:help] ->
        usage(0)

      true ->
        report = audit()

        if opts[:json] do
          IO.puts(
            JSON.encode!(%{
              topics: report.topics,
              routes: report.routes,
              settings: report.settings,
              stores: report.stores,
              errors: report.errors,
              warnings: report.warnings,
              failures: report.failures
            })
          )
        else
          print_report(report, opts)
        end

        failed = report.failures != [] || (opts[:strict] && report.warnings != [])
        System.halt(if failed, do: 1, else: 0)
    end
  end

  def audit do
    help = Index.help()
    topics = help |> Map.values() |> Enum.sort_by(& &1.id)
    route_keys = Index.routes() |> Enum.map(&route_key/1) |> MapSet.new()

    {failures, warnings} =
      Enum.reduce(topics, {[], []}, fn topic, {failures, warnings} ->
        {f, w} = audit_topic(topic, help, route_keys)
        {failures ++ f, warnings ++ w}
      end)

    covered =
      topics
      |> Enum.flat_map(& &1.routes)
      |> MapSet.new()

    missing = MapSet.difference(route_keys, covered)
    extra = MapSet.difference(covered, route_keys)

    coverage_failures =
      Enum.map(missing, fn route ->
        unless MapSet.member?(@known_gap, route) do
          "route #{route} is not covered by any help topic"
        end
      end)
      |> Enum.reject(&is_nil/1)

    extra_failures = Enum.map(extra, &"help topic names a route that is not in router.ex: #{&1}")

    duplicate_failures = duplicate_ids()
    test_failures = test_headers()
    setting_warnings = setting_drift()
    version_warnings = version_drift()
    index_warnings = index_freshness()

    failures =
      failures ++ coverage_failures ++ extra_failures ++ duplicate_failures ++ test_failures

    warnings = warnings ++ setting_warnings ++ version_warnings ++ index_warnings

    %{
      topics: length(topics),
      routes: MapSet.size(route_keys),
      settings: map_size(Index.settings()),
      stores: length(Index.stores()),
      errors: map_size(Index.errors()),
      failures: Enum.uniq(failures),
      warnings: Enum.uniq(warnings),
      topic_rows:
        Enum.map(topics, fn t ->
          %{id: t.id, title: t.title, file: t.file, routes: length(t.routes)}
        end)
    }
  end

  defp audit_topic(topic, help, route_keys) do
    source_failures =
      topic.sources
      |> Enum.reject(&source_exists?/1)
      |> Enum.map(&"#{topic.id}: source does not exist: #{&1}")

    route_failures =
      topic.routes
      |> Enum.reject(&MapSet.member?(route_keys, &1))
      |> Enum.map(&"#{topic.id}: route is not in router.ex: #{&1}")

    setting_failures =
      topic.settings
      |> Enum.reject(&(not is_nil(Index.setting(&1))))
      |> Enum.map(&"#{topic.id}: setting does not exist: #{&1}")

    store_failures =
      topic.stores
      |> Enum.reject(&(Index.store(&1) != []))
      |> Enum.map(&"#{topic.id}: store does not exist: #{&1}")

    error_failures =
      topic.errors
      |> Enum.reject(&(not is_nil(Index.error(&1))))
      |> Enum.map(&"#{topic.id}: error atom does not exist: #{&1}")

    related_failures =
      topic.related
      |> Enum.reject(&Map.has_key?(help, &1))
      |> Enum.map(&"#{topic.id}: related topic does not exist: #{&1}")

    body_warnings =
      if String.trim(topic.body) == "" do
        ["#{topic.id}: body is empty"]
      else
        []
      end

    verified_warnings = verified_drift(topic)

    failures =
      source_failures ++ route_failures ++ setting_failures ++ store_failures ++
        error_failures ++ related_failures

    {failures, body_warnings ++ verified_warnings}
  end

  defp source_exists?(source) do
    path = Path.join(Index.root(), source)
    File.exists?(path) or Path.wildcard(path) != []
  end

  defp route_key(route), do: "#{route.method} #{route.path}"

  defp duplicate_ids do
    Path.wildcard(Path.join(Index.root(), "docs/help/*.md"))
    |> Enum.reject(&(Path.basename(&1) == "README.md"))
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.take(20)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^id:\s*(\S+)/, line) do
          [_, id] -> [{id, Path.relative_to(path, Index.root())}]
          _ -> []
        end
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {id, files} ->
      if length(files) > 1 do
        ["duplicate help topic id '#{id}' in #{Enum.join(files, ", ")}"]
      else
        []
      end
    end)
  end

  defp test_headers do
    Index.tests()
    |> Enum.reject(&(&1.claims != []))
    |> Enum.map(&"test file has no # tests-for: header: #{&1.file}")
  end

  defp setting_drift do
    Index.settings()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, setting} ->
      cond do
        key == :serve ->
          []

        is_nil(setting.config_file) ->
          ["setting :#{key} is read in code but not set in config/runtime.exs"]

        is_nil(setting.readme) ->
          ["setting :#{key} has no row in the README configuration table"]

        true ->
          []
      end
    end)
  end

  defp version_drift do
    mix_version = read_version("mix.exs", ~r/version:\s*"([^"]+)"/)
    app_version = read_version("lib/junderground.ex", ~r/@version\s+"([^"]+)"/)
    readme_version = read_version("README.md", ~r/Status:\s*\*\*v([0-9.]+)\*\*/)

    versions =
      [{"mix.exs", mix_version}, {"lib/junderground.ex", app_version}, {"README.md", readme_version}]
      |> Enum.reject(fn {_file, value} -> is_nil(value) end)

    values = versions |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if length(values) > 1 do
      [
        "version drift: " <>
          Enum.map_join(versions, ", ", fn {file, value} -> "#{file}=#{value}" end)
      ]
    else
      []
    end
  end

  defp read_version(file, regex) do
    path = Path.join(Index.root(), file)

    if File.exists?(path) do
      case Regex.run(regex, File.read!(path)) do
        [_, value] -> value
        _ -> nil
      end
    end
  end

  defp index_freshness do
    script = Path.join(Index.root(), "scripts/agent_help.exs")

    if File.exists?(script) do
      case System.cmd("elixir", ["scripts/agent_help.exs", "--check"],
             cd: Index.root(),
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          []

        {output, _status} ->
          [
            "docs/AGENT-INDEX.md is stale; run `elixir scripts/agent_help.exs --write-index`" <>
              if(String.trim(output) == "", do: "", else: " (#{String.slice(String.trim(output), 0, 300)})")
          ]
      end
    else
      []
    end
  end

  defp verified_drift(topic) do
    case Date.from_iso8601(topic.verified) do
      {:ok, verified} ->
        topic.sources
        |> Enum.flat_map(&source_files/1)
        |> Enum.flat_map(fn file ->
          case File.stat(Path.join(Index.root(), file)) do
            {:ok, stat} ->
              changed = stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_date()

              if Date.compare(changed, verified) == :gt do
                ["#{topic.id}: #{file} changed after verified (#{topic.verified})"]
              else
                []
              end

            _ ->
              []
          end
        end)

      _ ->
        ["#{topic.id}: verified is not an ISO date (#{inspect(topic.verified)})"]
    end
  end

  defp source_files(source) do
    path = Path.join(Index.root(), source)

    cond do
      File.regular?(path) ->
        [Path.relative_to(path, Index.root())]

      true ->
        Path.wildcard(path)
        |> Enum.map(&Path.relative_to(&1, Index.root()))
    end
  end

  defp print_report(report, opts) do
    unless opts[:quiet] do
      IO.puts(
        "help_audit: #{report.topics} topics, #{report.routes} routes, " <>
          "#{report.settings} settings, #{report.stores} stores, #{report.errors} error atoms"
      )
    end

    Enum.each(report.failures, &IO.puts("ERROR #{&1}"))
    Enum.each(report.warnings, &IO.puts("WARN  #{&1}"))

    if opts[:all] && !opts[:quiet] do
      IO.puts("")

      Enum.each(report.topic_rows, fn row ->
        IO.puts("ok    #{row.id}  #{row.title}  (#{row.routes} routes, #{row.file})")
      end)
    end

    unless opts[:quiet] do
      case report.failures do
        [] ->
          IO.puts("ok    #{report.topics} topics, every route covered")

        _ ->
          IO.puts("#{length(report.failures)} error(s), #{length(report.warnings)} warning(s)")
      end
    end
  end

  defp usage(code) do
    IO.puts("""
    usage: elixir scripts/help_audit.exs [options]

      Checks docs/help/*.md against the tree: sources, routes, settings,
      stores, error atoms, related ids, route coverage, duplicate ids,
      test headers, version drift and the generated agent index.

      --quiet   print only errors and warnings
      --strict  fail on warnings as well as errors
      --all     also list every topic that passed
      --json    machine-readable report
      --check   accepted for the pre-push hook; this is the default action
    """)

    System.halt(code)
  end
end

JGTool.HelpAudit.main(System.argv())
