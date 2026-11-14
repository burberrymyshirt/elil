defmodule Elil.Globals do
  alias Elil.Parser.Boolean, as: BooleanNode
  alias Elil.Parser.Integer, as: IntegerNode
  alias Elil.Parser.String, as: StringNode

  defguard is_boolean_operator_s(type)
           when is_binary(type) and
                  type in ["lt", "lte", "gt", "gte", "eq", "neq"]

  defguard is_boolean_operator(type)
           when is_atom(type) and type in [:lt, :lte, :gt, :gte, :eq, :neq]

  defguard is_lit(type) when type in [BooleanNode, IntegerNode, StringNode]

  @elil_types [:string, :int, :func, :mixed]

  def is_builtin_type(t) when is_atom(t) do
    t in @elil_types
  end

  def is_valid_type(t) do
    is_builtin_type(t)
  end
end
