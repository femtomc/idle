defmodule IdleRuntimeTest do
  use ExUnit.Case
  doctest IdleRuntime

  test "greets the world" do
    assert IdleRuntime.hello() == :world
  end
end
