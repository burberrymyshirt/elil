defmodule Elil.Evaluator do
  require Elil.Utils
  import Elil.Utils
  alias Elil.Lexer, as: Lexer
  alias Elil.Parser.Node, as: Node

  defguard is_scope_type(type) when type in [:root, :scope]

  def eval(file) do
    # TODO: error handling
    case File.exists?(file) do
      true ->
        {:ok, fd} = File.open(file, [:utf8, :read_ahead])
        eval(fd, file)

      false ->
        eval(to_string(file), "eval()")
    end

    todo()
  end

  def eval(file, file_path) when is_pid(file) or is_atom(file) do
    # WANT: we just assume file is a valid atom or pid, so add validate_file or something
    IO.read(file, :eof) |> eval(file_path)
  end

  def eval(file, file_path) when is_binary(file) do
    {:ok, lexer_pid} = GenServer.start_link(Lexer, {file_path, file}, hibernate_after: 100)
    {:ok, root_node} = Elil.Parser.parse(lexer_pid)
    %Node{type: :root} = root_node
    GenServer.stop(lexer_pid)

    do_eval(root_node)
  end

  defp do_eval(%Node{type: :root} = node) do
    eval_node(node)
  end

  defp eval_node(%Node{type: :root, body: nil} = node) do
    eval_params(node)
  end

  defp eval_node(%Node{type: :scope, body: nil} = node) do
    eval_params(node)
  end

  defp eval_node(%Node{type: :expr} = node) do
    eval_expr(node)
  end

  defp eval_node(%Node{type: :lit} = node) do
    eval_lit(node)
  end

  defp eval_params(%Node{type: type, body: nil} = node) when is_scope_type(type) do
    Enum.map(node.params, &eval_node/1)
  end

  defp eval_expr(%Node{type: :expr} = node) do
    eval_func(node.body, node.params)
  end

  defp eval_func(func, args) when is_binary(func) and is_list(args) do
    # TODO: add meta data from parser to report arity/variadic parameters
    #  Right now we just ignore parameters when there are more than the function needs
    case func do
      "add" ->
        Enum.map(args, fn
          v -> r = eval_node(v)
          |> to_string()
          |> Integer.parse(10)
          {r, _} = r
          r
        end)
        |> Enum.reduce(0, fn
          v, acc when is_integer(v) -> v + acc
          v, _acc -> Elil.Logger.error_log_and_die("function add() expects only integers as arguments, got #{v}")
        end)

      "echo" ->
        Enum.map(args, &eval_node/1)
        |> Enum.map(&IO.write/1)

      "eval" ->
        [arg | _] = args

        eval_node(arg)
        |> eval()

      # TODO: add meta data from parser, so we can report line numbers
      #  see error logging in todo.txt
      _ ->
        Elil.Logger.error_log_and_die("undefined function: #{func}")
    end
  end

  defp eval_lit(%Node{type: :lit} = node) do
    node.body
  end
end
