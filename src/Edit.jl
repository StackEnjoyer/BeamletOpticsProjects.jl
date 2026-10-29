#=
Adding, changing, copying and removing lines of system.jl with checks, in one write each
=#

"""
    add!(dir, code::AbstractString; id = nothing, pos = (0, 0, 0), rot = (0, 0, 0), label = nothing,
         systems = Symbol[], by = nothing) -> Symbol

Adds a line for the object built by `code` (a constructor, e.g. `"RoundPlanoMirror(0.0254, 0.006)"`)
to the live project in the folder `dir` and returns its id. The line is a `@source` if the object
is a beam or a beam group, else a `@component`.

`id = nothing` takes the next free id of the prefix of the object (see [`next_id`](@ref) and
[`id_prefix`](@ref)), chosen in the same load and write, so no other participant can take it in
between; a given `id` that is taken throws. `pos` (in m) and `rot` (angles in degrees or a 3×3
matrix, see [`rotation_matrix`](@ref)) are the pose of the line, `label` the name shown instead of
the id. The new line becomes a member of the `systems` (ids of systems); a source goes into the
`sources` of at most one system.

The changed project is checked before anything is written: the code builds in the module of the
project (with its own code of `src/`), the pose is finite and the whole `system.jl` loads again.
A check that fails throws an `ArgumentError` naming the id, and nothing is written. The write is
one [`save_project`](@ref) with the participant `by`, which respects the claims of the others
(see [`claim!`](@ref)) and throws [`ProjectChanged`](@ref) if the files changed meanwhile.

# Examples

```julia
add!(".", "RoundPlanoMirror(0.0254, 0.006)"; pos = (0.1, 0.2, 0.0), rot = (0, 0, 45),
     systems = [:S1], by = "claude")                        # -> :M3
add!(".", "Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6)"; systems = [:S1])   # a source
```
"""
function add!(dir::AbstractString, code::AbstractString; id = nothing, pos = (0, 0, 0),
        rot = (0, 0, 0), label = nothing, systems = Symbol[], by = nothing)
    p = load_project(dir)
    what = isnothing(id) ? "the new line" : "`$id`"
    ex = _edit_parse(code, what)
    obj = _edit_build(p, ex, what)
    kind = obj isa Union{BMO.AbstractBeam, BMO.AbstractBeamGroup} ? :source : :component
    if isnothing(id)
        id = next_id(p, Base.invokelatest(id_prefix, obj))
    else
        id = Symbol(id)
        Base.isidentifier(id) || throw(ArgumentError("`$id` is not a valid id"))
        _taken(p, id) && throw(ArgumentError("the id `$id` is taken"))
    end
    pos, rot = _edit_pose(id, pos, _no_angles(rot))
    systems = Symbol[Symbol(s) for s in systems]
    for s in systems
        any(x -> x.name === s, p.systems) ||
            throw(ArgumentError("`$id`: unknown system `$s`"))
    end
    kind === :source && length(unique(systems)) > 1 &&
        throw(ArgumentError("`$id` is a source and belongs to at most one system, got $(join(systems, ", "))"))
    pose0 = _edit_place(obj, pos, rot, id)
    push!(p.entries, Entry(kind, id, ex, obj; pos, rot, pose0, label = _edit_label(label)))
    for s in unique(systems)
        _edit_system!(p, s, id, kind)
    end
    _edit_check(p, [id])
    save_project(p; by)
    _announce_wrote(p.path, by, "added $id"; selected_id = String(id))
    return id
end

