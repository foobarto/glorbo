defmodule Glorbo.Ollama.Pull do
  @moduledoc """
  Model download orchestration for Ollama (GEP-67, Phase 3).

  Runs `ollama pull <model>` host-side, **one at a time** (D9 — concurrent
  multi-GB pulls contend for disk + bandwidth; further requests queue),
  and streams progress to subscribers of the `"ollama:pulls"` PubSub
  topic as `{:ollama_pull, event}` where `event` is one of:

      {:started,  model}
      {:progress, model, percent}   # 0..100
      {:done,     model}
      {:error,    model, reason}
      {:cancelled, model}

  ## Pull safety (D10)

  The model name is user/UI-controlled, and the pull runs host-side,
  OUTSIDE the agent sandbox (D4) — so an unvalidated name in a shell
  string would be host RCE. Two defences:

    1. `validate_model/1` rejects anything outside Ollama's
       `[registry/][namespace/]name[:tag]` grammar (and any `..`) BEFORE
       exec.
    2. The name is passed as a single discrete argv element via
       `MuonTrap.Daemon` (execve — no shell), after `--` so a crafted
       name can never be read as an `ollama` flag.

  Both the spawn and the clock are injectable so the queue + parsing are
  tested without a real Ollama (`:spawn_fun`, `:pubsub`).
  """

  use GenServer

  alias Glorbo.Ollama.Detect

  @topic "ollama:pulls"

  # Ollama model ref: an optional `registry/` and/or `namespace/` prefix,
  # a `name`, and an optional `:tag`. Lowercase alnum + `.`/`_`/`-`/`/`,
  # each path segment starting alnum. `..` is rejected separately.
  @model_re ~r/^[a-z0-9][a-z0-9._-]*(\/[a-z0-9][a-z0-9._-]*){0,2}(:[a-z0-9][a-z0-9._-]*)?$/
  @max_model_len 200

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "PubSub topic carrying `{:ollama_pull, event}` messages."
  def topic, do: @topic

  @doc """
  Validate a user-supplied Ollama model ref against the `name[:tag]`
  grammar (with optional `registry/namespace/` prefix). Returns `:ok` or
  `{:error, :invalid_model}`. Rejects shell metacharacters, flags, path
  traversal, whitespace, and over-long input.
  """
  @spec validate_model(term()) :: :ok | {:error, :invalid_model}
  def validate_model(model)
      when is_binary(model) and byte_size(model) > 0 and byte_size(model) <= @max_model_len do
    if Regex.match?(@model_re, model) and not String.contains?(model, "..") do
      :ok
    else
      {:error, :invalid_model}
    end
  end

  def validate_model(_), do: {:error, :invalid_model}

  @doc """
  Queue a model pull. Validates the name first; a valid name is enqueued
  (and started if nothing is pulling). Progress arrives on `topic/0`.
  """
  @spec pull(GenServer.server(), String.t()) :: :ok | {:error, :invalid_model}
  def pull(server \\ __MODULE__, model) do
    case validate_model(model) do
      :ok -> GenServer.call(server, {:pull, model})
      err -> err
    end
  end

  @doc "Cancel a model pull — the in-flight one (kills the child) or a queued one."
  @spec cancel(GenServer.server(), String.t()) :: :ok
  def cancel(server \\ __MODULE__, model), do: GenServer.call(server, {:cancel, model})

  @doc "Current pull (`model` or `nil`) + the queued model list."
  @spec state(GenServer.server()) :: %{current: String.t() | nil, queue: [String.t()]}
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc false
  # Parse one line of `ollama pull` output into a percent, or nil. Public
  # for unit testing; ollama prints e.g. `pulling abc... 42% ▕██▏ ...`.
  def parse_percent(line) when is_binary(line) do
    case Regex.run(~r/\b(\d{1,3})%/, line) do
      [_, pct] -> min(String.to_integer(pct), 100)
      _ -> nil
    end
  end

  def parse_percent(_), do: nil

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      current: nil,
      child_pid: nil,
      child_ref: nil,
      queue: :queue.new(),
      pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub),
      spawn_fun: Keyword.get(opts, :spawn_fun, &default_spawn/2),
      stop_fun: Keyword.get(opts, :stop_fun, &default_stop/1)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:pull, model}, _from, state) do
    cond do
      state.current == model or queued?(state, model) ->
        {:reply, :ok, state}

      state.current == nil ->
        {:reply, :ok, start_pull(state, model)}

      true ->
        {:reply, :ok, %{state | queue: :queue.in(model, state.queue)}}
    end
  end

  def handle_call({:cancel, model}, _from, %{current: model} = state) do
    if is_reference(state.child_ref), do: Process.demonitor(state.child_ref, [:flush])
    if is_pid(state.child_pid), do: state.stop_fun.(state.child_pid)
    publish(state, {:cancelled, model})
    {:reply, :ok, advance(%{state | current: nil, child_pid: nil, child_ref: nil})}
  end

  def handle_call({:cancel, model}, _from, state) do
    {:reply, :ok, %{state | queue: :queue.delete(model, state.queue)}}
  end

  def handle_call(:state, _from, state) do
    {:reply, %{current: state.current, queue: :queue.to_list(state.queue)}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{child_ref: ref, current: model} = state) do
    event = if reason in [:normal, :shutdown], do: {:done, model}, else: {:error, model, reason}
    publish(state, event)
    {:noreply, advance(%{state | current: nil, child_pid: nil, child_ref: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp queued?(state, model), do: :queue.member(model, state.queue)

  defp start_pull(state, model) do
    logger_fun = fn line ->
      case parse_percent(line) do
        nil -> :ok
        pct -> publish(state, {:progress, model, pct})
      end
    end

    case state.spawn_fun.(model, logger_fun) do
      {:ok, pid} when is_pid(pid) ->
        ref = Process.monitor(pid)
        publish(state, {:started, model})
        %{state | current: model, child_pid: pid, child_ref: ref}

      {:error, reason} ->
        publish(state, {:error, model, reason})
        advance(state)
    end
  end

  # Start the next queued pull, if any.
  defp advance(state) do
    case :queue.out(state.queue) do
      {{:value, model}, rest} -> start_pull(%{state | queue: rest}, model)
      {:empty, _} -> state
    end
  end

  defp publish(state, event) do
    Phoenix.PubSub.broadcast(state.pubsub, @topic, {:ollama_pull, event})
  end

  defp default_stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  # Real spawn: `ollama pull -- <model>` as a MuonTrap.Daemon child
  # (process group bound to the BEAM; killed on cancel/shutdown). `--`
  # ends option parsing so a crafted (but validated) name can't be read
  # as a flag. `logger_fun` streams each output line through the parser.
  defp default_spawn(model, logger_fun) do
    case Detect.binary_path() do
      path when is_binary(path) ->
        MuonTrap.Daemon.start_link(path, ["pull", "--", model],
          logger_fun: logger_fun,
          stderr_to_stdout: true
        )

      _ ->
        {:error, :not_installed}
    end
  end
end
