defmodule OpenTelemetryTestProcessor.Span do
  @moduledoc """
  A struct representing an OpenTelemetry span for testing purposes.

  This module provides a simplified, test-friendly representation of OpenTelemetry spans.
  It extracts the most commonly needed fields from the raw OpenTelemetry span record
  and presents them in an easy-to-use struct format.

  ## Fields

  * `:name` - The name of the span (string)
  * `:trace_id` - The 128-bit integer trace ID
  * `:span_id` - The 64-bit integer span ID
  * `:parent_span_id` - The 64-bit integer parent span ID (nil for root spans)
  * `:status` - A map containing:
    * `:status` - The status code (`:ok`, `:error`, or `:unset`)
    * `:message` - An optional status message (string or empty string)
  * `:attributes` - A map of span attributes (key-value pairs)
  * `:events` - A list of event maps, each containing:
    * `:type` - The event name/type (string)
    * `:attributes` - Event-specific attributes (map)
  * `:original_span` - The raw OpenTelemetry span record for advanced use cases

  ## Usage

  When you receive a span message in your tests, it will already be converted
  to this struct format:

      test "receive span" do
        OpentelemetryTestProcessor.start()

        Tracer.with_span "my span" do
          Tracer.set_status(:ok)
          Tracer.set_attributes(%{"key" => "value"})
          Tracer.add_event("my event", %{"event_key" => "event_value"})
        end

        assert_receive {:trace_span, span}
        assert %OpentelemetryTestProcessor.Span{} = span
        assert span.name == "my span"
        assert span.status == %{status: :ok, message: ""}
        assert span.attributes == %{"key" => "value"}
        assert [%{type: "my event", attributes: %{"event_key" => "event_value"}}] = span.events
      end

  ## Accessing the Original Span

  For advanced use cases where you need access to fields not included in the
  simplified struct, you can access the raw OpenTelemetry span record via
  the `:original_span` field.

  And you can use the "span" record to extract information:

      require OpenTelemetryTestProcessor.Span
      Span.span(name: name) = span.original_span
  """

  require Record

  @span_fields Record.extract(:span, from: "./include/otel_span.hrl")
  # Define macros for `Span`.
  Record.defrecord(:span, @span_fields)

  @event_fields Record.extract(:event, from: "./include/otel_span.hrl")
  Record.defrecord(:event, @event_fields)

  @status_fields Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  Record.defrecord(:status, @status_fields)

  @type status :: %{status: OpenTelemetry.status_code(), message: String.t() | nil}
  @type t :: %__MODULE__{
          name: String.t(),
          trace_id: non_neg_integer() | nil,
          span_id: non_neg_integer() | nil,
          parent_span_id: non_neg_integer() | nil,
          status: status(),
          attributes: %{optional(String.t()) => any()},
          events: [map()],
          original_span: any()
        }

  defstruct [
    :name,
    :trace_id,
    :span_id,
    :parent_span_id,
    :status,
    :attributes,
    :events,
    :original_span
  ]

  def from_otel_span(
        span(
          name: name,
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: parent_span_id,
          status: raw_status,
          attributes: raw_attributes,
          events: raw_events
        ) = otel_span
      ) do
    %__MODULE__{
      name: name,
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: parent_span_id,
      status: extract_status(raw_status),
      attributes: extract_attributes(raw_attributes),
      events: extract_events(raw_events),
      original_span: otel_span
    }
  end

  defp extract_status(raw) do
    case raw do
      status(code: code, message: message) -> %{status: code, message: message}
      _ -> %{status: :unset, message: ""}
    end
  end

  defp extract_attributes(raw) do
    case raw do
      nil -> nil
      _ -> :otel_attributes.map(raw)
    end
  end

  defp extract_events(raw) do
    case raw do
      nil ->
        []

      _ ->
        raw
        |> :otel_events.list()
        |> Enum.map(&extract_event/1)
    end
  end

  defp extract_event(event(name: name, attributes: raw_attributes)) do
    %{type: name, attributes: :otel_attributes.map(raw_attributes)}
  end
end
