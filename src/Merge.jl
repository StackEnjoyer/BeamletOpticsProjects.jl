#=
Three-way merge of two states of a project that changed from a common base: which changes of
"theirs" to take into "mine", and which are conflicts. Used by the open window for changes of the
files (an agent, another person) and for drafts of teams (see `Teams.jl`)
=#

# The key of an entry or a system: its machine id, or its readable id for a line without one
_merge_key(x) = isnothing(x.uid) ? "id:" * String(x.name) : x.uid
_change_key(c) = _merge_key(something(c.old, c.new))

# The entry (or system) of the `key` in `xs`, by machine id or by readable id ("id:L1")
function _by_merge_key(xs, key::String)
    if startswith(key, "id:")
        name = Symbol(key[4:end])
        i = findfirst(x -> x.name === name, xs)
    else
        i = findfirst(x -> x.uid == key, xs)
    end
    return isnothing(i) ? nothing : xs[i]
end

# Whether the entry or system of the `key` is the same in the projects `a` and `b`
function _same_state(a::Project, b::Project, key::String)
    ea, eb = _by_merge_key(a.entries, key), _by_merge_key(b.entries, key)
    if !(isnothing(ea) && isnothing(eb))
        (isnothing(ea) || isnothing(eb)) && return false
        return same_entry(ea, eb)
    end
    sa, sb = _by_merge_key(a.systems, key), _by_merge_key(b.systems, key)
    (isnothing(sa) && isnothing(sb)) && return true
    (isnothing(sa) || isnothing(sb)) && return false
    return same_system(sa, a, sb, b)
end

# The same, with the members and sources of systems compared by their partners in `base` (a uid
# given to a line since is no change)
function _same_state(base::Project, a::Project, b::Project, key::String)
    sa, sb = _by_merge_key(a.systems, key), _by_merge_key(b.systems, key)
    (isnothing(sa) || isnothing(sb)) && return _same_state(a, b, key)
    return sa.name == sb.name && sa.label == sb.label && _same_members(base, a, sa, b, sb)
end

# The keys of the entries (or systems) `xs` of a project by readable id: the key of their partner in
# `base_xs` (see `match_entries`), else their own; the same thing has the same key in every state
function _base_keys(base_xs, xs)
    keys = Dict{Symbol, String}(x.name => _merge_key(x) for x in xs)
    for (old, new) in match_entries(base_xs, xs).pairs
        keys[new.name] = _merge_key(old)
    end
    return keys
end
_base_keys(base::Project, p::Project) =
    merge(_base_keys(base.entries, p.entries), _base_keys(base.systems, p.systems))
_keys_of(keys, names) = Set{String}(get(keys, n, "id:" * String(n)) for n in names)

# Whether the system `sa` of the project `a` and `sb` of `b` have the same `static`, members and
# sources, with the entries compared by their partners in `base`
function _same_members(base::Project, a::Project, sa, b::Project, sb)
    sa.static == sb.static || return false
    ka, kb = _base_keys(base.entries, a.entries), _base_keys(base.entries, b.entries)
    return _keys_of(ka, sa.members) == _keys_of(kb, sb.members) &&
           _keys_of(ka, sa.sources) == _keys_of(kb, sb.sources)
end

# Whether the change `c` from `base` to `p` is a change of the merge: not a change `:members` of a
# system whose members and sources only got uids (e.g. when `p` was saved)
_real_change(base::Project, p::Project, c) =
    !(c isa SystemChange && c.kind === :members && _same_members(base, base, c.old, p, c.new))

"""
The members and sources of the system of the `key` merged as sets of entry keys, if both `mine`
and `theirs` changed only them since `base` (same id, label and `static`, the system in all three):
`(mine ∪ (theirs − base)) − (base − theirs)`, each; `nothing` otherwise. The entries are compared by
their partners in `base`, such that a uid given to a line since does not make another entry of it;
the keys of the result are those of `mine`, else of `theirs`.
"""
function _merged_members(base::Project, mine::Project, theirs::Project, key::String)
    sb, sm, st = (_by_merge_key(p.systems, key) for p in (base, mine, theirs))
    any(isnothing, (sb, sm, st)) && return nothing
    (sm.name === st.name && sm.label == st.label && sm.static == st.static) || return nothing
    kb, km, kt = (_base_keys(base.entries, p.entries) for p in (base, mine, theirs))
    own = Dict{String, String}()
    for (p, ks) in ((theirs, kt), (mine, km)), e in p.entries
        own[ks[e.name]] = _merge_key(e)
    end
    function merged(f)
        b, m, t = _keys_of(kb, f(sb)), _keys_of(km, f(sm)), _keys_of(kt, f(st))
        return Set{String}(get(own, k, k) for k in setdiff(union(m, setdiff(t, b)), setdiff(b, t)))
    end
    return (; members = merged(s -> s.members), sources = merged(s -> s.sources))
end

# The prefix of a readable id, e.g. "BS" of `BS12`
function _id_prefix_of(name::Symbol)
    m = match(r"^(.*?)\d+$", String(name))
    return isnothing(m) ? String(name) : String(m.captures[1])
end

