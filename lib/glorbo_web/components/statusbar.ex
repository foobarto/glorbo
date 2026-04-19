defmodule GlorboWeb.Components.Statusbar do
  @moduledoc """
  Persistent bottom-row status bar (M1 mockup alignment —
  abc.zip shell.jsx:97-121).

  Renders, left → right:

    - Daemon state dot + uptime ("daemon alive · uptime 4d 12h 03m")
      or "daemon stopped".
    - Agents-running count ("3/6 agents running") — queries
      `Glorbo.Agent.Registry` match-spec (same technique as
      HealthLive).
    - SQLite WAL size — reads `glorbo.db` stat.
    - inotify watch-path count — introspects running
      `Glorbo.Filesystem.Watcher` processes.
    - Right side: director identity + wall-clock.

  The statusbar is static-at-render — it doesn't auto-tick. The
  underlying numbers change on the order of seconds, which is fine
  because the layout re-renders on every LV navigation. A live-
  ticking variant (own LiveComponent subscribing to PubSub) is a
  follow-up if the data is observed going stale.
  """
  use Phoenix.Component

  alias Glorbo.CLI.Lifecycle.Pidfile
  alias Glorbo.Filesystem.Hierarchy

  attr :rest, :global

  def statusbar(assigns) do
    state = collect_state()

    assigns = assign(assigns, :s, state)

    ~H"""
    <footer class="gl-statusbar" role="contentinfo" {@rest}>
      <span>
        <span class={[
          "gl-statusbar__dot",
          @s.daemon == :stopped && "gl-statusbar__dot--stopped"
        ]} /> {daemon_label(@s)}
      </span>
      <span class="gl-statusbar__sep">│</span>
      <span>{@s.agents_alive}/{@s.agents_total} agents running</span>
      <span class="gl-statusbar__sep">│</span>
      <span>
        sqlite WAL · {@s.sqlite_human}
      </span>
      <span class="gl-statusbar__sep">│</span>
      <span>
        <span :if={@s.watch_mode == :polling} class="gl-statusbar__warn">polling:</span>
        <span :if={@s.watch_mode != :polling}>inotify:</span> watching {@s.inotify_paths} paths
      </span>
      <span class="gl-statusbar__spacer"></span>
      <span>{@s.director}</span>
      <span class="gl-statusbar__sep">│</span>
      <time id="gl-statusbar-clock" phx-hook="ClockTick" datetime={@s.now_iso}>
        {@s.now_str}
      </time>
    </footer>
    """
  end

  # ---------------------------------------------------------------------------
  # Collectors — each is defensive; if anything errors we surface a
  # sensible fallback string rather than crash the layout.
  # ---------------------------------------------------------------------------

  defp collect_state do
    base = Hierarchy.default_root()

    %{
      daemon: daemon_status(base),
      uptime: uptime_str(base),
      agents_alive: agents_alive(),
      agents_total: agents_total(),
      sqlite_human: sqlite_size_human(base),
      inotify_paths: inotify_path_count(),
      watch_mode: watch_mode(),
      director: director_identity(),
      now_str: now_str(),
      now_iso: now_iso()
    }
  end

  defp daemon_status(base) do
    Pidfile.status(base)
  rescue
    _ -> :stopped
  catch
    _, _ -> :stopped
  end

  defp daemon_label(%{daemon: :running} = s), do: "daemon alive · uptime #{s.uptime}"
  defp daemon_label(%{daemon: :stale}), do: "daemon stale pidfile"
  defp daemon_label(_), do: "daemon stopped"

  # Pidfile mtime is a close-enough proxy for daemon start time — it's
  # written atomically on `glorbo up`. Formats into `4d 12h 03m` style.
  defp uptime_str(base) do
    case File.stat(Pidfile.path(base), time: :posix) do
      {:ok, %{mtime: mtime}} ->
        now = System.os_time(:second)
        diff = max(now - mtime, 0)
        format_uptime(diff)

      _ ->
        "—"
    end
  rescue
    _ -> "—"
  catch
    _, _ -> "—"
  end

  defp format_uptime(seconds) when is_integer(seconds) and seconds >= 0 do
    d = div(seconds, 86_400)
    rem1 = rem(seconds, 86_400)
    h = div(rem1, 3_600)
    rem2 = rem(rem1, 3_600)
    m = div(rem2, 60)

    cond do
      d > 0 ->
        "#{d}d #{h}h #{String.pad_leading(Integer.to_string(m), 2, "0")}m"

      h > 0 ->
        "#{h}h #{String.pad_leading(Integer.to_string(m), 2, "0")}m"

      true ->
        "#{m}m"
    end
  end

  defp agents_alive do
    Registry.count_match(Glorbo.Agent.Registry, {:company_child, :_, :agent_sup}, :_)
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp agents_total do
    base = Hierarchy.default_root()
    co_dir = Path.join(base, "companies")

    case File.ls(co_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.flat_map(fn slug ->
          agents_dir = Path.join([co_dir, slug, "agents"])

          case File.ls(agents_dir) do
            {:ok, ags} ->
              ags
              |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
              |> Enum.reject(&String.starts_with?(&1, "."))

            _ ->
              []
          end
        end)
        |> length()

      _ ->
        0
    end
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp sqlite_size_human(base) do
    case File.stat(Path.join(base, "glorbo.db")) do
      {:ok, %{size: size}} -> human_bytes(size)
      _ -> "—"
    end
  rescue
    _ -> "—"
  catch
    _, _ -> "—"
  end

  defp human_bytes(n) when is_integer(n) and n >= 0 do
    cond do
      n < 1_024 -> "#{n} B"
      n < 1_024 * 1_024 -> "#{Float.round(n / 1_024, 1)} KiB"
      n < 1_024 * 1_024 * 1_024 -> "#{Float.round(n / 1_024 / 1_024, 1)} MiB"
      true -> "#{Float.round(n / 1_024 / 1_024 / 1_024, 2)} GiB"
    end
  end

  defp inotify_path_count do
    # Count running file-watcher GenServers by their registry role.
    # Each running company has one watcher; a "path count" without
    # round-tripping into every watcher is a reasonable proxy.
    Registry.count_match(Glorbo.Agent.Registry, {:company_child, :_, :file_watcher}, :_)
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  # If any watcher is in polling mode, flag the whole fleet — it means
  # inotify isn't available on this host and every watcher will have
  # made the same fallback. Cheap: pick one watcher via the Registry
  # and ask it.
  defp watch_mode do
    case Registry.select(
           Glorbo.Agent.Registry,
           [{{{:company_child, :"$1", :file_watcher}, :"$2", :_}, [], [:"$2"]}]
         ) do
      [pid | _] when is_pid(pid) ->
        try do
          case Glorbo.Filesystem.Watcher.backend(pid) do
            :fs_poll -> :polling
            _ -> :inotify
          end
        catch
          _, _ -> :inotify
        end

      _ ->
        :inotify
    end
  rescue
    _ -> :inotify
  end

  defp director_identity do
    "#{System.get_env("USER") || "director"}@#{hostname()}"
  rescue
    _ -> "director@glorbo.local"
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "glorbo.local"
    end
  end

  defp now_str do
    Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")
  end

  defp now_iso, do: DateTime.to_iso8601(DateTime.utc_now())
end
