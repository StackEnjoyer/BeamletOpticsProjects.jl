#=
Reading a loaded project: the members and sources of a system, the pose of a line, and a moved
copy of the project in memory for scans
=#

"""The `SystemEntry` called `system` of `p`; throws an `ArgumentError` for an unknown system."""
function _query_system(p::Project, system::Symbol)
    i = findfirst(s -> s.name === system, p.systems)
    isnothing(i) &&
        throw(ArgumentError("unknown system `$system`: the project has " *
                            (isempty(p.systems) ? "no system" : "the systems " * join(("`$(s.name)`" for s in p.systems), ", "))))
    return p.systems[i]
end

"""
    members(p::Project, system::Symbol) -> Vector{Symbol}

The ids of the members of the system `system` as its `@system` line lists them (a group is one
member: its id, not those of the objects inside). Throws an `ArgumentError` for an unknown system.
"""
members(p::Project, system::Symbol) = copy(_query_system(p, system).members)

"""
    sources(p::Project, system::Symbol) -> Vector{Symbol}

The ids of the sources of the system `system` (its `sources = [...]` list, beam groups as groups).
Throws an `ArgumentError` for an unknown system.
"""
sources(p::Project, system::Symbol) = copy(_query_system(p, system).sources)

"""
    pose(p::Project, id::Symbol) -> @NamedTuple{pos::NTuple{3, Float64}, rot::Matrix{Float64}}

The pose of the component, source or group `id` as its line has it: the position `pos` in m (a
line without `pos`: the position of its object as constructed) and its `rot` as a rotation matrix
(see [`rotation_matrix`](@ref): the rotation since construction, the identity for a line without
`rot`). A pose read before a change puts the line back with [`set!`](@ref)`(dir, id; pos, rot)`.
Throws an `ArgumentError` for an unknown id.
"""
function pose(p::Project, id::Symbol)
    i = findfirst(e -> e.name === id, p.entries)
    if !isnothing(i)
        e = p.entries[i]
        return (; pos = NTuple{3, Float64}(_line_position(e)), rot = rotation_matrix(e.rot))
    end
    i = findfirst(g -> g.name === id, p.groups)
    if !isnothing(i)
        g = p.groups[i]
        return (; pos = g.pos, rot = rotation_matrix(g.rot))
    end
    throw(ArgumentError("unknown id `$id`: no component, source or group of the project"))
end

"""
    moved(p::Project, ids::Vector{Symbol}; offset = (0, 0, 0), rot = nothing, pivot = :center)
        -> Project

A copy of `p` in which the lines `ids` (components, sources, groups with their members, or systems
with their members and sources) are moved as [`move!`](@ref) moves them, with the built objects
moved too, so that the copy can be traced with [`trace`](@ref). Nothing is written and `p` is
unchanged. For scans of a position or an angle without a write; saving the copy is allowed but not
its purpose.
"""
function moved(p::Project, ids::Vector{Symbol}; offset = (0, 0, 0), rot = nothing, pivot = :center)
    # One graph, so that the objects of the entries, groups and systems stay shared; a module is not copied
    entries, systems, groups = deepcopy((p.entries, p.systems, p.groups))
    q = Project(p.path, p.name, entries, systems, groups, p.mod, p.stamp)
    _move!(q, ids; offset, rot, pivot)
    for (a, b) in zip(p.entries, q.entries)
        a.pos == b.pos && a.rot == b.rot && continue
        _pose_to!(b.object, a.rot, b.pos, b.rot)
    end
    for (a, b) in zip(p.groups, q.groups)
        a.pos == b.pos && a.rot == b.rot && continue
        BMO.set_pivot3d!(b.object, Float64[b.pos[1], b.pos[2], b.pos[3]])
        BMO.orientation!(b.object, rotation_matrix(b.rot))
    end
    return q
end

"""Turns the posed `obj` from the line rotation `old` to `new` about its position, then puts it at `pos`."""
function _pose_to!(@nospecialize(obj), old, pos, new)
    if !(old === nothing && new === nothing)
        rotate3d!(obj, rotation_matrix(new) * transpose(rotation_matrix(old)))
    end
    reset_translation3d!(obj)
    translate3d!(obj, Float64[pos[1], pos[2], pos[3]])
    return obj
end
