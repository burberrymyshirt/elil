defmodule Utils do
  defmacro todo(msg \\ "Not implemented") do
    file = __CALLER__.file
    mod = __CALLER__.module
    {func, arity} = __CALLER__.function
    line = __CALLER__.line
    quote do
      "[#{unquote(file)}:#{unquote line} #{unquote mod}.#{unquote func}/#{unquote arity}] TODO: #{unquote(msg)}"
        |> IO.puts
      exit :shutdown
    end
  end
end