"""
    set!(dir, id::Symbol; pos = nothing, rot = nothing, code = nothing, label = nothing,
         by = nothing) -> Project

Changes the given fields of the line `id` of the live project in the folder `dir` and keeps the
others, also its machine id; `nothing` keeps a field. `pos` (in m) and `rot` (angles in degrees
or a 3×3 matrix) are the pose of the line, as written in `system.jl`; `code` replaces the
constructor (the object is built again, a component stays a component and a source a source);
`label = ""` removes the label. Returns the project loaded again from the written files.

Of a group only the `label` is set: its `pos` is the pivot of its members, which a group moves
with it, see [`move!`](@ref); of a system only the `label`.

The checks and the write are those of [`add!`](@ref): a check that fails throws an
`ArgumentError` naming the id, and nothing is written.

# Examples

```julia
set!(".", :L1; pos = (0.0, 0.12, 0.0), by = "claude")
set!(".", :L1; code = "SphericalLens(0.05, -0.05, 0.006, 0.0254, 1.5)", label = "Collimator")
```
"""
function set!(dir::AbstractString, id::Symbol; pos = nothing, rot = nothing, code = nothing,
        label = nothing, by = nothing)
    p = load_project(dir)
    i = findfirst(e -> e.name === id, p.entries)
    if isnothing(i)
        j = findfirst(g -> g.name === id, p.groups)
        k = findfirst(s -> s.name === id, p.systems)
        isnothing(j) && isnothing(k) &&
            throw(ArgumentError("unknown id `$id`: no component, source, group or system of the project"))
        what = isnothing(j) ? "system" : "group"
        (isnothing(pos) && isnothing(rot) && isnothing(code)) ||
            throw(ArgumentError("`$id` is a $what: set! changes only its label" *
                                (what == "group" ? "; move! moves a group with its members" : "")))
        if !isnothing(label)
            if isnothing(j)
                s = p.systems[k]
                p.systems[k] = SystemEntry(s.name, s.members, s.sources, s.static, s.object,
                    _edit_label(label), s.uid)
            else
                g = p.groups[j]
                p.groups[j] = GroupEntry(g.name, g.members, g.pos, g.rot, g.object,
                    _edit_label(label), g.uid)
            end
        end
    else
        e = p.entries[i]
        newpos = isnothing(pos) ? e.pos : pos
        newrot = isnothing(rot) ? e.rot : rot
        newpos, newrot = _edit_pose(id, newpos, newrot)
        ex, obj, pose0 = e.code, e.object, e.pose0
        if !isnothing(code)
            ex = _edit_parse(code, "`$id`")
            obj = _edit_build(p, ex, "`$id`")
            kind = obj isa Union{BMO.AbstractBeam, BMO.AbstractBeamGroup} ? :source : :component
            kind === e.kind ||
                throw(ArgumentError("`$id` is a $(e.kind), the new code builds a $kind"))
            pose0 = _edit_place(obj, newpos, newrot, id)
        end
        newlabel = isnothing(label) ? e.label : _edit_label(label)
        p.entries[i] = Entry(e.kind, e.name, ex, obj; pos = newpos, rot = newrot, pose0,
            meta = e.meta, label = newlabel, uid = e.uid)
    end
    _edit_check(p, [id])
    save_project(p; by)
    _announce_wrote(p.path, by, "changed $id"; selected_id = String(id))
    return load_project(p.path)
end

"""
    duplicate!(dir, ids::Vector{Symbol}; offset = (0, 0, 0), rot = nothing, pivot = :center,
               systems = :same, by = nothing) -> Vector{Symbol}

Copies the components, sources and groups `ids` of the live project in the folder `dir` and moves
the copies by one rigid motion, as [`move!`](@ref) moves the originals (`offset`, `rot` and
`pivot` as there; the default leaves the copies on the originals). Returns the ids of the copies:
in the order of `ids`, a group after the copies of its members (in their order, also of the groups
inside it).

A copy has the code, pose and further keywords of its original, a new id (the next free one of its
prefix, see [`next_id`](@ref)), no label and no machine id (it gets one when it is written). A copy
of a group is a new group of the copies of its members. As in [`move!`](@ref), an id inside a
group must be given with its group (or a group around it).

`systems = :same` puts each copy into the systems of its original (a component into their
members, a source into their sources); a vector of system ids puts each copy into those (a source
into at most one), `Symbol[]` into none. The copies of the members of a group are in systems only
through the copy of the group.

The checks and the write are those of [`add!`](@ref): a check that fails throws an
`ArgumentError` naming the id, and nothing is written.

# Examples

```julia
duplicate!(".", [:M1]; offset = (0.0, 0.05, 0.0), by = "claude")   # -> [:M3]
duplicate!(".", [:G1]; rot = (0, 0, 180), pivot = (0.0, 0.0, 0.0))  # -> [:L3, :M4, :G2]
```
"""
function duplicate!(dir::AbstractString, ids::Vector{Symbol}; offset = (0, 0, 0), rot = nothing,
        pivot = :center, systems = :same, by = nothing)
    p = load_project(dir)
    sel = unique(ids)
    foreach(id -> _edit_kind(p, id), sel)
    _check_with_groups(p, sel)
    pivot isa Symbol && pivot !== :center && _edit_kind(p, pivot)
    parents = _group_parents(p)
    chosen = Set(sel)
    # What is inside a chosen group is copied with it
    roots = filter(id -> !_inside_chosen(parents, chosen, id), sel)
    if systems !== :same
        systems isa AbstractVector ||
            throw(ArgumentError("systems must be :same or a vector of system ids, got $(repr(systems))"))
        systems = Symbol[Symbol(s) for s in systems]
        for s in systems
            any(x -> x.name === s, p.systems) ||
                throw(ArgumentError("unknown system `$s`"))
        end
    end
    new = Symbol[]
    function dup!(id)
        i = findfirst(e -> e.name === id, p.entries)
        if !isnothing(i)
            e = p.entries[i]
            n = next_id(p, Base.invokelatest(id_prefix, e.object))
            push!(p.entries, Entry(e.kind, n, e.code, nothing, e.pos, e.rot, e.pose0, e.meta,
                nothing, nothing))
            push!(new, n)
            return n
        end
        g = p.groups[findfirst(g -> g.name === id, p.groups)]
        members = Symbol[dup!(m) for m in g.members]
        n = next_id(p, "G")
        push!(p.groups, GroupEntry(n, members, g.pos, g.rot, nothing, nothing, nothing))
        push!(new, n)
        return n
    end
    copies = Symbol[dup!(id) for id in roots]
    # The pivot as an id is the position of the original, which its copy has too
    _move!(p, copies; offset, rot, pivot)
    for (orig, c) in zip(roots, copies)
        kind = _edit_kind(p, orig) === :group ? :component : _entry_of(p, orig).kind
        if systems === :same
            for s in collect(p.systems)
                (orig in s.members || orig in s.sources) && _edit_system!(p, s.name, c, kind)
            end
        else
            kind === :source && length(unique(systems)) > 1 &&
                throw(ArgumentError("`$orig` is a source and its copy belongs to at most one system, got $(join(systems, ", "))"))
            foreach(s -> _edit_system!(p, s, c, kind), unique(systems))
        end
    end
    _edit_check(p, new)
    save_project(p; by)
    _announce_wrote(p.path, by, "copied " * join(ids, ", ") * " as " * join(new, ", ");
        selected_id = String(first(new)))
    return new
