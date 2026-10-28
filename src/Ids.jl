#=
Readable ids of the entries, groups and systems: a prefix of the family and a number, e.g. `L1`, `BS2`
=#

"""
    id_prefix(x) -> String

The prefix of the readable id of `x` (see [`next_id`](@ref)), chosen by its type: `"L"` lenses,
`"P"` prisms, `"M"` mirrors and other reflective optics, `"D"` detectors, `"BS"` beamsplitters,
`"B"` sources (beams and beam groups), `"G"` groups, `"S"` systems, `"X"` anything else. A package
with own component types may add methods.
"""
id_prefix(@nospecialize(x)) = "X"
id_prefix(::Union{BMO.Lens, BMO.DoubletLens, BMO.TripletLens}) = "L"
id_prefix(::BMO.Prism) = "P"
id_prefix(::BMO.AbstractReflectiveOptic) = "M"
id_prefix(::BMO.AbstractDetector) = "D"
id_prefix(::BMO.AbstractBeamsplitter) = "BS"
id_prefix(::Union{BMO.AbstractBeam, BMO.AbstractBeamGroup}) = "B"
id_prefix(::BMO.AbstractObjectGroup) = "G"
id_prefix(::BMO.AbstractSystem) = "S"

"""
    next_id(project, prefix) -> Symbol

The next free readable id with the `prefix` in `project`: the prefix and one more than the largest
number of an entry, group or system with that prefix, e.g. `:L4` after `L1`, `L3`.
"""
function next_id(p::Project, prefix::AbstractString)
    re = Regex("^" * prefix * "(\\d+)\$")
    n = 0
    for name in Iterators.flatten(((e.name for e in p.entries), (s.name for s in p.systems),
            (g.name for g in p.groups)))
        m = match(re, String(name))
        isnothing(m) || (n = max(n, parse(Int, m.captures[1])))
    end
    return Symbol(prefix, n + 1)
end
