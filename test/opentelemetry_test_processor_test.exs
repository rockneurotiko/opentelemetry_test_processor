defmodule OpenTelemetryTestProcessorTest do
  use ExUnit.Case, async: true
  doctest OpenTelemetryTestProcessor

  alias OpenTelemetryTestProcessor, as: OtelTest
  alias OpenTelemetryTestProcessor.Span
  require Span

  alias OpenTelemetry.Tracer
  require Tracer

  setup {OtelTest, :set_from_context}

  test "span without start is not received" do
    # Don't call OtelTest.start()
    Tracer.with_span "should not receive" do
      Tracer.set_status(:ok)
    end

    refute_receive {:trace_span, _}, 100
  end

  test "receive when start" do
    OtelTest.start()

    attributes = %{"key" => "value", "inner.key" => 123}

    Tracer.with_span "test span" do
      Tracer.set_status(:ok)
      Tracer.set_attributes(attributes)
      Tracer.add_event("test event", %{"event.key" => "event_value"})
      :ok
    end

    assert_receive {:trace_span, span}

    assert %Span{
             name: "test span",
             status: %{status: :ok, message: ""},
             attributes: ^attributes,
             events: events
           } =
             span

    assert [%{type: "test event", attributes: %{"event.key" => "event_value"}}] = events
  end

  test "error span" do
    OtelTest.start()

    attributes = %{"key" => "value_error", "inner.key" => 321}

    Tracer.with_span "test span" do
      Tracer.set_status(:error, "Something went wrong")
      Tracer.set_attributes(attributes)
      Tracer.add_event("test error event", %{"event.key" => "event_value"})
      :ok
    end

    assert_receive {:trace_span, span}

    assert %Span{
             name: "test span",
             status: %{status: :error, message: "Something went wrong"},
             attributes: ^attributes,
             events: events
           } =
             span

    assert [%{type: "test error event", attributes: %{"event.key" => "event_value"}}] = events
  end

  test "multiple spans in sequence" do
    OtelTest.start()

    Tracer.with_span "first span" do
      Tracer.set_status(:ok)
    end

    Tracer.with_span "second span" do
      Tracer.set_status(:ok)
    end

    Tracer.with_span "third span" do
      Tracer.set_status(:error, "Failed")
    end

    assert_receive {:trace_span, %Span{name: "first span"}}
    assert_receive {:trace_span, %Span{name: "second span"}}
    assert_receive {:trace_span, %Span{name: "third span", status: %{status: :error}}}
  end

  test "span with no events" do
    OtelTest.start()

    Tracer.with_span "span without events" do
      Tracer.set_status(:ok)
      Tracer.set_attributes(%{"key" => "value"})
    end

    assert_receive {:trace_span, span}
    assert %Span{name: "span without events", events: []} = span
  end

  test "span with multiple events" do
    OtelTest.start()

    Tracer.with_span "span with multiple events" do
      Tracer.add_event("event 1", %{"e1" => "v1"})
      Tracer.add_event("event 2", %{"e2" => "v2"})
      Tracer.add_event("event 3", %{"e3" => "v3"})
    end

    assert_receive {:trace_span, span}
    assert %Span{events: events} = span
    assert length(events) == 3
    assert Enum.any?(events, fn e -> e.type == "event 1" end)
    assert Enum.any?(events, fn e -> e.type == "event 2" end)
    assert Enum.any?(events, fn e -> e.type == "event 3" end)
  end

  test "allow/2 permits non-child process to send spans" do
    OtelTest.start()

    test_pid = self()

    spawn(fn ->
      OtelTest.allow(test_pid, self())

      Tracer.with_span "spawned process span" do
        Tracer.set_status(:ok)
      end
    end)

    assert_receive {:trace_span, %Span{name: "spawned process span"}}, 1000
  end

  test "child process automatically inherits permissions via Task" do
    OtelTest.start()

    task =
      Task.async(fn ->
        Tracer.with_span "task span" do
          Tracer.set_attributes(%{"from" => "task"})
          Tracer.set_status(:ok)
        end

        :done
      end)

    Task.await(task)

    assert_receive {:trace_span, %Span{name: "task span", attributes: %{"from" => "task"}}}
  end

  test "multiple concurrent processes with allow" do
    OtelTest.start()

    test_pid = self()

    for i <- 1..3 do
      spawn(fn ->
        OtelTest.allow(test_pid, self())

        Tracer.with_span "concurrent span #{i}" do
          Tracer.set_status(:ok)
        end
      end)
    end

    assert_receive {:trace_span, %Span{name: "concurrent span " <> _}}, 1000
    assert_receive {:trace_span, %Span{name: "concurrent span " <> _}}, 1000
    assert_receive {:trace_span, %Span{name: "concurrent span " <> _}}, 1000
  end

  test "nested spans" do
    OtelTest.start()

    Tracer.with_span "parent span" do
      Tracer.set_attributes(%{"level" => "parent"})

      Tracer.with_span "child span" do
        Tracer.set_attributes(%{"level" => "child"})
      end
    end

    assert_receive {:trace_span, %Span{name: "child span", attributes: %{"level" => "child"}}}
    assert_receive {:trace_span, %Span{name: "parent span", attributes: %{"level" => "parent"}}}
  end

  test "span with empty attributes" do
    OtelTest.start()

    Tracer.with_span "span with no attributes" do
      Tracer.set_status(:ok)
    end

    assert_receive {:trace_span, %Span{name: "span with no attributes"}}
  end

  describe "mode management" do
    test "set_private allows independent test isolation" do
      OtelTest.set_private()
      OtelTest.start()

      Tracer.with_span "private mode span" do
        Tracer.set_status(:ok)
      end

      assert_receive {:trace_span, %Span{name: "private mode span"}}
    end

    test "set_global raises error when async: true" do
      assert_raise RuntimeError,
                   ~r/cannot be set to global mode when the ExUnit case is async/,
                   fn ->
                     OtelTest.set_global(%{async: true})
                   end
    end

    test "set_from_context chooses private when async: true" do
      assert :ok = OtelTest.set_from_context(%{async: true})
    end
  end

  test "OTel pipeline remains stable when owner process dies before span ends" do
    # Start a separate process as the owner
    owner =
      spawn(fn ->
        OtelTest.start()
        # Signal readiness then wait to be killed
        receive do
          :die -> :ok
        end
      end)

    # Wait for it to register as owner
    Process.sleep(50)

    # Allow the current test process to verify pipeline stability
    OtelTest.allow(owner, self())

    # Kill the owner
    Process.exit(owner, :kill)
    Process.sleep(50)

    # Completing a span after the owner is dead should NOT crash the pipeline.
    # The span is silently dropped (no owner found after cleanup).
    Tracer.with_span "span after owner died" do
      Tracer.set_status(:ok)
    end

    # The test process itself was allowed but the owner is gone, so no span arrives.
    refute_receive {:trace_span, _}, 200
  end

  test "allow/2 called inside spawned process works when span ends after allow" do
    OtelTest.start()
    test_pid = self()

    spawn(fn ->
      # allow/2 must be called before the span ends. Since on_end/2 runs
      # synchronously in the same process as the span, this pattern is safe:
      # allow first, then create the span.
      OtelTest.allow(test_pid, self())

      Tracer.with_span "safe allow span" do
        Tracer.set_status(:ok)
      end
    end)

    assert_receive {:trace_span, %Span{name: "safe allow span"}}, 1000
  end

  describe "Span struct" do
    test "original_span field contains raw OpenTelemetry span" do
      OtelTest.start()

      Tracer.with_span "test original span" do
        Tracer.set_status(:ok)
      end

      assert_receive {:trace_span, span}
      assert %Span{original_span: original} = span
      # Span record
      assert Span.span(name: "test original span") = original
    end

    test "span status is properly extracted" do
      OtelTest.start()

      Tracer.with_span "status test" do
        Tracer.set_status(:ok)
      end

      assert_receive {:trace_span, span}
      assert %Span{status: %{status: :ok, message: ""}} = span
    end

    test "span attributes are properly extracted" do
      OtelTest.start()

      attrs = %{"string" => "value", "number" => 42, "bool" => true}

      Tracer.with_span "attributes test" do
        Tracer.set_attributes(attrs)
      end

      assert_receive {:trace_span, span}
      assert %Span{attributes: ^attrs} = span
    end

    test "span IDs are populated for root and child spans" do
      OtelTest.start()

      Tracer.with_span "parent id test" do
        Tracer.with_span "child id test" do
          :ok
        end
      end

      assert_receive {:trace_span, %Span{name: "child id test"} = child}
      assert_receive {:trace_span, %Span{name: "parent id test"} = parent}

      # Trace IDs should match (same trace)
      assert child.trace_id == parent.trace_id
      assert is_integer(child.trace_id) and child.trace_id != 0

      # Span IDs should be distinct non-zero integers
      assert is_integer(child.span_id) and child.span_id != 0
      assert is_integer(parent.span_id) and parent.span_id != 0
      assert child.span_id != parent.span_id

      # Child's parent_span_id should equal parent's span_id
      assert child.parent_span_id == parent.span_id

      # Root span has no parent
      assert parent.parent_span_id == :undefined
    end
  end
end
