#=
Differences between two states of a project, by the machine ids of the entries and systems
=#

"""
    EntryChange(uid, kind, old, new)

A change of the entry with the machine id `uid` from `old` to `new` (an [`Entry`](@ref) or
`nothing`), see [`diff_projects`](@ref). `kind` is one of `:added`, `:removed`, `:renamed` (other
readable id), `:rebuilt` (other code or own code), `:moved` (other `pos` or `rot`), `:relabeled`
and `:meta`; one entry can have several changes, e.g. `:renamed` and `:moved`.
"""
struct EntryChange
    uid::Union{Nothing, String}
    kind::Symbol
    old::Union{Nothing, Entry}
    new::Union{Nothing, Entry}
end

"""
    SystemChange(uid, kind, old, new)

A change of the system with the machine id `uid`, like [`EntryChange`](@ref): `kind` is one of
`:added`, `:removed`, `:renamed`, `:relabeled` and `:members` (other members, sources or `static`).
"""
struct SystemChange
    uid::Union{Nothing, String}
    kind::Symbol
    old::Union{Nothing, SystemEntry}
    new::Union{Nothing, SystemEntry}
end

"""
    diff_projects(base, new; rebuild = Symbol[]) -> (; entries, systems)

The changes from the project `base` to `new`, as `entries::Vector{EntryChange}` and
`systems::Vector{SystemChange}`. Entries and systems are paired by their `uid`; one without a uid
in `new` is `:added`. The order of the lines does not matter. The entries whose readable ids are in
`rebuild` count as `:rebuilt` even with the same code, e.g. since the own code that they call
changed.
"""
function diff_projects(base::Project, new::Project; rebuild = Symbol[])
    pairs, added, removed = _pair(base.entries, new.entries)
    kinds = (:removed, :renamed, :rebuilt, :moved, :relabeled, :meta, :added)
    found = Dict{Symbol, Vector{EntryChange}}(k => EntryChange[] for k in kinds)
    change!(kind, old, new) = push!(found[kind], EntryChange(something(new, old).uid, kind, old, new))
    foreach(e -> change!(:removed, e, nothing), removed)
    foreach(e -> change!(:added, nothing, e), added)
    for (old, e) in pairs
        old.name == e.name || change!(:renamed, old, e)
        if old.kind != e.kind || _code_key(old.code) != _code_key(e.code) ||
           e.name in rebuild || old.name in rebuild
            change!(:rebuilt, old, e)
        elseif !_same_pose(old, e)
            change!(:moved, old, e)
        end
        old.label == e.label || change!(:relabeled, old, e)
        _same_meta(old.meta, e.meta) || change!(:meta, old, e)
    end
    spairs, sadded, sremoved = _pair(base.systems, new.systems)
    skinds = (:removed, :renamed, :relabeled, :members, :added)
    sfound = Dict{Symbol, Vector{SystemChange}}(k => SystemChange[] for k in skinds)
    schange!(kind, old, new) = push!(sfound[kind], SystemChange(something(new, old).uid, kind, old, new))
    foreach(s -> schange!(:removed, s, nothing), sremoved)
    foreach(s -> schange!(:added, nothing, s), sadded)
    for (old, s) in spairs
        old.name == s.name || schange!(:renamed, old, s)
        old.label == s.label || schange!(:relabeled, old, s)
        (old.static != s.static || _keys(base, old.members) != _keys(new, s.members) ||
         _keys(base, old.sources) != _keys(new, s.sources)) && schange!(:members, old, s)
    end
    return (; entries = reduce(vcat, (found[k] for k in kinds)),
        systems = reduce(vcat, (sfound[k] for k in skinds)))
end

