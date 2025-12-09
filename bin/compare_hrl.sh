#!/usr/bin/env bash

# no output, but stop if fails
mix deps.get > /dev/null 2>&1

if [ $? -ne 0 ]; then
  echo "✖ Failed to get dependencies"
  exit 1
fi

diff include/otel_span.hrl deps/opentelemetry/include/otel_span.hrl

if [ $? -ne 0 ]; then
  echo "✖ The otel_span.hrl files differ between include/ and deps/opentelemetry/include/"
  exit 1
else
  echo "✅ The otel_span.hrl files are identical"
  exit 0
fi
