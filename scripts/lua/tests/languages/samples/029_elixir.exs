defmodule Demo.Widget do
  @moduledoc """
  Renders enabled widget labels.
  """

  alias __MODULE__, as: Widget

  defstruct name: "demo", items: []

  defguardp enabled?(item) when is_map(item) and item.enabled == true

  defmacro trace(expr) do
    quote do
      try do
        unquote(expr)
      rescue
        error -> reraise error, __STACKTRACE__
      after
        :ok
      end
    end
  end

  def render(%Widget{name: name, items: items}) when is_list(items) do
    items
    |> Enum.filter(fn item -> enabled?(item) end)
    |> Enum.map(fn item -> "#{name}:#{item.label}" end)
    |> Enum.join(", ")
  end

  def render(_), do: raise ArgumentError, "invalid widget"
end

case Demo.Widget.trace(Demo.Widget.render(%Demo.Widget{items: [%{enabled: true, label: "alpha"}]})) do
  "" -> :empty
  text -> IO.puts(text)
end
