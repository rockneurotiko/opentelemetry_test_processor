defmodule OpentelemetryTestProcessor.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/rockneurotiko/opentelemetry_test_processor"

  def project do
    [
      app: :opentelemetry_test_processor,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A test OpenTelemetry span processor for Elixir",
      dialyzer: dialyzer(),
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_api, "~> 1.5"},
      {:nimble_ownership, "~> 1.0"},
      # Development
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Release deps
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:iex, :mix],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp docs do
    [
      main: "OpenTelemetryTestProcessor",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      files: [
        "lib/**/*.ex",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "VERSION",
        "LICENSE"
      ],
      licenses: ["Beerware"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Rock Neurotiko"]
    ]
  end
end
