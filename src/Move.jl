#=
Moving a selection of components, sources and groups rigidly, in one write of system.jl
=#

"""
    move!(dir, ids::Vector{Symbol}; offset = (0, 0, 0), rot = nothing, pivot = :center,
          by = nothing) -> Project

Moves the components, sources and groups `ids` of the live project in the folder `dir` by one
rigid motion, as a selection of several in the window, and writes `system.jl` once. Returns the
project loaded again from the written files.

The motion first rotates by `rot` about `pivot` with the axes of the world, then moves by
`offset` (in m): a position `x` becomes `pivot + R (x - pivot) + offset` with
`R = rotation_matrix(rot)` (angles in degrees as `rot` of a line, or a 3×3 matrix, `nothing`: no
rotation, see [`rotation_matrix`](@ref)), and the orientation of each line is turned by `R`.
`pivot` is `:center` (the mean of the positions of the `ids`: of the components and sources, and
the pivot of each group), the id of a component, source or group (its position), or a point
`(x, y, z)`.

A group moves with all its members, also those of the groups inside it, and its pivot and
orientation move with them. An id inside a group must be given with its group (or a group around
it); the members of a group are never moved alone, which would break the group. Unknown ids
throw an `ArgumentError` naming the id.

An id of a system stands for its members and sources (as listed by the `@system` line, groups as
groups); an object named twice, e.g. by a system and by one of its members, moves once.

The write is one [`save_project`](@ref) with the participant `by`: it throws an `ArgumentError`
if it would change a line claimed by another participant (see [`claim!`](@ref)) and
[`ProjectChanged`](@ref) if the files changed between loading and writing; then nothing is
written.

# Examples

```julia
move!(".", [:L1, :M1]; offset = (0.0, 0.01, 0.0), by = "claude")   # 10 mm along y
move!(".", [:G1]; rot = (0, 0, 90), by = "claude")                # G1 turned about its pivot
move!(".", [:L1, :L2]; rot = (0, 0, 5), pivot = :L1)              # about the position of L1
```
"""
function move!(dir::AbstractString, ids::Vector{Symbol}; offset = (0, 0, 0), rot = nothing,
        pivot = :center, by = nothing)
    p = load_project(dir)
    _move!(p, ids; offset, rot, pivot)
    save_project(p; by)
    _announce_wrote(p.path, by, "moved " * join(ids, ", "); selected_id = String(first(ids)))
    return load_project(p.path)
end

"""
Moves the lines `ids` of the loaded project `p` in memory (`pos` and `rot` of its entries and
groups; the built objects are not moved), see [`move!`](@ref). Returns `p`.
"""
function _move!(p::Project, ids::Vector{Symbol}; offset = (0, 0, 0), rot = nothing,
        pivot = :center)
    length(offset) == 3 || throw(ArgumentError("offset needs three numbers, got $(length(offset))"))
    t = Float64[offset[1], offset[2], offset[3]]
    R = rot === nothing ? nothing : rotation_matrix(rot)
    sel = _expand_systems(p, ids)
    foreach(id -> _move_kind(p, id), sel)
    # A member of a group only with its group (or a group around it)
    parents = _group_parents(p)
    chosen = Set(sel)
    for id in sel
        g = id
        inside = false
        while haskey(parents, g)
            g = parents[g]
            g in chosen && (inside = true; break)
        end
        haskey(parents, id) && !inside &&
            throw(ArgumentError("`$id` is in the group `$(parents[id])`; move the group `$(_outermost(parents, id))`"))
    end
    c = _move_pivot(p, sel, pivot)
    # Every line that moves: the entries and groups of the selection, with their members
    lines = Set{Symbol}()
    function collect!(n)
        n in lines && return nothing
        push!(lines, n)
        i = findfirst(g -> g.name === n, p.groups)
        isnothing(i) || foreach(collect!, p.groups[i].members)
        return nothing
    end
    foreach(collect!, sel)
    moved(x) = isnothing(R) ? x + t : c + R * (x - c) + t
    turned(r) = isnothing(R) ? r : R * rotation_matrix(r)
    for (i, e) in enumerate(p.entries)
        e.name in lines || continue
        x = moved(_line_position(e))
        p.entries[i] = Entry(e.kind, e.name, e.code, e.object, NTuple{3, Float64}(x), turned(e.rot),
            e.pose0, e.meta, e.label, e.uid)
    end
    for (i, g) in enumerate(p.groups)
        g.name in lines || continue
        x = moved(_line_position(g))
        p.groups[i] = GroupEntry(g.name, g.members, NTuple{3, Float64}(x), turned(g.rot), g.object,
            g.label, g.uid)
    end
    return p
end

"""
`ids` with every system replaced by its members and sources (in this order), each id once, in the
order of first appearance.
"""
function _expand_systems(p::Project, ids::Vector{Symbol})
    out = Symbol[]
    for id in ids
        i = findfirst(s -> s.name === id, p.systems)
        if isnothing(i)
            push!(out, id)
        else
            append!(out, p.systems[i].members)
            append!(out, p.systems[i].sources)
        end
    end
    return unique(out)
end

"""`:entry` or `:group` for the id `id` of `p`; throws for a system or an unknown id."""
function _move_kind(p::Project, id::Symbol)
    any(e -> e.name === id, p.entries) && return :entry
    any(g -> g.name === id, p.groups) && return :group
    any(s -> s.name === id, p.systems) &&
        throw(ArgumentError("`$id` is a system, not a component, source or group"))
    throw(ArgumentError("unknown id `$id`: no component, source or group of the project"))
end

"""The position of a line: `pos` of an entry (as constructed if it has none), the pivot of a group."""
_line_position(e::Entry) = e.pos === nothing ? copy(e.pose0[1]) : collect(e.pos)
_line_position(g::GroupEntry) = collect(g.pos)

"""The position of the id `id` of `p`, an entry or a group."""
function _id_position(p::Project, id::Symbol)
    _move_kind(p, id) === :entry ?
    _line_position(p.entries[findfirst(e -> e.name === id, p.entries)]) :
    _line_position(p.groups[findfirst(g -> g.name === id, p.groups)])
end

"""The pivot of `move!`: the mean of the positions of `sel`, the position of an id, or a point."""
function _move_pivot(p::Project, sel::Vector{Symbol}, pivot)
    if pivot === :center
        isempty(sel) && return zeros(3)
        return sum(id -> _id_position(p, id), sel) / length(sel)
    end
    pivot isa Symbol && return _id_position(p, pivot)
    length(pivot) == 3 ||
        throw(ArgumentError("pivot must be :center, an id or a point (x, y, z), got $(repr(pivot))"))
    return Float64[pivot[1], pivot[2], pivot[3]]
end
