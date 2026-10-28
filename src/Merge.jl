#=
Three-way merge of two states of a project that changed from a common base: which changes of
"theirs" to take into "mine", and which are conflicts. Used by the open window for changes of the
files (an agent, another person) and for drafts of teams (see `Teams.jl`); `compose` builds the
state of one with the other at some keys (e.g. the open conflicts of a window)
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

# Whether the entry, system or group of the `key` is the same in the projects `a` and `b`
function _same_state(a::Project, b::Project, key::String)
    ea, eb = _by_merge_key(a.entries, key), _by_merge_key(b.entries, key)
    if !(isnothing(ea) && isnothing(eb))
        (isnothing(ea) || isnothing(eb)) && return false
        return same_entry(ea, eb)
    end
    sa, sb = _by_merge_key(a.systems, key), _by_merge_key(b.systems, key)
    if !(isnothing(sa) && isnothing(sb))
        (isnothing(sa) || isnothing(sb)) && return false
        return same_system(sa, a, sb, b)
    end
    ga, gb = _by_merge_key(a.groups, key), _by_merge_key(b.groups, key)
    (isnothing(ga) && isnothing(gb)) && return true
    (isnothing(ga) || isnothing(gb)) && return false
    return same_group(ga, a, gb, b)
end

# The same, with the members and sources of systems and groups compared by their partners in `base`
# (a uid given to a line since is no change)
function _same_state(base::Project, a::Project, b::Project, key::String)
    sa, sb = _by_merge_key(a.systems, key), _by_merge_key(b.systems, key)
    if !(isnothing(sa) || isnothing(sb))
        return sa.name == sb.name && sa.label == sb.label && _same_members(base, a, sa, b, sb)
    end
    ga, gb = _by_merge_key(a.groups, key), _by_merge_key(b.groups, key)
    (isnothing(ga) || isnothing(gb)) && return _same_state(a, b, key)
    return ga.name == gb.name && ga.label == gb.label && _same_group_pose(ga, gb) &&
           _same_members(base, a, ga, b, gb)
end

# The keys of the entries (or systems, or groups) `xs` of a project by readable id: the key of their
# partner in `base_xs` (see `match_entries`), else their own; the same thing has the same key in
# every state
function _base_keys(base_xs, xs)
    keys = Dict{Symbol, String}(x.name => _merge_key(x) for x in xs)
    for (old, new) in match_entries(base_xs, xs).pairs
        keys[new.name] = _merge_key(old)
    end
    return keys
end
_base_keys(base::Project, p::Project) = merge(_base_keys(base.entries, p.entries),
    _base_keys(base.systems, p.systems), _base_keys(base.groups, p.groups))
# The base keys of what can be a member of a system or group: entries and groups
_member_keys(base::Project, p::Project) =
    merge(_base_keys(base.entries, p.entries), _base_keys(base.groups, p.groups))
_keys_of(keys, names) = Set{String}(get(keys, n, "id:" * String(n)) for n in names)

# Whether the system (or group) `sa` of the project `a` and `sb` of `b` have the same `static`,
# members and sources, with the entries and groups compared by their partners in `base`
function _same_members(base::Project, a::Project, sa, b::Project, sb)
    ka, kb = _member_keys(base, a), _member_keys(base, b)
    _keys_of(ka, sa.members) == _keys_of(kb, sb.members) || return false
    sa isa GroupEntry && return true
    return sa.static == sb.static && _keys_of(ka, sa.sources) == _keys_of(kb, sb.sources)
end

# Whether the change `c` from `base` to `p` is a change of the merge: not a change `:members` of a
# system or group whose members and sources only got uids (e.g. when `p` was saved)
_real_change(base::Project, p::Project, c) =
    !(c isa Union{SystemChange, GroupChange} && c.kind === :members &&
      _same_members(base, base, c.old, p, c.new))

"""
The members and sources of the system (or the members of the group) of the `key` merged as sets
of keys of entries and groups, if both `mine` and `theirs` changed only them since `base` (same id,
label and `static` of a system, same pivot and orientation of a group, in all three):
`(mine ∪ (theirs − base)) − (base − theirs)`, each; `nothing` otherwise. The entries and groups are
compared by their partners in `base`, such that a uid given to a line since does not make another
one of it; the keys of the result are those of `mine`, else of `theirs`. A group has no `sources`.
"""
function _merged_members(base::Project, mine::Project, theirs::Project, key::String)
    sb, sm, st = (_by_merge_key(p.systems, key) for p in (base, mine, theirs))
    if any(isnothing, (sb, sm, st))
        sb, sm, st = (_by_merge_key(p.groups, key) for p in (base, mine, theirs))
        any(isnothing, (sb, sm, st)) && return nothing
        (sm.name === st.name && sm.label == st.label && _same_group_pose(sm, st)) || return nothing
        return (; members = _merged_set(base, mine, theirs, x -> x.members, sb, sm, st),
            sources = Set{String}())
    end
    (sm.name === st.name && sm.label == st.label && sm.static == st.static) || return nothing
    return (; members = _merged_set(base, mine, theirs, s -> s.members, sb, sm, st),
        sources = _merged_set(base, mine, theirs, s -> s.sources, sb, sm, st))