end

"""
    remove!(dir, ids::Vector{Symbol}; by = nothing) -> Project

Removes the components, sources and groups `ids` of the live project in the folder `dir`, as the
window does: their lines and their places in the systems (members and sources) and groups. A
group is removed with its members, also those of the groups inside it. As in [`move!`](@ref), an
id inside a group must be given with its group (or a group around it); unknown ids and ids of
systems throw an `ArgumentError` naming the id. Returns the project loaded again from the written
files.

The checks and the write are those of [`add!`](@ref): a check that fails throws an
`ArgumentError`, and nothing is written.

# Examples

```julia
remove!(".", [:M3, :G2]; by = "claude")
```
"""
function remove!(dir::AbstractString, ids::Vector{Symbol}; by = nothing)
    p = load_project(dir)
    sel = unique(ids)
    foreach(id -> _edit_kind(p, id), sel)
    _check_with_groups(p, sel)
    gone = Set{Symbol}()
    function collect!(n)
        n in gone && return nothing
        push!(gone, n)
        i = findfirst(g -> g.name === n, p.groups)
        isnothing(i) || foreach(collect!, p.groups[i].members)
        return nothing
    end
    foreach(collect!, sel)
    filter!(e -> !(e.name in gone), p.entries)
    filter!(g -> !(g.name in gone), p.groups)
    for (i, g) in enumerate(p.groups)
        p.groups[i] = GroupEntry(g.name, filter(m -> !(m in gone), g.members), g.pos, g.rot,
            g.object, g.label, g.uid)
    end
    for (i, s) in enumerate(p.systems)
        p.systems[i] = SystemEntry(s.name, filter(m -> !(m in gone), s.members),
            filter(m -> !(m in gone), s.sources), s.static, s.object, s.label, s.uid)
    end
    _edit_check(p, sel)
    save_project(p; by)
    _announce_wrote(p.path, by, "removed " * join(ids, ", "); selected_id = "")
    return load_project(p.path)
end

"""`:entry` or `:group` for the id `id` of `p`; throws for a system or an unknown id."""
function _edit_kind(p::Project, id::Symbol)
    any(e -> e.name === id, p.entries) && return :entry
    any(g -> g.name === id, p.groups) && return :group
    any(s -> s.name === id, p.systems) &&
        throw(ArgumentError("`$id` is a system; give the ids of components, sources and groups"))
    throw(ArgumentError("unknown id `$id`: no component, source or group of the project"))
end

_entry_of(p::Project, id::Symbol) = p.entries[findfirst(e -> e.name === id, p.entries)]

"""Whether `id` is inside a group of `chosen` (at any depth), by the `parents` of `_group_parents`."""
function _inside_chosen(parents::Dict{Symbol, Symbol}, chosen::Set{Symbol}, id::Symbol)
    g = id
    seen = Set{Symbol}()
    while haskey(parents, g) && !(g in seen)
        push!(seen, g)
        g = parents[g]
        g in chosen && return true
    end
    return false
end

"""Throws if an id of `sel` is in a group that is not in `sel` (at any depth), as `move!`."""
function _check_with_groups(p::Project, sel::Vector{Symbol})
    parents = _group_parents(p)
    chosen = Set(sel)
    for id in sel
        haskey(parents, id) && !_inside_chosen(parents, chosen, id) &&
            throw(ArgumentError("`$id` is in the group `$(parents[id])`; give the group `$(_outermost(parents, id))`"))
    end
    return nothing
end