"""
New readable ids for the entries and systems `added` by "theirs" (`key => entry or system`,
added or renamed, in this order) whose id another entry or system of `mine` has already: the next
free id of the same prefix in both projects (see [`next_id`](@ref)), by key.
"""
function _renumbered(base::Project, mine::Project, theirs::Project, added)
    taken = Project(mine.path, "taken"; entries = Entry[mine.entries..., theirs.entries...],
        systems = SystemEntry[mine.systems..., theirs.systems...])
    km = _base_keys(base, mine)
    renames = Dict{String, Symbol}()
    for (k, x) in added
        get(km, x.name, k) == k && continue
        id = next_id(taken, _id_prefix_of(x.name))
        push!(taken.systems, SystemEntry(id, Symbol[]))
        renames[k] = id
    end
    return renames
end

# The keys of the systems that would hold the same source in the merged state, sorted: the systems
# of `take` as in `theirs`, those of `merged` with their merged sources, the others as in `mine`
function _shared_sources(base::Project, mine::Project, theirs::Project, take, merged)
    km, kt = _base_keys(base, mine), _base_keys(base, theirs)
    tobase = Dict{String, String}()
    for (p, ks) in ((mine, km), (theirs, kt)), e in p.entries
        tobase[_merge_key(e)] = ks[e.name]
    end
    holders = Dict{String, Vector{String}}()
    hold!(src, k) = push!(get!(holders, src, String[]), k)
    for s in mine.systems
        k = km[s.name]
        (k in take || haskey(merged, k)) && continue
        foreach(src -> hold!(src, k), _keys_of(km, s.sources))
    end
    for s in theirs.systems
        k = kt[s.name]
        k in take && foreach(src -> hold!(src, k), _keys_of(kt, s.sources))
    end
    for (k, m) in merged
        foreach(src -> hold!(src, k), Set{String}(get(tobase, x, x) for x in m.sources))
    end
    return sort!(unique!(String[k for ks in values(holders) if length(unique(ks)) > 1 for k in ks]))
end

"""
    merge_plan(base, mine, theirs; stale = key -> false, rebuild = Symbol[], keep = String[])
        -> (; take, conflicts, merged, renames, mine, theirs)

What to take from the project `theirs` into `mine`, which both changed from the common state
`base` (e.g. the files changed by an agent and the setup in an open window, or the draft of a team
and the live project). Entries and systems are compared by their keys: the machine id, or `"id:L1"`
for a line without one (see [`diff_projects`](@ref)).

- `take`: the keys that only `theirs` changed, or that both changed to the same state; the caller
  applies the entries and systems of `theirs` for them.
- `conflicts`: the keys that both changed differently, those that only `theirs` changed but for
  which `stale(key)` is `true` (e.g. `theirs` sets back a state that `mine` wrote, from an older
  read), and the keys of `keep` (conflicts still open from before) unless `mine` and `theirs` agree
  on them now (or merge their members and sources, see `merged`), and the systems that would hold the
  same source otherwise (e.g. both moved it into another system), since a source belongs to at most
  one system. Nothing of them is taken.
- `merged`: the systems that both changed only in their members or sources, which is no conflict:
  their members and sources merged as sets of entry keys, `key => (; members, sources)`, each
  `(mine ∪ (theirs − base)) − (base − theirs)`, e.g. both added a lens to `S1`.
- `renames`: the entries and systems of `take` that `theirs` added or renamed to a readable id that
  another entry or system of `mine` has already, by key, with the next free id of the same prefix;
  the caller adds them under that id, and the systems refer to them by it.
- `mine`, `theirs`: the changes of each since `base`, see [`diff_projects`](@ref); `rebuild` names
  the entries of `theirs` that count as rebuilt (e.g. since the own code that they call changed).
"""
function merge_plan(base::Project, mine::Project, theirs::Project; stale = key -> false,
        rebuild = Symbol[], keep = String[])
    d = diff_projects(base, theirs; rebuild)
    g = diff_projects(base, mine)
    theirs_keys = Set{String}(_change_key(c) for c in Iterators.flatten((d.entries, d.systems))
                              if _real_change(base, theirs, c))
    mine_keys = Set{String}(_change_key(c) for c in Iterators.flatten((g.entries, g.systems))
                            if _real_change(base, mine, c))
    merged = Dict{String, @NamedTuple{members::Set{String}, sources::Set{String}}}()
    conflicts = String[]
    for k in theirs_keys
        if k in mine_keys
            _same_state(base, mine, theirs, k) && continue
            m = _merged_members(base, mine, theirs, k)
            isnothing(m) ? push!(conflicts, k) : (merged[k] = m)
        elseif stale(k)
            push!(conflicts, k)
        end
    end
    still = String[k for k in keep if !(k in conflicts) && !haskey(merged, k) && !_same_state(base, mine, theirs, k)]
    conflicts = vcat(still, conflicts)
    take = setdiff(theirs_keys, conflicts, keys(merged))
    # A source in two systems: both are conflicts (each round sets back systems to the state of mine)
    while true
        shared = setdiff(_shared_sources(base, mine, theirs, take, merged), conflicts)
        isempty(shared) && break
        append!(conflicts, shared)
        foreach(k -> delete!(merged, k), shared)
        take = setdiff(theirs_keys, conflicts, keys(merged))
    end
    added = Dict{String, Any}(_change_key(c) => c.new for c in Iterators.flatten((d.entries, d.systems))
                              if c.kind in (:added, :renamed) && _change_key(c) in take)
    renames = _renumbered(base, mine, theirs, sort!(collect(added); by = first))
    return (; take, conflicts, merged, renames, mine = g, theirs = d)
end
