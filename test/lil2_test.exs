defmodule Lil2Test do
  use ExUnit.Case
  doctest Lil2

  test "greets the world" do
    assert Lil2.hello() == :world
  end
end
