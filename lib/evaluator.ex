defmodule Elil.Evaluator do
  require Elil.Utils
  import Elil.Utils
  alias Elil.Lexer, as: Lexer
  alias Elil.Parser.Node, as: Node

  defmodule Value do
    @enforce_keys [:type]
    defstruct [
      :type,
      :value
    ]

    defmodule Type do
      @compile {:inline, int: 0, void: 0, str: 0}
      def int(), do: :int
      def void(), do: :void
      def str(), do: :str
    end

    defimpl String.Chars, for: __MODULE__ do
      def to_string(%Value{type: :void}) do
        ""
      end

      def to_string(%Value{} = value) do
        Kernel.to_string(value.value)
      end
    end

    def new(value, wanted_type)

    def new(_v, :void) do
      struct!(Value, type: Type.void())
    end

    def new(v, :str) when not is_nil(v) do
      struct!(Value, type: Type.str(), value: to_string(v))
    end

    def new(v, :int) when not is_nil(v) do
      v =
        case v do
          v when is_integer(v) -> v
          # TODO: handle more than just base 10
          v when is_binary(v) -> Integer.parse(v, 10) |> elem(0)
          # TODO: handle more than just base 10
          v when is_list(v) -> Integer.parse(List.to_string(v), 10) |> elem(0)
          v -> Elil.Logger.error_log_and_die("unable to parse value \"#{v}\" to an integer")
        end

      struct!(Value, type: Type.int(), value: v)
    end
  end

  defmodule Context do
    use GenServer

    defmodule Scope do
      defstruct lets: %{}
    end

    defstruct scopes: []

    def push_scope(pid), do: GenServer.call(pid, {:push_scope})

    def pop_scope(pid), do: GenServer.call(pid, {:pop_scope})

    def put_let(pid, %Node{type: :let} = node) when is_pid(pid) do
      GenServer.call(pid, {:put_let, node})
    end

    def get_let(pid, %Node{type: :ident} = node) when is_pid(pid) do
      get_let(pid, node.body)
    end

    def get_let(pid, name) when is_pid(pid) do
      GenServer.call(pid, {:get_let, name})
    end

    @impl true
    def init(_initial) do
      {:ok, struct!(Context)}
    end

    @impl true
    def handle_call({:push_scope}, _from, %Context{} = state) do
      state = struct!(state, scopes: [struct!(Scope) | state.scopes])
      {:reply, {:ok}, state}
    end

    @impl true
    def handle_call({:pop_scope}, _from, %Context{} = state) do
      [_ | scopes] = state.scopes
      state = struct!(state, scopes: scopes)
      {:reply, {:ok}, state}
    end

    @impl true
    def handle_call({:put_let, %Node{type: :let} = node}, _from, %Context{} = state) do
      # TODO: make local variables when we introduce functions
      [scope | rest_scopes] = state.scopes

      case Map.has_key?(scope.lets, node.body) do
        true ->
          {:reply, :already_exists, state}

        false ->
          # use the variable name as the key
          lets = Map.put_new(scope.lets, node.body, node)
          scope = struct!(scope, lets: lets)
          {:reply, :ok, struct!(state, scopes: [scope | rest_scopes])}
      end
    end

    @impl true
    def handle_call({:get_let, name}, _from, %Context{} = state) do
      # TODO: make local variables when we introduce functions
      case do_get_let(name, state.scopes) do
        {:undefined} ->
          {:reply, {:undefined}, state}

        {:ok, %Node{} = node} ->
          {:reply, {:ok, node}, state}
      end
    end

    defp do_get_let(name, scopes) when is_binary(name) and is_list(scopes) do
      [scope | rest_scopes] = scopes

      case Map.get(scope.lets, name) do
        nil ->
          case 0 === length(rest_scopes) do
            true -> {:undefined}
            false -> do_get_let(name, rest_scopes)
          end

        %Node{} = node ->
          {:ok, node}
      end
    end
  end

  defguard is_scope_type(type) when type in [:root, :scope]
  defguard is_lit(type) when type in [:dqstr, :int]

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
    if (Elil.Cmd.get_option_bool("print_file_path")) do
      IO.puts("Evaluating file: "<>file_path)
    end
    {:ok, lexer_pid} = GenServer.start_link(Lexer, {file_path, file}, hibernate_after: 100)
    {:ok, root_node} = Elil.Parser.parse(lexer_pid)
    GenServer.stop(lexer_pid)
    %Node{type: :root} = root_node

    if Elil.Cmd.get_option_bool("print_ast") do
      IO.inspect(root_node)
    else
      {:ok, context_pid} = GenServer.start_link(Context, [])

      # TODO: if we bubble errors up to the surface through returns, we can handle errors properly here.
      #  I don't really wanna use exceptions. I feel like they might be a crutch for a poor recursive design.
      #  Although that might be wrong and exceptions are just the way to go. Who knows.

      do_eval(context_pid, root_node)

      GenServer.stop(context_pid)
    end

    :ok
  end

  defp do_eval(pid, %Node{type: :root} = node) when is_pid(pid) do
    eval_node(pid, node)
  end

  defp eval_node(pid, %Node{type: :root, body: nil} = node) when is_pid(pid) do
    {:ok} = Context.push_scope(pid)
    eval_params(pid, node)
    {:ok} = Context.pop_scope(pid)
  end

  defp eval_node(pid, %Node{type: :scope, body: nil} = node) when is_pid(pid) do
    {:ok} = Context.push_scope(pid)
    eval_params(pid, node)
    {:ok} = Context.pop_scope(pid)
  end

  defp eval_node(pid, %Node{type: :expr} = node) when is_pid(pid) do
    eval_expr(pid, node)
  end

  defp eval_node(pid, %Node{type: type} = node) when is_pid(pid) and is_lit(type) do
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

    node.params
    |> Enum.map(&eval_node(pid, &1))
  end

  # TODO: could be merged with the eval_params/2 above, idk if it is actually important that the body is nil.
  #  I just wanna assert as much as possible right now. I don't know if we need named scopes in the future,
  #  but in that case I would like to keep the assert for now so I know where refactoring is needed.
  defp eval_params(pid, %Node{type: :let} = node) when is_pid(pid) do
    node.params
    |> Enum.map(&eval_node(pid, &1))
  end

  defp eval_expr(pid, %Node{type: :expr} = node) when is_pid(pid) do
    eval_func(pid, node.body, node.params)
  end

  defp eval_func(pid, func, args) when is_binary(func) and is_list(args) and is_pid(pid) do
    # TODO: add meta data from parser to report arity/variadic parameters
    #  Right now we just ignore parameters when there are more than the function needs
    case func do
      "fn" ->
        todo("implement let bindings")

      "add" ->
        Enum.map(args, fn v ->
          eval_node(pid, v)
          |> to_string()
          |> Integer.parse(10)
        end)
        |> Enum.reduce(0, fn
          {v, rem}, _acc when is_list(rem) and length(rem) > 0 ->
            Elil.Logger.error_log_and_die(
              "function add() expects only integers as arguments, got #{v}"
            )

          {v, _rem}, acc when is_integer(v) ->
            v + acc

          v, _acc ->
            Elil.Logger.error_log_and_die(
              "function add() expects only integers as arguments, got #{v}"
            )
        end)
        |> Value.new(Value.Type.int())

      "sub" ->
        Enum.map(args, fn
          v ->
            eval_node(pid, v)
            |> to_string()
            |> Integer.parse(10)
        end)
        |> Enum.reduce(0, fn
          {v, rem}, _acc when is_list(rem) and length(rem) > 0 ->
            Elil.Logger.error_log_and_die(
              "function sub() expects only integers as arguments, got #{v}"
            )

          {v, _rem}, acc when is_integer(v) ->
            v + acc

          v, _acc ->
            Elil.Logger.error_log_and_die(
              "function sub() expects only integers as arguments, got #{v}"
            )
        end)
        |> Value.new(Value.Type.int())

      "echo" ->
        Enum.map(args, &eval_node(pid, &1))
        |> Enum.map(&to_string/1)
        |> Enum.map(&IO.write/1)
        |> Value.new(Value.Type.void())

      "eval" ->
        # TODO: make it fail if more are given or something.
        [arg | _] = args

        %Value{type: :str} = value = eval_node(pid, arg)
        value
        |> then(&(&1.value))
        |> eval()
        |> Value.new(Value.Type.void())

      # TODO: add meta data from parser, so we can report line numbers
      #  @see logging errors in todo.txt
      _ ->
        Elil.Logger.error_log_and_die("undefined function: \"#{func}\"")
    end
  end

  defp eval_lit(pid, %Node{type: :int} = node) when is_pid(pid) do
    Value.new(node.body, Value.Type.int())
  end

  defp eval_lit(pid, %Node{type: :dqstr} = node) when is_pid(pid) do
    # TODO: string interpolating
    Value.new(node.body, Value.Type.str())
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
        # TODO: not a real solution. eval_params returns a list, which worked by accident when I wasn't using Evaluator.Value.
        # I can't really figure out why this is being passed in as a list. Before Value was introduced, it worked as expected...
        # eval_lit returns a single element. And it is only sometimes. Only when let is popped it seems.
        r = eval_params(pid, node)
        1 = length(r)
        List.pop_at(r, 0) |> elem(0)
    end
  end
end
