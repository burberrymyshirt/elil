defmodule Elil.Evaluator do
  require Elil.Utils
  import Elil.Utils
  alias Elil.Lexer, as: Lexer
  alias Elil.Parser.Node, as: Node

  defmodule Context do
    use GenServer

    defstruct lets: %{}

    def put_let(pid, %Node{type: :let} = node) when is_pid(pid) do
      # everything lives in a global namespace for now.
      # @see global_namespace
      GenServer.call(pid, {:put_let, node})
    end

    def get_let(pid, %Node{type: :ident} = node) when is_pid(pid) do
      # everything lives in a global namespace for now.
      # @see gloabl_namespace
      get_let(pid, node.body)
    end

    def get_let(pid, name) when is_pid(pid) do
      # everything lives in a global namespace for now.
      # @see gloabl_namespace
      GenServer.call(pid, {:get_let, name})
    end

    @impl true
    def init(_initial) do
      {:ok, struct!(Context)}
    end

    @impl true
    def handle_call({:put_let, %Node{type: :let} = node}, _from, %Context{} = state) do
      case Map.has_key?(state.lets, node.body) do
        true ->
          {:reply, :already_exists, state}

        false ->
          # use the variable name as the key
          lets = Map.put_new(state.lets, node.body, node)
          {:reply, :ok, struct!(state, lets: lets)}
      end
    end

    def handle_call({:get_let, name}, _from, %Context{} = state) do
      case Map.get(state.lets, name) do
        nil ->
          {:reply, :undefined, state}

        %Node{} = node ->
          {:reply, {:ok, node}, state}
      end
    end
  end

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

    {:ok, context_pid} = GenServer.start_link(Context, [])

    # TODO: if we bubble errors up to the surface through returns, we can handle errors properly here.
    #  I don't really wanna use exceptions. I feel like they might be a crutch for a poor recursive design.
    #  Although that might be wrong and exceptions are just the way to go. Who knows.

    do_eval(context_pid, root_node)

    GenServer.stop(context_pid)
  end

  defp do_eval(pid, %Node{type: :root} = node) when is_pid(pid) do
    eval_node(pid, node)
  end

  defp eval_node(pid, %Node{type: :root, body: nil} = node) when is_pid(pid) do
    eval_params(pid, node)
  end

  defp eval_node(pid, %Node{type: :scope, body: nil} = node) when is_pid(pid) do
    eval_params(pid, node)
  end

  defp eval_node(pid, %Node{type: :expr} = node) when is_pid(pid) do
    eval_expr(pid, node)
  end

  defp eval_node(pid, %Node{type: :lit} = node) when is_pid(pid) do
    eval_lit(pid, node)
  end

  defp eval_node(pid, %Node{type: :let} = node) when is_pid(pid) do
    eval_let(pid, node)
  end

  # an ident from the parser is expected to be a name of a variable or function.
  defp eval_node(pid, %Node{type: :ident} = node) when is_pid(pid) do
    eval_ident(pid, node)
  end

  defp eval_params(pid, %Node{type: type, body: nil} = node)
       when is_pid(pid) and is_scope_type(type) do
    Enum.map(node.params, &eval_node(pid, &1))
  end

  # TODO: could be merged with the eval_params/2 above, idk if it is actually important that the body is nil.
  #  I just wanna assert as much as possible right now. I don't know if we need named scopes in the future,
  #  but in that case I would like to keep the assert for now so I know where refactoring is needed.
  defp eval_params(pid, %Node{type: :let} = node) when is_pid(pid) do
    Enum.map(node.params, &eval_node(pid, &1))
  end

  defp eval_expr(pid, %Node{type: :expr} = node) when is_pid(pid) do
    eval_func(pid, node.body, node.params)
  end

  defp eval_func(pid, func, args) when is_binary(func) and is_list(args) and is_pid(pid) do
    # TODO: add meta data from parser to report arity/variadic parameters
    #  Right now we just ignore parameters when there are more than the function needs
    case func do
      "let" ->
        todo("move keywords to separate eval function maybe? idk.")
        todo("implement let bindings")

      "fn" ->
        todo("implement let bindings")

      "add" ->
        Enum.map(args, fn v ->
          eval_node(pid, v)
          |> to_string()
          |> Integer.parse(10)
          |> elem(0)
        end)
        |> Enum.reduce(0, fn
          v, acc when is_integer(v) ->
            v + acc

          v, _acc ->
            Elil.Logger.error_log_and_die(
              "function add() expects only integers as arguments, got #{v}"
            )
        end)

      "sub" ->
        Enum.map(args, fn
          v ->
            eval_node(pid, v)
            |> to_string()
            |> Integer.parse(10)
            |> elem(0)
        end)
        |> Enum.reduce(fn
          v, acc when is_integer(v) ->
            acc - v

          v, _acc ->
            Elil.Logger.error_log_and_die(
              "function add() expects only integers as arguments, got #{v}"
            )
        end)

      "echo" ->
        Enum.map(args, &eval_node(pid, &1))
        |> Enum.map(&IO.write/1)

      "eval" ->
        [arg | _] = args

        eval_node(pid, arg)
        |> eval()

      # TODO: add meta data from parser, so we can report line numbers
      #  @see logging errors in todo.txt
      _ ->
        Elil.Logger.error_log_and_die("undefined function: \"#{func}\"")
    end
  end

  defp eval_lit(pid, %Node{type: :lit} = node) when is_pid(pid) do
    node.body
  end

  defp eval_let(pid, %Node{type: :let} = node) when is_pid(pid) do
    case Context.put_let(pid, node) do
      {:already_exists} ->
        # TODO: add meta data from parser, so we can report line numbers
        #  @see logging errors in todo.txt
        Elil.Logger.error_log_and_die(
          "variable \"#{to_string(node.body)}\" has already been previously defined"
        )

      _ ->
        {:ok}
    end
  end

  defp eval_ident(pid, %Node{type: :ident} = node) when is_pid(pid) do
    case Context.get_let(pid, node) do
      {:undefined} ->
        # TODO: add meta data from parser, so we can report line numbers
        #  @see logging errors in todo.txt
        Elil.Logger.error_log_and_die("variable \"#{to_string(node.body)}\" is undefined")

      {:ok, %Node{type: :let} = node} ->
        eval_params(pid, node)
    end
  end
end
