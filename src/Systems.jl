#=
Creating systems and changing their members and sources with checks, in one write each
=#

"""
    add_system!(dir, ids::Vector{Symbol} = Symbol[]; sources = Symbol[], id = nothing,
                label = nothing, by = nothing) -> Symbol

Adds a `@system` line to the live project in the folder `dir` and returns its id. Its members are
the components and groups of `ids`, its sources the sources of `ids` and `sources` (a source given
in `ids` goes to the sources). A source belongs to at most one system: one that is in another
system leaves it in the same write. An object can be a member of any number of systems.

`id = nothing` takes the next free id `S1`, `S2`, ... (see [`next_id`](@ref)), chosen in the same
load and write as in [`add!`](@ref); a given `id` that is taken throws. `label` is the name shown
instead of the id. An empty `ids` makes an empty system, e.g. the first one of a new project.

Unknown ids, ids of systems and an id inside a group that is given without its group throw an
`ArgumentError` naming the id. The checks and the write are those of [`add!`](@ref): the changed
`system.jl` loads before anything is written, the write respects the claims of the others (see
[`claim!`](@ref)) and is done again from the files if they changed meanwhile.

# Examples

```julia
add_system!(".", [:L1, :M1, :D1]; sources = [:B1], by = "claude")   # -> :S1
add_system!(".")                                                    # an empty system -> :S2
```
"""
add_system!(dir::AbstractString, ids::Vector{Symbol} = Symbol[]; kwargs...) =
    _retry_changed(() -> _add_system_once!(dir, ids; kwargs...))

function _add_system_once!(dir::AbstractString, ids::Vector{Symbol}; sources = Symbol[],
        id = nothing, label = nothing, by = nothing)
    p = load_project(dir)
    if isnothing(id)
        id = next_id(p, "S")
    else
        id = Symbol(id)
        Base.isidentifier(id) || throw(ArgumentError("`$id` is not a valid id"))
        _taken(p, id) && throw(ArgumentError("the id `$id` is taken"))
    end
    members, srcs = _system_parts(p, unique(vcat(Symbol.(ids), Symbol.(collect(sources)))))
    _free_sources!(p, srcs)
    push!(p.systems, SystemEntry(id, members, srcs; label = _edit_label(label)))
    _edit_check(p, [id])
    save_project(p; by)
    _announce_wrote(p.path, by, "added the system $id"; selected_id = "")
    return id
end

"""
    join_system!(dir, system::Symbol, ids::Vector{Symbol}; by = nothing) -> Project

Adds the components, groups and sources `ids` of the live project in the folder `dir` to the
system `system`: components and groups as members, sources as its sources. A source leaves the
system it was in, in the same write (a source belongs to at most one system); an object stays a
member of its other systems. Ids that are in the system already are left as they are. Returns the
project loaded again from the written files.

Unknown ids, ids of systems, an id inside a group that is given without its group and an unknown
`system` throw an `ArgumentError` naming the id, and nothing is written. The checks and the write
are those of [`add!`](@ref).

# Examples

```julia
join_system!(".", :S1, [:L2, :B2]; by = "claude")
```
"""
join_system!(dir::AbstractString, system::Symbol, ids::Vector{Symbol}; kwargs...) =
    _retry_changed(() -> _join_system_once!(dir, system, ids; kwargs...))

function _join_system_once!(dir::AbstractString, system::Symbol, ids::Vector{Symbol}; by = nothing)
    p = load_project(dir)
    i = _system_index(p, system)
    members, srcs = _system_parts(p, unique(Symbol.(ids)))
    _free_sources!(p, srcs; except = system)
    s = p.systems[i]
    p.systems[i] = SystemEntry(s.name, vcat(s.members, filter(m -> !(m in s.members), members)),
        vcat(s.sources, filter(m -> !(m in s.sources), srcs)), s.static, s.object, s.label, s.uid)
    _edit_check(p, Symbol[system; ids])
    save_project(p; by)
    _announce_wrote(p.path, by, "put " * join(ids, ", ") * " into $system"; selected_id = "")
    return load_project(p.path)
end

"""
    leave_system!(dir, system::Symbol, ids::Vector{Symbol}; by = nothing) -> Project

Takes the members and sources `ids` out of the system `system` of the live project in the folder
`dir`. The objects stay lines of the project (and members of their other systems); to remove them
from the project, see [`remove!`](@ref). Returns the project loaded again from the written files.

An id that is not a member or source of `system` and an unknown `system` throw an
`ArgumentError` naming it, and nothing is written. The checks and the write are those of
[`add!`](@ref).

# Examples

```julia
leave_system!(".", :S1, [:L2]; by = "claude")
```
"""
leave_system!(dir::AbstractString, system::Symbol, ids::Vector{Symbol}; kwargs...) =
    _retry_changed(() -> _leave_system_once!(dir, system, ids; kwargs...))

function _leave_system_once!(dir::AbstractString, system::Symbol, ids::Vector{Symbol}; by = nothing)
    p = load_project(dir)
    i = _system_index(p, system)
    s = p.systems[i]
    gone = unique(Symbol.(ids))
    for id in gone
        (id in s.members || id in s.sources) ||
            throw(ArgumentError("`$id` is not in the system `$system`"))
    end
    p.systems[i] = SystemEntry(s.name, filter(m -> !(m in gone), s.members),
        filter(m -> !(m in gone), s.sources), s.static, s.object, s.label, s.uid)
    _edit_check(p, Symbol[system; ids])
    save_project(p; by)
    _announce_wrote(p.path, by, "took " * join(ids, ", ") * " out of $system"; selected_id = "")
    return load_project(p.path)
end

"""The index of the system `system` in `p.systems`; an `ArgumentError` if there is none."""
function _system_index(p::Project, system::Symbol)
    i = findfirst(s -> s.name === system, p.systems)
    isnothing(i) && throw(ArgumentError("unknown system `$system`"))
    return i
end

"""
The `ids` split into members (components and groups) and sources, in their order, after checking
that each is a line or group of `p` and that none is inside a group that `ids` does not give.
"""
function _system_parts(p::Project, ids::Vector{Symbol})
    foreach(id -> _edit_kind(p, id), ids)
    _check_with_groups(p, ids)
    members, srcs = Symbol[], Symbol[]
    for id in ids
        i = findfirst(e -> e.name === id, p.entries)
        push!(!isnothing(i) && p.entries[i].kind === :source ? srcs : members, id)
    end
    return members, srcs
end

"""Takes the sources `srcs` out of every system of `p` but `except`: a source is in one system."""
function _free_sources!(p::Project, srcs::Vector{Symbol}; except = nothing)
    isempty(srcs) && return p
    for (i, s) in enumerate(p.systems)
        s.name === except && continue
        any(in(srcs), s.sources) || continue
        p.systems[i] = SystemEntry(s.name, s.members, filter(m -> !(m in srcs), s.sources), s.static,
            s.object, s.label, s.uid)
    end
    return p
end