"""
Pairs the entries (or systems) of two states: by `uid`, then the remaining ones without a uid in
`old` by their readable id. Returns the `pairs` `(old, new)` and the unpaired `added` and `removed`.
"""
function _pair(olds::Vector{T}, news::Vector{T}) where {T}
    byuid = Dict{String, T}(x.uid => x for x in olds if !isnothing(x.uid))
    used = Set{String}()
    pairs = Tuple{T, T}[]
    rest = T[]
    for x in news
        old = isnothing(x.uid) ? nothing : get(byuid, x.uid, nothing)
        if isnothing(old)
            push!(rest, x)
        else
            push!(pairs, (old, x))
            push!(used, x.uid)
        end
    end
    # Lines of an agent without uid (or entries of a state before the first save): paired by their
    # readable id with an old one that is not paired yet; a new one with an unknown uid only with
    # an old one without uid
    free = T[x for x in olds if isnothing(x.uid) || !(x.uid in used)]
    added = T[]
    for x in rest
        i = findfirst(o -> o.name === x.name && (isnothing(x.uid) || isnothing(o.uid)), free)
        if isnothing(i)
            push!(added, x)
        else
            push!(pairs, (free[i], x))
            deleteat!(free, i)
        end
    end
    return pairs, added, free
end

_code_key(@nospecialize(code)) = code isa AbstractString ? _code_key(Meta.parse(code)) :
                                 string(normalize_code(code))

# The same position (exactly) and rotation (within 1e-13); `nothing` is the constructed pose
function _same_pose(a::Entry, b::Entry)
    pos(e) = isnothing(e.pos) ? e.pose0[1] : collect(e.pos)
    pos(a) == pos(b) || return false
    return maximum(abs, rotation_matrix(a.rot) - rotation_matrix(b.rot)) <= _ROT_TOL
end

_same_meta(a, b) = isequal(Dict{Symbol, Any}(a), Dict{Symbol, Any}(b))

# The members of a system as a set of uids (or ids for entries without one) of the project `p`
function _keys(p::Project, names::Vector{Symbol})
    keys = Set{String}()
    for n in names
        i = findfirst(e -> e.name === n, p.entries)
        push!(keys, isnothing(i) || isnothing(p.entries[i].uid) ? "id:" * String(n) : p.entries[i].uid)
    end
    return keys
end

"""
    copy_code(from, to)

Copies the own code of the project in the folder `from` (every file in `src/`) to the folder `to`,
without overwriting a file that exists there; nothing if `from` has no `src/`.
"""
function copy_code(from::AbstractString, to::AbstractString)
    src = joinpath(abspath(from), "src")
    isdir(src) || return nothing
    for (root, _, files) in walkdir(src), f in files
        target = joinpath(abspath(to), "src", relpath(joinpath(root, f), src))
        isfile(target) && continue
        mkpath(dirname(target))
        cp(joinpath(root, f), target)
    end
    return nothing
end

"""
    same_entry(a, b) -> Bool

Whether the entries `a` and `b` (of two states of a project) describe the same thing: the same
kind, readable id, code, pose, label and further keywords.
"""
same_entry(a::Entry, b::Entry) = a.kind == b.kind && a.name == b.name &&
                                 _code_key(a.code) == _code_key(b.code) && _same_pose(a, b) &&
                                 a.label == b.label && _same_meta(a.meta, b.meta)

"""
    same_system(a, pa, b, pb) -> Bool

Whether the systems `a` of the project `pa` and `b` of `pb` are the same: id, label, `static`, and
members and sources (compared by their machine ids).
"""
same_system(a::SystemEntry, pa::Project, b::SystemEntry, pb::Project) =
    a.name == b.name && a.label == b.label && a.static == b.static &&
    _keys(pa, a.members) == _keys(pb, b.members) && _keys(pa, a.sources) == _keys(pb, b.sources)

"""A new machine id: a UUID (version 4) as a string."""
new_uid() = string(uuid4())

"""
    match_entries(olds, news) -> (; pairs, added, removed)

Pairs the entries (or systems) of two states like [`diff_projects`](@ref): by `uid`, then the
remaining ones without a uid in `olds` by their readable id. `pairs` are the `(old, new)` tuples,
`added` the unpaired ones of `news`, `removed` those of `olds`.
"""
function match_entries(olds::Vector{T}, news::Vector{T}) where {T}
    pairs, added, removed = _pair(olds, news)
    return (; pairs, added, removed)
end
