# OpenTelemetryTestProcessor

A test span processor that behaves like Mox for OpenTelemetry traces. Test your OpenTelemetry instrumentation with the same ease and safety as you test other dependencies.

## Features

- **Explicit Opt-in**: Tests must explicitly call `start/1` to receive spans, preventing test pollution
- **Process Isolation**: Safe for `async: true` tests with private mode (default)
- **Child Process Support**: Automatically inherits permissions for spawned tasks and processes
- **Flexible Ownership**: Use `allow/2` to permit specific processes to send spans
- **Clean API**: Receive spans as messages with `assert_receive {:trace_span, span}`
- **Rich Span Data**: Access span name, status, attributes, events, and the original OpenTelemetry span

## Installation

Add `opentelemetry_test_processor` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:opentelemetry_test_processor, "~> 0.1.0", only: :test}
  ]
end
```

## Configuration

Configure the processor in your test environment (`config/test.exs`):

```elixir
config :opentelemetry,
  traces_exporter: :none,
  processors: [
    {OpenTelemetryTestProcessor, %{}}
  ]
```

This disables the default exporter and sets up the test processor to capture spans in your tests.

## Usage

### Basic Usage

Tests must explicitly opt-in to receive spans by calling `OpenTelemetryTestProcessor.start/0`:

```elixir
defmodule MyAppTest do
  use ExUnit.Case
  alias OpenTelemetryTestProcessor, as: OtelTest
  alias OpenTelemetry.Tracer
  require Tracer

  test "receives spans from traced code" do
    OtelTest.start()

    # Your code that generates spans
    Tracer.with_span "my operation" do
      Tracer.set_status(:ok)
      Tracer.set_attributes(%{"user_id" => 123})
    end

    # Assert on received spans
    assert_receive {:trace_span, span}
    assert span.name == "my operation"
    assert span.status == %{status: :ok, message: ""}
    assert span.attributes == %{"user_id" => 123}
  end
end
```

### Testing Span Attributes

```elixir
test "validates span attributes" do
  OtelTest.start()

  attributes = %{"key" => "value", "count" => 42}

  Tracer.with_span "test span" do
    Tracer.set_attributes(attributes)
  end

  assert_receive {:trace_span, span}
  assert span.attributes == attributes
end
```

### Testing Span Events

```elixir
test "captures span events" do
  OtelTest.start()

  Tracer.with_span "operation with events" do
    Tracer.add_event("processing started", %{"item_count" => 10})
    Tracer.add_event("processing completed", %{"duration_ms" => 150})
  end

  assert_receive {:trace_span, span}
  assert length(span.events) == 2
  assert Enum.any?(span.events, fn e -> e.type == "processing started" end)
end
```

### Testing Error Spans

```elixir
test "captures error spans" do
  OtelTest.start()

  Tracer.with_span "failing operation" do
    Tracer.set_status(:error, "Something went wrong")
  end

  assert_receive {:trace_span, span}
  assert span.status == %{status: :error, message: "Something went wrong"}
end
```

### Testing Nested Spans

```elixir
test "handles nested spans" do
  OtelTest.start()

  Tracer.with_span "parent operation" do
    Tracer.set_attributes(%{"level" => "parent"})

    Tracer.with_span "child operation" do
      Tracer.set_attributes(%{"level" => "child"})
    end
  end

  # Child span completes first
  assert_receive {:trace_span, %{name: "child operation"}}
  # Then parent span
  assert_receive {:trace_span, %{name: "parent operation"}}
end
```

### Working with Child Processes

Child processes automatically inherit span tracking permissions:

```elixir
test "child processes via Task" do
  OtelTest.start()

  task = Task.async(fn ->
    Tracer.with_span "task operation" do
      Tracer.set_status(:ok)
    end
  end)

  Task.await(task)
  assert_receive {:trace_span, %{name: "task operation"}}
end
```

### Allowing Non-Child Processes

For processes that aren't direct children, use `allow/2`:

```elixir
test "with spawned process" do
  OtelTest.start()
  test_pid = self()

  spawn(fn ->
    OtelTest.allow(test_pid, self())

    Tracer.with_span "spawned operation" do
      Tracer.set_status(:ok)
    end
  end)

  assert_receive {:trace_span, %{name: "spawned operation"}}, 1000
