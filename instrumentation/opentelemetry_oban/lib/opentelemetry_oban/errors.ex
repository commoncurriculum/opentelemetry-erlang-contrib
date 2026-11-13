defmodule OpentelemetryOban.Errors do
  @moduledoc false

  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.Span
  alias OpenTelemetry.Tracer

  # `Exception.normalize/3` turns Erlang-style reasons (`:badarg`, `:undef`, ...) into Elixir
  # exception structs, so `Span.record_exception/4` can record `exception.message`. Reasons that
  # cannot be normalized (`:throw` and `:exit` kinds) fall back to the Erlang API, which accepts
  # any term but records no message.
  def record_exception(ctx, kind, reason, stacktrace) do
    case Exception.normalize(kind, reason, stacktrace) do
      %{__exception__: true} = exception ->
        Span.record_exception(ctx, exception, stacktrace, [])
        exception

      not_an_exception ->
        :otel_span.record_exception(ctx, kind, reason, stacktrace, [])
        not_an_exception
    end
  end

  def set_error_type(%struct_name{} = error) when is_exception(error),
    do: Tracer.set_attribute(ErrorAttributes.error_type(), inspect(struct_name))

  def set_error_type(_error), do: :ok
end
