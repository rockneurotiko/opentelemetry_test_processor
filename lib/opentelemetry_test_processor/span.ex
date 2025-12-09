defmodule OpenTelemetryTestProcessor.Span do
  @moduledoc """
  A struct representing an OpenTelemetry span for testing purposes.

  This module provides a simplified, test-friendly representation of OpenTelemetry spans.
  It extracts the most commonly needed fields from the raw OpenTelemetry span record
  and presents them in an easy-to-use struct format.

  ## Fields

  * `:name` - The name of the span (string)
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
  @span_fields Record.extract(:span, from: "deps/opentelemetry/include/otel_span.hrl")
  # Define macros for `Span`.
  Record.defrecord(:span, @span_fields)

  @event_fields Record.extract(:event, from: "deps/opentelemetry/include/otel_span.hrl")
  Record.defrecord(:event, @event_fields)

  @type status :: %{status: OpenTelemetry.status_code(), message: String.t() | nil}
  @type t :: %__MODULE__{
          name: String.t(),
          status: status(),
          attributes: %{optional(String.t()) => any()},
          events: [map()],
          original_span: any()
        }

  defstruct [:name, :status, :attributes, :events, :original_span]

  def from_otel_span(span(name: name) = span) do
    %__MODULE__{
      name: name,
      status: maybe_extract(span, :status),
      attributes: maybe_extract(span, :attributes),
      events: maybe_extract(span, :events),
      original_span: span
    }
  end

  defp maybe_extract(span(status: status), :status) do
    case status do
      {:status, status, status_message} -> %{status: status, message: status_message}
      _ -> %{status: :unset, message: ""}
    end
  end

  defp maybe_extract(span(attributes: attributes), :attributes) do
    case attributes do
      {:attributes, _, _, _, attributes} -> attributes
      _ -> nil
    end
  end

  defp maybe_extract(span(events: events), :events) do
    case events do
      {:events, _, _, _, _, events} -> Enum.map(events || [], &maybe_extract(&1, :full_event))
      _ -> []
    end
  end

  defp maybe_extract(event(name: name, attributes: attributes), :full_event) do
    case attributes do
      {:attributes, _, _, _, attributes} -> %{attributes: attributes, type: name}
      _ -> nil
    end
  end

  defp maybe_extract(_span, _field), do: nil
end
