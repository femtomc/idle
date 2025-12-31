defmodule IdleRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :idle_runtime,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {IdleRuntime.Application, []}
    ]
  end

  defp deps do
    [
      {:absynthe, path: "../../absynthe"},
      {:jason, "~> 1.4"}
      # NOTE: Burrito removed due to typed_struct/typedstruct conflict
      # Burrito depends on typed_struct, absynthe's decibel depends on typedstruct
      # Both define TypedStruct module. Revisit when upstream resolves this.
    ]
  end

  defp releases do
    [
      idle: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
