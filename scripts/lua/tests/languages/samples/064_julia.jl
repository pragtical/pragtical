module DemoWidgets

export Widget, render

abstract type AbstractWidget end

mutable struct Widget{T <: AbstractString} <: AbstractWidget
    name::T
    count::Int
end

macro traced(expr)
    quote
        try
            $(esc(expr))
        catch err
            @warn "render failed" err
            rethrow()
        finally
            nothing
        end
    end
end

function render(widget::Widget, items::Vector{String})::String
    labels = String[]
    for item in items
        if isempty(item)
            continue
        elseif item == "stop"
            break
        else
            push!(labels, "$(widget.name):$item")
        end
    end
    return join(labels, ", ")
end

let widget = Widget("demo", 0)
    @traced render(widget, ["alpha", "beta"])
end

md"""
# Widget

Rendered with Julia markdown string support.
"""

end
