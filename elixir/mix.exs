defmodule Portraiture.MixProject do
  use Mix.Project

  def project do
    [
      app: :portraiture,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  # Portraiture is zero-dependency and does not use the Logger application;
  # logging is exposed as a plain callback option instead.
  def application do
    []
  end
end