"""The expression of the code string `code` of a line, `what` (e.g. "`L1`") for the error."""
function _edit_parse(code::AbstractString, what)
    ex = try
        Meta.parse(code; raise = true)
    catch err
        throw(ArgumentError("$what: the code does not parse: $(_edit_cause(err))"))
    end
    (ex isa Expr && ex.head in (:incomplete, :error)) &&
        throw(ArgumentError("$what: the code does not parse: $(repr(code))"))
    return normalize_code(ex)
end

"""The object built by the expression `ex` in the module of `p`, as `load_project` builds a line."""
function _edit_build(p::Project, ex, what)
    mod = isnothing(p.mod) ? _project_module(p.path, p.name) : p.mod
    try
        return Core.eval(mod, ex)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("$what: the code does not build: $(_edit_cause(err))"))
    end
end

"""
The pose `pose0` of the just built `obj` of the line `id`, which is then posed by `pos` and `rot`
as `load_project` poses a line; an `ArgumentError` if `obj` can not be posed (no object).
"""
function _edit_place(@nospecialize(obj), pos, rot, id::Symbol)
    try
        pose0 = Base.invokelatest(pose_of, obj)
        Base.invokelatest(apply_pose!, obj, pos, rot)
        return pose0
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("`$id`: the code does not build an object that can be posed: $(_edit_cause(err))"))
    end
end

"""
`pos` and `rot` of a line as `Entry` keeps them, after checking that they are three finite
numbers (`rot`: or a 3×3 matrix); `nothing` stays.
"""
function _edit_pose(id::Symbol, pos, rot)
    if !isnothing(pos)
        (length(pos) == 3 && all(x -> x isa Real, pos)) ||
            throw(ArgumentError("pos of `$id` needs three numbers, got $(repr(pos))"))
    end
    if !isnothing(rot)
        ok = rot isa AbstractMatrix ? size(rot) == (3, 3) && all(x -> x isa Real, rot) :
             length(rot) == 3 && all(x -> x isa Real, rot)
        ok || throw(ArgumentError("rot of `$id` needs three angles or a 3×3 matrix, got $(repr(rot))"))
    end
    bad = _nonfinite(pos, rot)
    isnothing(bad) ||
        throw(ArgumentError("$bad of `$id` is not finite: $(repr(bad == "pos" ? pos : rot))"))
    pos = isnothing(pos) ? nothing : NTuple{3, Float64}(Tuple(Float64.(collect(pos))))
    rot = isnothing(rot) ? nothing :
          rot isa AbstractMatrix ? Matrix{Float64}(rot) : NTuple{3, Float64}(Tuple(Float64.(collect(rot))))
    return pos, rot
end

# Angles that are all zero are no rotation: the line gets no `rot`
_no_angles(rot) = !(rot isa AbstractMatrix) && !isnothing(rot) && length(rot) == 3 &&
                  all(x -> x isa Real && iszero(x), rot) ? nothing : rot

# The label of a line: `nothing` and "" are none
_edit_label(::Nothing) = nothing
_edit_label(label) = isempty(label) ? nothing : String(label)

"""Adds `id` (a `:component` or a `:source` by `kind`) to the system `s` of `p`, once."""
function _edit_system!(p::Project, s::Symbol, id::Symbol, kind::Symbol)
    i = findfirst(x -> x.name === s, p.systems)
    x = p.systems[i]
    members, sources = copy(x.members), copy(x.sources)
    list = kind === :source ? sources : members
    id in list || push!(list, id)
    p.systems[i] = SystemEntry(x.name, members, sources, x.static, x.object, x.label, x.uid)
    return p
end

"""
Checks the changed project `p` before it is written: `system.jl` of it loads, with the own code of
the project, in a copy of the folder in `tempdir()`. Throws an `ArgumentError` naming the `ids`
and the first line of the cause.
"""
function _edit_check(p::Project, ids::Vector{Symbol})
    names = join(("`$id`" for id in ids), ", ")
    root = mktempdir(; cleanup = false)
    try
        text = system_code(p)
        dir = joinpath(root, basename(p.path))
        mkpath(dir)
        toml = joinpath(p.path, "Project.toml")
        isfile(toml) && cp(toml, joinpath(dir, "Project.toml"))
        src = joinpath(p.path, "src")
        isdir(src) && cp(src, joinpath(dir, "src"))
        file = joinpath(dir, "system.jl")
        write(file, text)
        _load_project(dir, file)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("$names: $(_edit_cause(err)); the project is not written"))
    finally
        rm(root; recursive = true, force = true)
    end
    return nothing
end

"""The first line of the message of `err`, without the wrapping of an `include`."""
function _edit_cause(err)
    while err isa LoadError
        err = err.error
    end
    msg = err isa ArgumentError ? err.msg : sprint(showerror, err)
    return strip(first(split(msg, '\n')))
end