end
```

### Mode Management

#### Private Mode (Default)

Private mode is the default and is safe for `async: true` tests. Each test must explicitly call `start/1`:

```elixir
setup :set_private

test "isolated test" do
  OtelTest.start()
  # ... test code
end
```

#### Global Mode

Global mode sends all spans to a shared owner process. **Cannot be used with `async: true`**:

```elixir
# In your test module
use ExUnit.Case, async: false

setup :set_global

test "shared spans" do
  # No need to call start/1 in global mode
  # ... test code
end
```

#### Context-Based Mode

Automatically choose the mode based on the test context:

```elixir
setup :set_from_context
```

This uses private mode for `async: true` tests and global mode otherwise.

## API Reference

### OpenTelemetryTestProcessor

#### `start(owner_pid \\ self())`

Starts tracking spans for the given process. The process will receive all spans that are ended by itself or any of its child processes.

Returns: `:ok | {:error, term()}`

#### `allow(owner_pid, allowed_pid)`

Allows `allowed_pid` to use spans from `owner_pid`. When spans are ended by `allowed_pid`, they will be sent to `owner_pid`.

Returns: `:ok | {:error, term()}`

#### `set_private(context \\ %{})`

Sets the processor to private mode. Processes must explicitly opt-in with `start/1`. Safe for `async: true` tests.

#### `set_global(context)`

Sets the processor to global mode. All spans are sent to the shared owner process. Cannot be used with `async: true` tests.

#### `set_from_context(context)`

Chooses the processor mode based on context. Uses `set_private/1` when `async: true`, otherwise `set_global/1`.

### OpenTelemetryTestProcessor.Span

The span struct sent to test processes contains:

- `name` - The span name (string)
- `status` - A map with `status` (atom: `:ok`, `:error`, `:unset`) and `message` (string)
- `attributes` - A map of span attributes
- `events` - A list of event maps with `type` and `attributes` keys
- `original_span` - The raw OpenTelemetry span record for advanced use cases

## Examples

### Testing a Service with Multiple Spans

```elixir
defmodule MyApp.UserService do
  alias OpenTelemetry.Tracer
  require Tracer

  def create_user(params) do
    Tracer.with_span "create_user" do
      Tracer.set_attributes(%{"user_email" => params.email})

      Tracer.with_span "validate_user" do
        # validation logic
      end

      Tracer.with_span "save_user" do
        # save logic
      end

      Tracer.set_status(:ok)
      {:ok, %User{}}
    end
  end
end

defmodule MyApp.UserServiceTest do
  use ExUnit.Case
  alias OpenTelemetryTestProcessor, as: OtelTest

  test "create_user generates proper spans" do
    OtelTest.start()

    MyApp.UserService.create_user(%{email: "test@example.com"})

    # Receive spans in order of completion
    assert_receive {:trace_span, %{name: "validate_user"}}
    assert_receive {:trace_span, %{name: "save_user"}}
    assert_receive {:trace_span, %{name: "create_user", status: %{status: :ok}}}
  end
end
```

### Testing Multiple Sequential Operations

```elixir
test "multiple operations" do
  OtelTest.start()

  Enum.each(1..3, fn i ->
    Tracer.with_span "operation_#{i}" do
      Tracer.set_attributes(%{"index" => i})
    end
  end)

  assert_receive {:trace_span, %{name: "operation_1", attributes: %{"index" => 1}}}
  assert_receive {:trace_span, %{name: "operation_2", attributes: %{"index" => 2}}}
  assert_receive {:trace_span, %{name: "operation_3", attributes: %{"index" => 3}}}
end
```

## Troubleshooting

### Spans Not Being Received

If you're not receiving spans in your tests:

1. Ensure you've configured the processor in `config/test.exs`
2. Call `OtelTest.start()` at the beginning of your test
3. Check that the code generating spans is actually being executed
4. Use `assert_receive` with a timeout: `assert_receive {:trace_span, _}, 1000`

### Async Test Issues

If you're getting errors about global mode with async tests:

- Remove `async: true` from your test module when using `set_global/1`
- Or use `set_private/1` or `set_from_context/1` instead

### Process Permission Issues

If spawned processes aren't sending spans:

- Use `Task.async` instead of `spawn` (automatic permission inheritance)
- Or explicitly call `allow/2` to grant permission

## License

[Your License Here]

## Contributing

[Your Contributing Guidelines Here]
