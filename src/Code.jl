#=
Own types of a project: the constructor code of an object, by which a change of its shape (e.g. on
a card of the GUI) is written to its line of `system.jl`
=#

"""
    constructor_code(obj) -> Union{Nothing, String}

The code of the constructor that builds `obj` as it is now, without its pose: the right-hand side
of its line in `system.jl` (the line keeps `pos` and `rot`). `nothing` (the default) if the type of
`obj` does not tell it.

An own type in the code of a project (`src/<Name>.jl`) adds a method, so that a change of its shape
(e.g. by a slider on its card in the GUI) can be saved to its line:

```julia
# src/Bench.jl: an own type Porro, built by Porro(leg, height) and keeping both
BeamletOpticsProjects.constructor_code(p::Porro) = "Porro(\$(p.leg), \$(p.height))"
```

The string must parse and, evaluated in the module of the project (where the exported names of
`src/<Name>.jl` are known), build an object equal in shape to `obj`. Print numbers with `repr` or
string interpolation of `Float64`, which round-trip exactly. Without a method, a change of the
shape lives only in the window and is lost when the project is loaded again.
"""
constructor_code(@nospecialize(obj)) = nothing
