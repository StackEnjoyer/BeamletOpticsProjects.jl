#=
The macros of system.jl: each builds one thing, keeps how it was built and registers it in the
project that is being loaded (see `load_project`)
=#

"""Key of the project that `load_project` fills, in the task-local storage."""
const _LOADING = :BeamletOpticsProjects_loading

"""The project that is being loaded, or `nothing` (a plain `include` of `system.jl`)."""
_loading() = get(task_local_storage(), _LOADING, nothing)

"""
    @component name = expr [pos = (x, y, z)] [rot = (a, b, c)] [key = value ...]

Builds the component `expr`, binds it to `name` and, while a project is loaded, registers it under
`name` with its recipe `expr`. `pos` is the absolute position in m, `rot` the rotation since
construction as angles in degrees about the global x-, y- and z-axes (or a 3×3 matrix), see
[`apply_pose!`](@ref). Further keywords are kept with the entry (e.g. `catalog` of the GUI).
"""
macro component(args...)
    return _entry_macro(:component, __source__, args)
end

"""
    @source name = expr [pos = (x, y, z)] [rot = (a, b, c)] [key = value ...]

Like [`@component`](@ref) for a source (a beam or a beam group).
"""
macro source(args...)
    return _entry_macro(:source, __source__, args)
end

"""
    @system name = [members...] [sources = [names...]] [static = true]

Builds a `System` (a `StaticSystem` with `static = true`) of the components `members` and binds it
to `name`; `sources` are the sources traced in it. A component may be a member of several systems,
a source belongs to at most one.
"""
macro system(args...)
    return _system_macro(__source__, args)
end

"""`file:line` of a macro call, for error messages."""
_where(src::LineNumberNode) = string(src.file === nothing ? "system.jl" : basename(string(src.file)),
    ":", src.line)

"""Splits the arguments `name = expr key = value ...` of a macro."""
function _split_args(macroname, src, args)
    where = _where(src)
    isempty(args) && throw(ArgumentError("$where: $macroname needs `name = ...`"))
    head = args[1]
    (head isa Expr && head.head === :(=) && head.args[1] isa Symbol) ||
        throw(ArgumentError("$where: $macroname needs `name = ...`, got `$head`"))
    kws = Pair{Symbol, Any}[]
    for a in args[2:end]
        (a isa Expr && a.head === :(=) && a.args[1] isa Symbol) ||
            throw(ArgumentError("$where: $macroname takes `key = value` after the name, got `$a`"))
        any(k -> k == a.args[1], first.(kws)) &&
            throw(ArgumentError("$where: keyword `$(a.args[1])` given twice"))
        push!(kws, a.args[1] => a.args[2])
    end
    return head.args[1]::Symbol, head.args[2], kws, where
end

function _entry_macro(kind::Symbol, src, args)
    name, ex, kws, where = _split_args("@$kind", src, args)
    pos = rot = label = uid = nothing
    meta = Expr[]
    for (k, v) in kws
        if k === :pos
            pos = esc(v)
        elseif k === :rot
            rot = esc(v)
        elseif k === :label
            label = esc(v)
        elseif k === :uid
            uid = esc(v)
        else
            push!(meta, :($(QuoteNode(k)) => $(esc(v))))
        end
    end
    code = QuoteNode(normalize_code(ex))
    return quote
        $(esc(name)) = $(_register_entry!)($(QuoteNode(kind)), $(QuoteNode(name)), $code,
            $(esc(ex)), $pos, $rot, Pair{Symbol, Any}[$(meta...)], $label, $uid, $where)
    end
end

function _system_macro(src, args)
    name, members, kws, where = _split_args("@system", src, args)
    sources, static, label, uid = :([]), false, nothing, nothing
    for (k, v) in kws
        if k === :sources
            sources = v
        elseif k === :label
            label = esc(v)
        elseif k === :uid
            uid = esc(v)
        elseif k === :static
            v isa Bool || throw(ArgumentError("$where: static must be true or false"))
            static = v
        else
            throw(ArgumentError("$where: @system has no keyword `$k`"))
        end
    end
    m, s = _names(members, "members", where), _names(sources, "sources", where)
    # Outside of `load_project` the names are the variables that @component and @source bound
    return quote
        $(esc(name)) = $(_register_system!)($(QuoteNode(name)), $m, $s, $static, $label, $uid, $where,
            () -> Any[$(map(esc, m)...)], () -> Any[$(map(esc, s)...)])
    end