end

# The names `f` of `xb`, `xm`, `xt` (of `base`, `mine`, `theirs`) merged as a set of keys
function _merged_set(base::Project, mine::Project, theirs::Project, f, xb, xm, xt)
    kb, km, kt = (_member_keys(base, p) for p in (base, mine, theirs))
    own = Dict{String, String}()
    for (p, ks) in ((theirs, kt), (mine, km)), x in Iterators.flatten((p.entries, p.groups))
        own[ks[x.name]] = _merge_key(x)
    end
    b, m, t = _keys_of(kb, f(xb)), _keys_of(km, f(xm)), _keys_of(kt, f(xt))
    return Set{String}(get(own, k, k) for k in setdiff(union(m, setdiff(t, b)), setdiff(b, t)))
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
        systems = SystemEntry[mine.systems..., theirs.systems...],
        groups = GroupEntry[mine.groups..., theirs.groups...])
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
The keys of the systems and groups that would break the tree of groups in the merged state, sorted
(the systems and groups of `take` as in `theirs`, those of `merged` with their merged members, the
others as in `mine`): all that hold an entry or group that a group holds too (an entry or group is
a member of at most one group, and one inside a group is in systems only through that group), and
those that hold a group that the merged state does not have (e.g. `theirs` removed it, or it is a
conflict and `mine` has none).
"""
function _tree_conflicts(base::Project, mine::Project, theirs::Project, take, merged)
    km, kt = _base_keys(base, mine), _base_keys(base, theirs)
    tobase = Dict{String, String}()
    for (p, ks) in ((mine, km), (theirs, kt)), x in Iterators.flatten((p.entries, p.groups))
        tobase[_merge_key(x)] = ks[x.name]
    end
    # The systems and groups of the merged state: key => (whether a group, keys of its members)
    held = Dict{String, Tuple{Bool, Set{String}}}()
    for (isgroup, xs) in ((false, mine.systems), (true, mine.groups)), x in xs
        k = km[x.name]
        k in take && continue
        members = haskey(merged, k) ? Set{String}(get(tobase, m, m) for m in merged[k].members) :
                  _keys_of(km, x.members)
        held[k] = (isgroup, members)
    end
    for (isgroup, xs) in ((false, theirs.systems), (true, theirs.groups)), x in xs
        k = kt[x.name]
        k in take && (held[k] = (isgroup, _keys_of(kt, x.members)))
    end
    groups = Set{String}(k for (k, (isgroup, _)) in held if isgroup)
    known = union(Set{String}(km[g.name] for g in mine.groups), Set{String}(kt[g.name] for g in theirs.groups),
        Set{String}(_merge_key(g) for g in base.groups))
    holders = Dict{String, Vector{String}}()
    bad = Set{String}()
    for (k, (_, members)) in held, m in members
        push!(get!(holders, m, String[]), k)
        m in known && !(m in groups) && push!(bad, k)
    end
    for hs in values(holders)
        any(in(groups), hs) && length(unique(hs)) > 1 && union!(bad, hs)
    end
    return sort!(collect(bad))
end

"""
    merge_plan(base, mine, theirs; stale = key -> false, rebuild = Symbol[], keep = String[])
        -> (; take, conflicts, merged, renames, mine, theirs)

What to take from the project `theirs` into `mine`, which both changed from the common state
`base` (e.g. the files changed by an agent and the setup in an open window, or the draft of a team
and the live project). Entries, systems and groups are compared by their keys: the machine id, or
`"id:L1"` for a line without one (see [`diff_projects`](@ref)).

- `take`: the keys that only `theirs` changed, or that both changed to the same state; the caller
  applies the entries and systems of `theirs` for them.
- `conflicts`: the keys that both changed differently, those that only `theirs` changed but for
  which `stale(key)` is `true` (e.g. `theirs` sets back a state that `mine` wrote, from an older
  read), and the keys of `keep` (conflicts still open from before) unless `mine` and `theirs` agree
  on them now (or merge their members and sources, see `merged`), the systems that would hold the
  same source otherwise (e.g. both moved it into another system), since a source belongs to at most
  one system, and the systems and groups that would break the tree of groups otherwise (an entry or
  group in two groups, in a group and in a system, or a system or group that holds a group that the
  merged state does not have). Nothing of them is taken.
- `merged`: the systems and groups that both changed only in their members (and sources), which is
  no conflict: their members and sources merged as sets of keys of entries and groups,
  `key => (; members, sources)`, each `(mine ∪ (theirs − base)) − (base − theirs)`, e.g. both added
  a lens to `S1`; the `sources` of a group are empty.
- `renames`: the entries, systems and groups of `take` that `theirs` added or renamed to a readable
  id that another one of `mine` has already, by key, with the next free id of the same prefix;
  the caller adds them under that id, and the systems refer to them by it.
- `mine`, `theirs`: the changes of each since `base`, see [`diff_projects`](@ref); `rebuild` names
  the entries of `theirs` that count as rebuilt (e.g. since the own code that they call changed).
