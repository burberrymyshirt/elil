defmodule Elil.Context do
  alias Elil.Parser.Reference, as: ReferenceNode
  alias Elil.Evaluator.Value
  use GenServer

  defmodule Scope do
    defstruct symbols: %{}, local_symbols: %{}

    def new(), do: %__MODULE__{}
  end

  defmodule Frame do
    defstruct scopes: []

    def new(), do: %__MODULE__{}
  end

  defstruct frames: []

  def push_frame(pid) when is_pid(pid), do: GenServer.call(pid, {:push_frame})

  def pop_frame(pid) when is_pid(pid), do: GenServer.call(pid, {:pop_frame})

  def push_scope(pid) when is_pid(pid), do: GenServer.call(pid, {:push_scope})

  def pop_scope(pid) when is_pid(pid), do: GenServer.call(pid, {:pop_scope})

  def define_symbol(pid, var_name, %Value{type: type} = value, into)
      when is_pid(pid) and is_binary(var_name) and type !== :void and
             is_atom(into) do
    # TODO: @see logging errors
    # cannot assign void to anything, so we hard fail for now

    GenServer.call(pid, {:define_symbol, var_name, value, into})
  end

  def reassign(pid, var_name, %Value{type: type} = value, into)
      when is_pid(pid) and is_binary(var_name) and type !== :void and
             is_atom(into) do
    # TODO: @see logging errors
    # cannot assign void to anything, so we hard fail for now

    GenServer.call(pid, {:reassign, var_name, value, into})
  end

  def get_symbol(pid, %ReferenceNode{} = node) when is_pid(pid) do
    get_symbol(pid, node.name)
  end

  def get_symbol(pid, var_name) when is_pid(pid) when is_pid(var_name) do
    GenServer.call(pid, {:get_symbol, var_name})
  end

  @impl true
  def init(_initial) do
    {:ok, %__MODULE__{frames: [Frame.new()]}}
  end

  @impl true
  def handle_call({:push_frame}, _from, %__MODULE__{} = state) do
    state = %__MODULE__{state | frames: [Frame.new() | state.frames]}
    {:reply, {:ok}, state}
  end

  @impl true
  def handle_call({:pop_frame}, _from, %__MODULE__{} = state) do
    [_first | rest] = state.frames
    state = %__MODULE__{state | frames: rest}
    {:reply, {:ok}, state}
  end

  @impl true
  def handle_call(
        {:push_scope},
        _from,
        %__MODULE__{frames: [%Frame{} = first | rest]} = state
      ) do
    frame = %Frame{first | scopes: [%Scope{} | first.scopes]}
    state = %__MODULE__{state | frames: [frame | rest]}
    {:reply, {:ok}, state}
  end

  @impl true
  def handle_call(
        {:pop_scope},
        _from,
        %__MODULE__{frames: [%Frame{} = frame | rest]} = state
      ) do
    [_ | scopes] = frame.scopes
    frame = %Frame{frame | scopes: scopes}
    state = %__MODULE__{state | frames: [frame | rest]}
    {:reply, {:ok}, state}
  end

  @impl true
  def handle_call(
        {:define_symbol, var_name, %Value{type: type} = value, into},
        _from,
        %__MODULE__{frames: [%Frame{} = frame | frames_rest]} = state
      )
      when type !== :void and is_binary(var_name) and is_atom(into) do
    # NOTE: some of these are very awkward operations, should maybe be
    # refactored at a later point.

    [%Scope{} = scope | scopes_rest] = frame.scopes

    key =
      if into === :global do
        :symbols
      else
        :local_symbols
      end

    symbols = Map.get(scope, key)

    case symbols |> Map.has_key?(var_name) do
      true ->
        {:reply, :already_exists, state}

      false ->
        # use the variable name as the key
        symbols = Map.put_new(symbols, var_name, value)
        scope = Map.put(scope, key, symbols)
        frame = %Frame{frame | scopes: [scope | scopes_rest]}
        {:reply, :ok, %__MODULE__{state | frames: [frame | frames_rest]}}
    end
  end

  @impl true
  def handle_call(
        {:reassign, name, %Value{type: type} = value, into},
        _from,
        %__MODULE__{} = state
      )
      when type !== :void and is_binary(name) and is_atom(into) do
    key =
      if into === :global do
        :symbols
      else
        :local_symbols
      end

    case do_reassign(name, state.frames, value, key) do
      # scopes cannot change if the variable is undefined, so ignore them.
      {:undefined, _} ->
        {:reply, {:undefined}, state}

      {:ok, frames} ->
        {:reply, {:ok}, %__MODULE__{state | frames: frames}}
    end
  end

  @impl true
  def handle_call({:get_symbol, name}, _from, %__MODULE__{} = state) do
    case do_get_symbol(name, state.frames) do
      :undefined ->
        {:reply, :undefined, state}

      {:ok, %Value{} = value} ->
        {:reply, {:ok, value}, state}
    end
  end

  defp do_get_symbol(name, frames, first \\ true)

  defp do_get_symbol(_name, [], _first), do: :undefined

  defp do_get_symbol(name, [%Frame{} = frame | rest], first)
       when is_boolean(first) and is_binary(name) do
    case do_get_symbol_scope(name, frame.scopes, first) do
      :undefined -> do_get_symbol(name, rest, false)
      {:ok, value} -> {:ok, value}
    end
  end

  defp do_get_symbol_scope(_name, [], _first), do: :undefined

  defp do_get_symbol_scope(name, [%Scope{} = scope | rest_scopes], true)
       when is_binary(name) do
    case lookup_symbol(scope.local_symbols, name) do
      :err ->
        case lookup_symbol(scope.symbols, name) do
          :err -> do_get_symbol_scope(name, rest_scopes, true)
          {:ok, value} -> {:ok, value}
        end

      {:ok, value} ->
        {:ok, value}
    end
  end

  defp do_get_symbol_scope(name, [%Scope{} = scope | rest_scopes], false)
       when is_binary(name) do
    case lookup_symbol(scope.symbols, name) do
      :err -> do_get_symbol_scope(name, rest_scopes, false)
      {:ok, value} -> {:ok, value}
    end
  end

  defp lookup_symbol(%{} = symbols, name) when is_binary(name) do
    case Map.get(symbols, name) do
      nil ->
        :err

      %Value{} = value ->
        {:ok, value}
    end
  end

  defp do_reassign(_name, [], %Value{} = _value, _key), do: {:undefined, nil}

  defp do_reassign(name, [%Frame{} = frame | rest], %Value{} = value, key)
       when is_binary(name)
       when is_atom(key) do
    case do_reassign_scope(name, frame.scopes, value, key) do
      {:ok, scopes} ->
        {:ok, [%Frame{frame | scopes: scopes} | rest]}

      {:undefined, _} ->
        case do_reassign(name, rest, value, key) do
          {:undefined, _} -> {:undefined, nil}
          {:ok, rest} -> [frame | rest]
        end
    end
  end

  defp do_reassign_scope(_name, [], %Value{} = _value, _key),
    do: {:undefined, nil}

  defp do_reassign_scope(name, [%Scope{} = scope | rest], %Value{} = value, key)
       when is_binary(name)
       when is_atom(key) do
    # TODO: this sucks ass ... Hopefully it is obvious why .
    case key do
      :symbols ->
        if Map.has_key?(scope.symbols, name) do
          {:ok,
           [%Scope{scope | symbols: Map.put(scope.symbols, name, value)} | rest]}
        else
          case do_reassign_scope(name, rest, value, key) do
            {:ok, rest} -> {:ok, [scope | rest]}
            {:undefined, _} -> {:undefined, nil}
          end
        end

      :local_symbols ->
        if Map.has_key?(scope.local_symbols, name) do
          {:ok,
           [
             %Scope{scope | local_symbols: Map.put(scope.symbols, name, value)}
             | rest
           ]}
        else
          case do_reassign_scope(name, rest, value, key) do
            {:ok, rest} -> {:ok, [scope | rest]}
            {:undefined, _} -> {:undefined, nil}
          end
        end
    end
  end
end
