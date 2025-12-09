defmodule OpenTelemetryTestProcessor do
  @moduledoc """
  A test span processor that behaves like Mox for OpenTelemetry traces.

  ## Usage

  Setup the processor in your test config:

      config :opentelemetry,
        traces_exporter: :none,
        processors: [
          {OpenTelemetryTestProcessor, %{}}
        ]


  Tests must opt-in to receive spans:

      test "receives spans" do
        OpenTelemetryTestProcessor.start()

        # Your code that generates spans
        MyApp.do_something_traced()

        # Assert on received spans
        assert_receive {:trace_span, span}
      end

  Child processes of the test process are automatically allowed. For other
  processes, use `allow/2`:

      test "with async task" do
        OpenTelemetryTestProcessor.start()

        task = Task.async(fn ->
          OpenTelemetryTestProcessor.allow(self(), task_pid)
          MyApp.do_something_traced()
        end)

        assert_receive {:trace_span, span}
      end
  """

  @behaviour :otel_span_processor

  @timeout 5_000

  @this {:global, OpenTelemetryTestProcessor.Server}

  @type pid_or_name :: pid() | atom()
  defguardp is_pid_or_name(term) when is_pid(term) or is_atom(term)

  ## Public API

  @doc """
  Starts tracking spans for the given process.

  The process will receive all spans that are ended by itself or any of its
  child processes via `send(pid, {:trace_span, span})`.

  ## Examples

      test "my test" do
        OpenTelemetryTestProcessor.start()
        # ... test code that generates spans
        assert_receive {:trace_span, span}
      end
  """
  @spec start(pid_or_name()) :: :ok | {:error, term()}
  def start(owner_pid \\ self()) when is_pid_or_name(owner_pid) do
    owner_pid = find_pid(owner_pid)

    # Initialize ownership for this pid with :spans as the key
    case NimbleOwnership.get_and_update(
           @this,
           owner_pid,
           :spans,
           fn _ -> {:ok, %{}} end,
           @timeout
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Allows `allowed_pid` to use spans from `owner_pid`.

  When spans are ended by `allowed_pid`, they will be sent to `owner_pid`.
  This is useful for allowing non-child processes to participate in span tracking.

  ## Examples

      test "with explicit allow" do
        OpenTelemetryTestProcessor.start()

        spawn(fn ->
          OpenTelemetryTestProcessor.allow(self(), other_pid)
          MyApp.do_something_traced()
        end)

        assert_receive {:trace_span, span}
      end
  """
  @spec allow(pid_or_name(), pid_or_name()) :: :ok | {:error, term()}
  def allow(owner_pid, allowed_pid)
      when is_pid_or_name(owner_pid) and is_pid_or_name(allowed_pid) do
    owner_pid = find_pid(owner_pid)
    allowed_pid = find_pid(allowed_pid)

    case NimbleOwnership.allow(@this, owner_pid, allowed_pid, :spans, @timeout) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp find_pid(pid) when is_pid(pid), do: pid

  defp find_pid(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> name
      pid -> pid
    end
  end

  @doc """
  Sets the processor to private mode.

  In private mode, processes must explicitly opt-in with `start/1` and
  can allow other processes with `allow/2`. This is the default mode
  and is safe for `async: true` tests.

  ## Examples

      setup :set_private
  """
  @spec set_private(term()) :: :ok
  def set_private(_context \\ %{}) do
    NimbleOwnership.set_mode_to_private(@this)
  end

  @doc """
  Sets the processor to global mode.

  In global mode, all spans are sent to the shared owner process.
  Tests using global mode cannot be `async: true`.

  ## Examples

      setup :set_global
  """
  @spec set_global(term()) :: :ok
  def set_global(%{async: true}) do
    raise "OpenTelemetryTestProcessor cannot be set to global mode when the ExUnit case is async. " <>
            "Remove \"async: true\" when using ExUnit.Case"
  end

  def set_global(_context) do
    NimbleOwnership.set_mode_to_shared(@this, self())
  end

  @doc """
  Chooses the processor mode based on context.

  When `async: true` is used, `set_private/1` is called,
  otherwise `set_global/1` is used.

  ## Examples

      setup :set_from_context
  """
  @spec set_from_context(term()) :: :ok
  def set_from_context(%{async: true} = _context), do: set_private()
  def set_from_context(context), do: set_global(context)

  ## Behaviour implementation

  def start_link(_config) do
    # Start the NimbleOwnership server if it's not already running
    case NimbleOwnership.start_link(name: @this) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @impl :otel_span_processor
  def processor_init(_pid, config), do: config

  @impl :otel_span_processor
  def on_start(_ctx, span, _config), do: span

  @impl :otel_span_processor
  def on_end(span, _config) do
    # Get the current process and its callers (parent processes)
    # This allows child processes to automatically inherit permissions
    callers = [self() | caller_pids()]

    # Try to find the owner process that started tracking
    case NimbleOwnership.fetch_owner(@this, callers, :spans, @timeout) do
      {:ok, owner_pid} ->
        # Send the span to the owner
        forward_span(owner_pid, span)

      {:shared_owner, owner_pid} ->
        # In shared mode, send to the shared owner
        forward_span(owner_pid, span)

      :error ->
        # No owner found, this process hasn't opted in to receive spans
        :ok
    end

    true
  end

  @impl :otel_span_processor
  def force_flush(_config), do: :ok

  ## Private helpers

  defp forward_span(owner_pid, otel_span) do
    span = OpenTelemetryTestProcessor.Span.from_otel_span(otel_span)
    send(owner_pid, {:trace_span, span})
  end

  # Get the list of caller PIDs from the process dictionary
  # This is automatically set by Task and other OTP behaviors
  defp caller_pids do
    case Process.get(:"$callers") do
      nil -> []
      pids when is_list(pids) -> pids
    end
  end
end