"""
function merge_plan(base::Project, mine::Project, theirs::Project; stale = key -> false,
        rebuild = Symbol[], keep = String[])
    d = diff_projects(base, theirs; rebuild)
    g = diff_projects(base, mine)
    theirs_keys = Set{String}(_change_key(c) for c in Iterators.flatten((d.entries, d.systems, d.groups))
                              if _real_change(base, theirs, c))
    mine_keys = Set{String}(_change_key(c) for c in Iterators.flatten((g.entries, g.systems, g.groups))
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
    # A source in two systems, an entry in two groups, or one in a group and in a system: all are
    # conflicts (each round sets back systems and groups to the state of mine)
    while true
        shared = setdiff(union(_shared_sources(base, mine, theirs, take, merged),
            _tree_conflicts(base, mine, theirs, take, merged)), conflicts)
        isempty(shared) && break
        append!(conflicts, sort!(collect(shared)))
        foreach(k -> delete!(merged, k), shared)
        take = setdiff(theirs_keys, conflicts, keys(merged))
    end
    added = Dict{String, Any}(_change_key(c) => c.new for c in Iterators.flatten((d.entries, d.systems, d.groups))
                              if c.kind in (:added, :renamed) && _change_key(c) in take)
    renames = _renumbered(base, mine, theirs, sort!(collect(added); by = first))
    return (; take, conflicts, merged, renames, mine = g, theirs = d)
end

#=
Composing a state from two
=#

"""
The project `mine` with the entries, systems and groups of `theirs` for the keys of `plan`
(`take`, `merged`, `renames` as of [`merge_plan`](@ref) of `base`, `mine` and `theirs`), see
`_apply_plan!`; `mine` stays as it is. The result has the folder, name, module and stamp of `mine`,
so that [`save_project`](@ref) of it throws `ProjectChanged` if the files changed since `mine` was
loaded. Returns it and the keys of its entries, systems and groups, `(project, done)`.
"""
function _compose(base::Project, mine::Project, theirs::Project, plan)
    p = Project(mine.path, mine.name, copy(mine.entries), copy(mine.systems), copy(mine.groups),
        mine.mod, mine.stamp)
    done = _apply_plan!(p, base, theirs, plan)
    return p, done
end

"""
The entries, systems and groups of `theirs` with keys in `take` whose readable id an entry, system
or group of `mine` has that is not in `take` (it stays): `(key, entry or system or group)`, sorted
by key, for `_renumbered`.
"""
function _clashes(base::Project, mine::Project, theirs::Project, take)
    km, kt = _base_keys(base, mine), _base_keys(base, theirs)
    out = Tuple{String, Any}[]
    for x in Iterators.flatten((theirs.entries, theirs.systems, theirs.groups))
        k = kt[x.name]
        k in take || continue
        other = get(km, x.name, k)
        other == k || other in take || push!(out, (k, x))
    end
    return sort!(out; by = first)
end

"""
    compose(base, mine, theirs, keys) -> (; project, keys)

The state of the project `mine` with that of `theirs` at the keys `keys` (both changed from the
common state `base`): the entries, systems and groups of `theirs` for those keys (also removed:
what `theirs` does not have), those of `mine` elsewhere. `mine` stays as it is. Keys are those of
[`merge_plan`](@ref): the machine id, or `"id:L1"` for a line without one; the key of a line is the
same in all three states. Systems and groups refer to their members by key, so a system of `mine`
holds an entry of `theirs` and a group of `theirs` holds the entries of `mine`; members that are
gone are left out.

The keys are widened where the result would break a rule otherwise: a system of `mine` that would
hold a source that a system of `theirs` at `keys` holds (a source belongs to at most one system),
and a system or group that would break the tree of groups (an entry or a group in two groups, or in
a group and in a system, or a group that the result does not have), get the state of `theirs` too,
until no rule is broken. An entry, system or group of `theirs` whose readable id one of `mine` that
stays has gets the next free id of its prefix.

Returns the result and the widened keys, sorted. The result has the folder, the name and the
stamp of `mine`: [`save_project`](@ref) of it throws `ProjectChanged` if the files changed since
`mine` was loaded.

E.g. a window with an open conflict at `L1` saves its state everywhere else, and the files keep
theirs at `L1`:

```julia
r = compose(base, window, files, ["l1-uid"])
save_project(r.project)
```
"""
function compose(base::Project, mine::Project, theirs::Project, keys)
    take = Set{String}(String(k) for k in keys)
    merged = Dict{String, @NamedTuple{members::Set{String}, sources::Set{String}}}()
    while true
        bad = union(_shared_sources(base, mine, theirs, take, merged),
            _tree_conflicts(base, mine, theirs, take, merged))
        wider = setdiff(bad, take)
        isempty(wider) && break
        union!(take, wider)
    end
    renames = _renumbered(base, mine, theirs, _clashes(base, mine, theirs, take))
    project, _ = _compose(base, mine, theirs, (; take, merged, renames))
    return (; project, keys = sort!(collect(take)))
end
