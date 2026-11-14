defmodule Elil.Evaluator do
  alias Elil.Context
  alias Elil.Lexer
  alias Elil.Parser.Boolean, as: BooleanNode
  alias Elil.Parser.Condition, as: ConditionNode
  alias Elil.Parser.Definition, as: DefinitionNode
  alias Elil.Parser.Integer, as: IntegerNode
  alias Elil.Parser.Parameter, as: ParameterNode
  alias Elil.Parser.Reference, as: ReferenceNode
  alias Elil.Parser.Scope, as: ScopeNode
  alias Elil.Parser.String, as: StringNode
  alias Elil.Utils.SourceLocation
  import Elil.Utils
  require Elil.Utils
  import Elil.Globals
  require Elil.Globals

  defmodule Value do
    @enforce_keys [:type]
    defstruct [
      :type,
      :value
    ]

    defmodule Type do
      @compile {:inline, int: 0, void: 0, string: 0, func: 0, bool: 0}
      def int(), do: :int
      def void(), do: :void
      def string(), do: :string
      def func(), do: :func
      def bool(), do: :bool
    end

    defimpl String.Chars, for: __MODULE__ do
      def to_string(%Value{type: :void}) do
        ""
      end

      def to_string(%Value{value: true, type: :bool}), do: "true"
      def to_string(%Value{value: false, type: :bool}), do: "false"

      def to_string(%Value{} = value) do
        Kernel.to_string(value.value)
      end
    end

    def new(value, wanted_type)

    def new(_v, :void) do
      struct!(Value, type: Type.void())
    end

    def new(v, :bool) when is_boolean(v) do
      struct!(Value, type: Type.bool(), value: v)
    end

    def new(v, :string) when not is_nil(v) do
      struct!(Value, type: Type.string(), value: to_string(v))
    end

    def new(v, :func) when not is_nil(v) when is_list(v) do
      # Assert v is a list for now, as that is how it is parsed.
      struct!(Value, type: Type.func(), value: v)
    end

    def new(v, :int) when not is_nil(v) do
      v =
        case v do
          v when is_integer(v) ->
            v

          # TODO: handle more than just base 10
          v when is_binary(v) ->
            Integer.parse(v, 10) |> elem(0)

          # TODO: handle more than just base 10
          v when is_list(v) ->
            Integer.parse(List.to_string(v), 10) |> elem(0)

          # @see logging errors
          v ->
            Elil.Logger.error_log_and_die(
              "unable to parse value \"#{v}\" to an integer"
            )
        end

      struct!(Value, type: Type.int(), value: v)
    end

    def lt(%Value{type: :int} = lt, %Value{type: :int} = gt) do
      new(raw_int(lt) < raw_int(gt), :bool)
    end

    defp raw_int(%Value{type: :int, value: val} = _v) when is_binary(val) do
      String.to_integer(val, 10)
    end

    defp raw_int(%Value{type: :int, value: val} = _v) when is_integer(val) do
      val
    end
  end

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
    if Elil.Cmd.get_option_bool("print_file_path") do
      IO.puts("Evaluating file: " <> file_path)
    end

    if Elil.Cmd.get_option_bool("print_lexer") do
      # TODO: knowledge of the lexer module should probably be abstracted to
      # lib/cmd.ex instead of being inside the evaluator. Idk, maybe.
      Lexer.lex_entire_file(file, file_path, &print_lexer(&1))
      :ok
    else
      {:ok, lexer_pid} =
        GenServer.start_link(Lexer, {file_path, file}, hibernate_after: 100)

      {:ok, %ScopeNode{} = root_node} = Elil.Parser.parse(lexer_pid)
      GenServer.stop(lexer_pid)

      if Elil.Cmd.get_option_bool("print_ast") do
        IO.inspect(root_node)
      else
        {:ok, context_pid} = GenServer.start_link(Context, [])

        # TODO: if we bubble errors up to the surface through returns, we can handle errors properly here.
        #  I don't really wanna use exceptions. I feel like they might be a crutch for a poor recursive design.
        #  Although that might be wrong and exceptions are just the way to go. Who knows.

        eval_node(context_pid, root_node)

        GenServer.stop(context_pid)
      end

      :ok
    end
  end

  defp eval_node(pid, %m{} = node) when is_pid(pid) and is_lit(m) do
    eval_lit(pid, node)
  end

  defp eval_node(pid, %DefinitionNode{type: :var} = node) when is_pid(pid) do
    define_symbol(pid, node, :local)
  end

  defp eval_node(pid, %DefinitionNode{type: t} = node)
       when is_pid(pid) and t in [:gvar, :func] do
    define_symbol(pid, node, :global)
  end

  defp eval_node(pid, %DefinitionNode{type: :ass} = node) when is_pid(pid) do
    # todo("rename eval_ass to reassign_symbol, like the define_symbol above.")
    eval_ass(pid, node)
  end

  defp eval_node(pid, %DefinitionNode{type: :gass} = node) when is_pid(pid) do
    # todo("rename eval_gass to reassign_symbol, like the define_symbol above.")
    eval_gass(pid, node)
  end

  defp eval_node(pid, %ReferenceNode{name: func} = node)
       when is_pid(pid) and is_boolean_operator(func) do
    eval_bool(pid, node)
  end

  # an ident from the parser is expected to be a name of a variable or function.
  defp eval_node(pid, %type{} = node)
       when is_pid(pid) and type in [ReferenceNode] do
    eval_reference(pid, node)
  end

  # an ident from the parser is expected to be a name of a variable or function.
  defp eval_node(pid, %ConditionNode{} = node) when is_pid(pid) do
    %Value{} = evaled_cond = eval_node(pid, node.condition)

    case evaled_cond do
      %Value{value: true} ->
        eval_node(pid, node.then)

      %Value{value: false} ->
        if is_nil(node.otherwise) do
          struct!(Value, type: Value.Type.void())
        else
          eval_node(pid, node.otherwise)
        end

      %Value{type: a} when is_atom(a) ->
        # @see logging erros
        Elil.Logger.error_log_and_die(
          "expected boolean when calling if-statement. Got type: \":#{Atom.to_string(a)}\""
        )
    end
  end

  defp eval_node(pid, %ScopeNode{} = node) when is_pid(pid) do
    {:ok} = Context.push_scope(pid)
    eval_params(pid, node)
    {:ok} = Context.pop_scope(pid)
  end

  defp eval_params(pid, %ReferenceNode{} = node) when is_pid(pid) do
    node.value
    |> Enum.map(&eval_node(pid, &1))
  end

  defp eval_params(pid, %ScopeNode{} = node) when is_pid(pid) do
    node.value
    |> Enum.map(&eval_node(pid, &1))
  end

  defp eval_builtins(pid, %ReferenceNode{name: func, value: args})
       when is_binary(func) and (is_list(args) or is_nil(args)) and is_pid(pid) do
    # TODO: @see logging errors the current logging just bubbles up to the calling function,
    # which doesn't take specific arguments or anything into account. Good enough
    # for now, but at a later point, I would like to have errors be more pin-pointable and direct
    case func do
      "add" ->
        # hard assert for now
        true = is_list(args)

        Enum.map(args, fn
          v ->
            %Value{} = eval_node(pid, v)
        end)
        |> Enum.reduce(0, fn
          %Value{type: :int} = v, acc ->
            acc + v.value

          %Value{type: t} = _v, _acc ->
            # TODO: error log here, instead of failing match
            {:err,
             "function add() expects only integers as arguments, got #{to_string(t)}"}
        end)
        |> Value.new(Value.Type.int())

      "sub" ->
        # hard assert for now
        true = is_list(args)

        [%Value{type: :int} = head | tail] =
          Enum.map(args, fn
            v ->
              %Value{} = eval_node(pid, v)
          end)

        Enum.reduce(tail, head.value, fn
          %Value{type: :int} = v, acc ->
            acc - v.value

          %Value{type: t} = _v, _acc ->
            # TODO: error log here, instead of failing match
            {:err,
             "function sub() expects only integers as arguments, got #{to_string(t)}"}
        end)
        |> Value.new(Value.Type.int())

      "echo" ->
        # hard assert for now
        true = is_list(args)

        Enum.map(args, &eval_node(pid, &1))
        |> Enum.map(&to_string/1)
        |> Enum.map(&IO.write/1)
        |> Value.new(Value.Type.void())

      "eval" ->
        # hard assert for now
        true = is_list(args)

        # TODO: make it fail if more are given or something.
        [arg | _] = args

        %Value{type: :string} = value = eval_node(pid, arg)

        value
        |> then(& &1.value)
        |> eval()
        |> Value.new(Value.Type.void())

      _ ->
        {:err, "symbol \"#{func}\" is not defined"}
    end
  end

  defp eval_lit(pid, %StringNode{} = node) when is_pid(pid) do
    # TODO: string interpolating
    Value.new(node.value, Value.Type.string())
  end

  defp eval_lit(pid, %BooleanNode{} = node) when is_pid(pid) do
    Value.new(node.value, Value.Type.bool())
  end

  defp eval_lit(pid, %IntegerNode{value: v} = _node)
       when is_pid(pid) and is_integer(v) do
    Value.new(v, Value.Type.int())
  end

  defp define_symbol(pid, %DefinitionNode{type: :func} = node, into)
       when is_atom(into) do
    value = Value.new(node.value, Value.Type.func())
    do_define_symbol(pid, node.name, value, into, node.source_location)
  end

  defp define_symbol(pid, %DefinitionNode{type: type} = node, into)
       when is_atom(into) and type in [:var, :gvar] do
    # Hard assert for now. Only one value can be assigned to a variable.
    1 = length(node.value)
    [head | _] = node.value
    %Value{} = value = eval_node(pid, head)

    do_define_symbol(pid, node.name, value, into, node.source_location)
  end

  defp do_define_symbol(
         pid,
         name,
         %Value{} = value,
         into,
         %SourceLocation{} = source_location
       )
       when is_pid(pid) and is_binary(name) and is_atom(into) do
    case Context.define_symbol(pid, name, value, into) do
      :already_exists ->
        Elil.Logger.error_log_and_die(
          source_location,
          "symbol \"#{to_string(name)}\" has already been previously defined"
        )

      _ ->
        {:ok}
    end
  end

  defp eval_ass(pid, %DefinitionNode{type: :ass} = node) when is_pid(pid) do
    # Hard assert for now. Only one value can be assigned to a variable.
    1 = length(node.value)
    [head | _] = node.value
    %Value{} = value = eval_node(pid, head)

    case Context.reassign(pid, node.name, value, :local) do
      {:undefined} ->
        Elil.Logger.error_log_and_die(
          node,
          "symbol \"#{to_string(node.name)}\" is undefined. To reassign something you need to define it first, using something like the \"let\" keyword."
        )

      _ ->
        {:ok}
    end
  end

  defp eval_gass(pid, %DefinitionNode{type: :gass} = node) when is_pid(pid) do
    # Hard assert for now. Only one value can be assigned to a variable.
    %Value{} = value = eval_node(pid, node.value)

    case Context.reassign(pid, node.name, value, :global) do
      {:undefined} ->
        Elil.Logger.error_log_and_die(
          node,
          "symbol \"#{to_string(node.name)}\" is undefined. To reassign something you need to define it first, using something like the \"let\" keyword."
        )

      _ ->
        {:ok}
    end
  end

  defp eval_reference(pid, %ReferenceNode{} = node) when is_pid(pid) do
    case eval_builtins(pid, node) do
      %Value{} = value ->
        value

      {:err, msg} ->
        # TODO: figure out when we need to do a function lookup vs a variable lookup
        case Context.get_symbol(pid, node) do
          {:ok, %Value{type: :func} = value} ->
            {:ok, fn_params} =
              value.value
              |> Keyword.get(:fn_params)
              |> resolve_func_params()

            params = eval_params(pid, node)
            expect_all(params, Value)

            arguments =
              case validate_func_params(params, fn_params) do
                {:ok, arguments} ->
                  arguments

                {:err, msg} ->
                  # TODO: @see logging errors
                  Elil.Logger.error_log_and_die(node, msg)
              end

            Context.push_frame(pid)
            Context.push_scope(pid)

            Context.define_symbol(pid, node.name, value, :local)

            # TODO: This is a bit scuffed. Maybe the Value should know its own name,
            # instead of just being the symbol key in the scope.
            arguments
            |> Enum.each(fn
              {name, value} -> Context.define_symbol(pid, name, value, :local)
            end)

            fn_body = Keyword.get(value.value, :fn_body)
            r = eval_node(pid, fn_body)

            return =
              if r !== {:ok} do
                todo("handle function returning value. Even if it's void")
              else
                struct!(Value, type: Value.Type.void())
              end

            # automatically pops the scope
            Context.pop_frame(pid)

            # TODO: This return might have to be assigned to something
            {:ok, return}

          # void cannot be a vairable, so hard assert for now.
          # TODO: @see logging errors we wanna either log that void is not valid and crash, or allow void as some sort of valid value.
          {:ok, %Value{type: type} = value} when type != :void ->
            value

          _ ->
            Elil.Logger.error_log_and_die(node.source_location, msg)
        end
    end
  end

  defp resolve_func_params(v, acc \\ [])

  defp resolve_func_params([], acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp resolve_func_params([%ParameterNode{} = head | tail], acc) do
    if not is_valid_type(head.type) do
      Elil.Logger.error_log_and_die(head, "invalid type given for argument")
    end

    resolve_func_params(tail, [head | acc])
  end

  defp validate_func_params(parameters, arguments)
       when is_list(arguments) and is_list(parameters) and
              length(arguments) !== length(parameters) do
    {
      :err,
      # TODO: @see logging erros. The function name should be logged here. idk maybe with a format string parsed above?
      "not enough arguments passed to function. Got #{length(parameters)}, but expected #{length(arguments)}"
    }
  end

  defp validate_func_params(parameters, arguments)
       when is_list(parameters) and is_list(arguments) do
    Enum.zip([parameters, arguments])
    |> Enum.map(fn {parameter, argument} ->
      case validate_single_func_param(parameter, argument) do
        {:ok, {name, %Value{} = value}} -> {name, value}
        # TODO: @see logging errors
        {:err, msg} -> Elil.Logger.error_log_and_die(argument, msg)
      end
    end)
    |> then(&{:ok, &1})
  end

  defp validate_single_func_param(
         %Value{type: atype} = _argument,
         %ParameterNode{type: ptype} = _parameter
       )
       when is_atom(ptype) and is_atom(atype) and ptype !== atype do
    # TODO: @see logging errors The arguments here need to say which argument was wrong and stuff like that.
    {:err,
     "argument does not have the same type as the parameter needs. Got: #{Atom.to_string(atype)}, but expected #{Atom.to_string(ptype)}"}
  end

  defp validate_single_func_param(
         %Value{type: atype} = argument,
         %ParameterNode{type: ptype} = parameter
       )
       when is_atom(ptype) and is_atom(atype) do
    # TODO: this only works for literals with no parameters. Maybe not the best idea.
    {:ok,
     {parameter.name,
      struct!(Value, type: argument.type, value: argument.value)}}
  end

  defp expect_all(values, struct_type)
       when is_list(values) and is_atom(struct_type) do
    values
    |> Enum.each(fn
      v when is_struct(v, struct_type) -> :ok
      # TODO: @see logging errors
      _ -> Elil.Logger.error_log_and_die("idk")
    end)
  end

  defp expect_parameter_count(%ReferenceNode{value: params} = node, count)
       when is_list(params) and is_integer(count) do
    if length(node.value) === count do
      {:ok}
    else
      Elil.Logger.error_log_and_die(
        node,
        "function: \"#{node.name}\" expected #{Integer.to_string(count)} amount of argumnets, but got: #{length(node.value)}"
      )
    end
  end

  defp eval_bool(pid, %ReferenceNode{} = node) do
    expect_parameter_count(node, 2)
    [lhs | tail] = node.value
    [rhs | _] = tail
    lhs = %Value{type: :int} = eval_node(pid, lhs)
    rhs = %Value{type: :int} = eval_node(pid, rhs)

    get_boolean_operator(node.name).(lhs, rhs)
    |> Value.new(:bool)
  end

  defp get_boolean_operator(op) when is_atom(op) do
    case op do
      :lt -> &Kernel.<(&1, &2)
      :lte -> &Kernel.<=(&1, &2)
      :gt -> &Kernel.>(&1, &2)
      :gte -> &Kernel.>=(&1, &2)
      :eq -> &Kernel.===(&1, &2)
    end
  end
end
