defmodule OpenTelemetryTestProcessorTest do
  use ExUnit.Case
  doctest OpenTelemetryTestProcessor

  alias OpenTelemetryTestProcessor, as: OtelTest
  alias OpenTelemetryTestProcessor.Span
  require Span

  alias OpenTelemetry.Tracer
  require Tracer

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

    test "set_global works without async" do
      assert :ok = OtelTest.set_global(%{})
      # Reset to private mode for test isolation
      OtelTest.set_private()
    end

    test "set_from_context chooses private when async: true" do
      assert :ok = OtelTest.set_from_context(%{async: true})
    end

    test "set_from_context chooses global when async: false" do
      assert :ok = OtelTest.set_from_context(%{async: false})
      # Reset to private mode for test isolation
      OtelTest.set_private()
    end
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
  end
end
