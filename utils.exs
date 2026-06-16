defmodule Utils do
  defmacro todo(msg \\ "Not implemented") do
    caller = __CALLER__
    file = caller.file
    mod = caller.module
    {func, arity} = caller.function
    line = caller.line
    quote do
      "#{unquote(file)}:#{unquote line} #{unquote mod}.#{unquote func}/#{unquote arity} TODO: #{unquote(msg)}"
        |> IO.puts
      exit :shutdown
    end
  end

  def dump(v), do: IO.inspect(v)

  @default_usage_msg "Usage: elixir elil.exs [input_file]"

  def print_usage(message) when is_binary(message), do: print_usage [message]

  def print_usage(message) when is_list(message) do
    List.pop_at(message, 0)
      |> print_usage()
  end

  def print_usage({message, _rest})
    when is_list(message) and length(message) == 0
    when is_nil(message) do
    IO.puts @default_usage_msg
  end

  def print_usage({message, rest}) when is_binary(message) do
    IO.puts message
    print_usage rest
  end

  def error_log(msg) when is_bitstring(msg) do
    # TODO: maybe make into macro and accept row and column for proper error logging
    IO.puts(msg)
  end

  defmacro is_whitespace(char) do
    quote do
      unquote(char) === "\s" or
      unquote(char) === "\t" or
      unquote(char) === "\n" or
      unquote(char) === "\r"
    end
  end

  defmacro is_numeric(char) do
    quote do
      unquote(char) === "0" or
      unquote(char) === "1" or
      unquote(char) === "2" or
      unquote(char) === "3" or
      unquote(char) === "4" or
      unquote(char) === "5" or
      unquote(char) === "6" or
      unquote(char) === "7" or
      unquote(char) === "8" or
      unquote(char) === "9"
    end
  end
end