end

"""The names of a vector `[a, b, ...]` in `@system`."""
function _names(ex, what, where)
    (ex isa Expr && ex.head === :vect && all(a -> a isa Symbol, ex.args)) ||
        throw(ArgumentError("$where: $what of @system must be a list of names `[a, b]`, got `$ex`"))
    return Symbol[ex.args...]
end

"""Every name of `p`, entries and systems."""
_taken(p::Project, name::Symbol) = any(e -> e.name === name, p.entries) ||
                                   any(s -> s.name === name, p.systems)

function _register_entry!(kind::Symbol, name::Symbol, code, @nospecialize(obj), pos, rot, meta,
        label, uid, where::String)
    p = _loading()
    p !== nothing && _taken(p, name) &&
        throw(ArgumentError("$where: the name `$name` is used twice"))
    p === nothing || _check_uid(p, uid, where)
    pose0 = pose_of(obj)
    apply_pose!(obj, pos, rot)
    p === nothing || push!(p.entries, Entry(kind, name, code, obj; pos, rot, pose0, meta, label, uid))
    return obj
end

function _register_system!(name::Symbol, members::Vector{Symbol}, sources::Vector{Symbol},
        static::Bool, label, uid, where::String, member_objects, source_objects)
    p = _loading()
    if p === nothing
        objs = member_objects()
        return static ? StaticSystem(objs) : isempty(objs) ? System() : System(objs)
    end
    _taken(p, name) && throw(ArgumentError("$where: the name `$name` is used twice"))
    _check_uid(p, uid, where)
    # Built when all lines are read (see `_build_systems!`): a member may be defined below
    push!(p.systems, SystemEntry(name, members, sources; static, label, uid))
    push!(get!(Vector{String}, task_local_storage(), _WHERE), where)
    return nothing
end

"""Key of the places (`file:line`) of the systems of the project being loaded."""
const _WHERE = :BeamletOpticsProjects_where

"""
Builds the systems of the project `p` that `load_project` read, after all lines: the members and
sources by their ids, at the places `wheres` (`file:line`) for the error messages.
"""
function _build_systems!(p::Project, wheres::Vector{String})
    taken = Dict{Symbol, Symbol}()
    for (i, (se, where)) in enumerate(zip(p.systems, wheres))
        objs = Any[_lookup(p, n, :component, where) for n in se.members]
        foreach(n -> _lookup(p, n, :source, where), se.sources)
        for n in se.sources
            haskey(taken, n) &&
                throw(ArgumentError("$where: the source `$n` is already in the system `$(taken[n])`"))
            taken[n] = se.name
        end
        sys = se.static ? StaticSystem(objs) : isempty(objs) ? System() : System(objs)
        p.systems[i] = SystemEntry(se.name, se.members, se.sources, se.static, sys, se.label, se.uid)
    end
    return p
end

"""Throws if the machine id `uid` is in `p` already, e.g. a line that was copied with it."""
function _check_uid(p::Project, uid, where::String)
    isnothing(uid) && return nothing
    uid isa AbstractString || throw(ArgumentError("$where: uid must be a string"))
    any(e -> e.uid == uid, p.entries) || any(s -> s.uid == uid, p.systems) || return nothing
    throw(ArgumentError("$where: the uid \"$uid\" is used twice; a new line has no uid, it gets one when it is saved"))
end

function _lookup(p::Project, name::Symbol, kind::Symbol, where::String)
    for e in p.entries
        e.name === name || continue
        e.kind === kind && return e.object
        throw(ArgumentError("$where: `$name` is a $(e.kind), not a $kind"))
    end
    throw(ArgumentError("$where: unknown $kind `$name` (define it with @$kind above)"))
end

"""
    normalize_code(ex)

`ex` without line numbers and with the bodies `begin x end` of short functions such as `λ -> 1.5`
unwrapped, so that it prints on one line and reads back the same.
"""
function normalize_code(@nospecialize(ex))
    ex isa Expr || return ex
    args = Any[normalize_code(a) for a in ex.args if !(a isa LineNumberNode)]
    if ex.head === :-> && length(args) == 2 && args[2] isa Expr && args[2].head === :block &&
       length(args[2].args) == 1
        args[2] = args[2].args[1]
    end
    return Expr(ex.head, args...)
end
