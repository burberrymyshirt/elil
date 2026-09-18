defmodule Elil.Utils do
  defmodule SourceLocation do
    defstruct [:file_path, :row, :column]
  end

  defmacro todo(msg \\ "Not implemented") do
    caller = __CALLER__
    file = caller.file
    mod = caller.module
    {func, arity} = caller.function
    line = caller.line

    quote do
      "#{unquote(file)}:#{unquote(line)}: #{unquote(mod)}.#{unquote(func)}/#{unquote(arity)} TODO: #{unquote(msg)}"
      |> IO.puts()

      exit({:shutdown, 1})
    end
  end

  defmacro unreachable() do
    caller = __CALLER__
    file = caller.file
    mod = caller.module
    {func, arity} = caller.function
    line = caller.line

    quote do
      "#{unquote(file)}:#{unquote(line)}: #{unquote(mod)}.#{unquote(func)}/#{unquote(arity)} UNREACHABLE}"
      |> IO.puts()

      exit({:shutdown, 1})
    end
  end

  def dump(v) do
    IO.inspect(v)
    v
  end

  @default_usage_msg "Usage: elixir elil.exs <input_file> ..."

  def print_usage(message) when is_binary(message), do: print_usage([message])

  def print_usage(message) when is_list(message) do
    List.pop_at(message, 0)
    |> print_usage()
  end

  def print_usage({message, _rest})
      when is_list(message) and length(message) === 0
      when is_nil(message) do
    IO.puts(@default_usage_msg)
  end

  def print_usage({message, rest}) when is_binary(message) do
    IO.puts(message)
    print_usage(rest)
  end

  defmacro is_numeric(char) do
    quote do
      unquote(char) in ?0..?9
    end
  end

  defmacro is_whitespace(char) do
    quote do
      unquote(char) in [?\n, ?\r, ?\s, ?\t]
    end
  end

  def time_compare_with_logging({first, first_args}, {second, second_args}) do
    {{first_res, first_time}, {second_res, second_time}} =
      time_compare({first, first_args}, {second, second_args})

    IO.puts("Compared two functions\n")
    IO.puts("==================================\n")
    IO.puts("First function result:")
    IO.puts("\tTime in microseconds: #{first_time}\n")
    IO.puts("Second function result:")
    IO.puts("\tTime in microseconds: #{second_time}\n")

    {{first_res, first_time}, {second_res, second_time}}
  end

  def time_compare({first, first_args}, {second, second_args})
      when is_function(first) and is_function(second) and is_list(first_args) and
             is_list(second_args) do
    first_start = System.monotonic_time(:microsecond)
    first_res = apply(first, first_args)
    first_end = System.monotonic_time(:microsecond)

    second_start = System.monotonic_time(:microsecond)
    second_res = apply(second, second_args)
    second_end = System.monotonic_time(:microsecond)
    {{first_res, first_end - first_start}, {second_res, second_end - second_start}}
  end
end
