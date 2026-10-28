#=
Teams: an orchestrator and its workers (people or agents alike) work in a draft of the project,
a copy under `.bmo/drafts/<team>/` with the state it was forked from (`base/`), and talk over a
board of one file per entry. A draft is for variants; a team works in the live project otherwise.
Claims keep two workers off the same lines, in a draft as in the live project (`claim!` with the
folder of the draft, see `Claims.jl`). The participant who has the say over the project merges the
draft into it (`merge_draft!`, on top of `merge_plan` and `_compose`). Every file is written
atomically or created exclusively, also on a shared drive.
=#

# The files of a project that a draft copies (and its `base/`), besides `src/`
const _TEAM_FILES = ("system.jl", "Project.toml")
# How often `wait_for` looks at the board [s]
const _BOARD_POLL = 0.5

_drafts_dir(dir) = joinpath(project_dir(dir), ".bmo", "drafts")

# A part of a file name: anything but letters, digits and `_.@-` becomes `_`
_file_part(s) = replace(String(s), r"[^A-Za-z0-9_.@\-]" => "_")

_exists_error(e) = e isa Base.IOError && e.code == Base.UV_EEXIST

# Copies the files of the project in `from` that define the setup into the folder `to`
function _copy_setup(from, to)
    mkpath(to)
    for f in _TEAM_FILES
        isfile(joinpath(from, f)) && cp(joinpath(from, f), joinpath(to, f))
    end
    isdir(joinpath(from, "src")) && cp(joinpath(from, "src"), joinpath(to, "src"))
    return to
end

"""
    fork_team(dir, name; by, goal = "") -> String

Forks a draft of the team `name` from the project in the folder `dir` and returns the folder of the
draft, `<dir>/.bmo/drafts/<name>/`. It holds copies of `system.jl`, `src/` and `Project.toml`
(it loads as a project, see [`load_project`](@ref), but has no versions), the same three in `base/`
(the state it was forked from, against which [`merge_draft!`](@ref) finds the changes of the team),
`team.toml` (`by`, the participant who forked it, `created`, UTC, and `goal`), and the folders
`board/` (see [`post!`](@ref)) and `claims/` (see [`claim!`](@ref)).

`name` may contain letters, digits and `_.@-`. Throws an `ArgumentError` if a team of that name
exists: of two participants that fork the same name at the same time, exactly one gets the draft
(the folder is created with `mkdir`). See [`teams`](@ref).
"""
function fork_team(dir::AbstractString, name::AbstractString; by::AbstractString,
        goal::AbstractString = "")
    dir = project_dir(dir)
    (occursin(r"^[A-Za-z0-9_.@\-]+$", name) && !(name in (".", ".."))) ||
        throw(ArgumentError("a team name may contain letters, digits and _.@-, got \"$name\""))
    isfile(joinpath(dir, "system.jl")) || throw(ArgumentError("no system.jl in \"$dir\""))
    root = _drafts_dir(dir)
    mkpath(root)
    draft = joinpath(root, name)
    try
        mkdir(draft)
    catch e
        _exists_error(e) || rethrow()
        throw(ArgumentError("the team \"$name\" exists already in \"$root\""))
    end
    # One copy of the project, so that the draft and its base are the same state even if the
    # project is saved meanwhile
    snapshot = mktempdir()
    try
        _copy_setup(dir, joinpath(snapshot, "setup"))
        _copy_setup(joinpath(snapshot, "setup"), draft)
        _copy_setup(joinpath(snapshot, "setup"), joinpath(draft, "base"))
    finally
        rm(snapshot; recursive = true, force = true)
    end
    mkpath(joinpath(draft, "board"))
    mkpath(joinpath(draft, "claims"))
    # Last: a draft with `team.toml` is complete
    team = Dict{String, Any}("by" => String(by), "created" => unix2datetime(time()),
        "goal" => String(goal))
    _write_atomic(joinpath(draft, "team.toml"), sprint(TOML.print, team))
    return draft
end

"""
    teams(dir) -> Vector{String}

The names of the teams of the project in the folder `dir` (the drafts under `.bmo/drafts/` that
were forked completely, see [`fork_team`](@ref)), sorted.
"""
function teams(dir::AbstractString)
    root = _drafts_dir(dir)
    isdir(root) || return String[]
    return sort!(String[d for d in readdir(root) if isfile(joinpath(root, d, "team.toml"))])
end

#=
The board
=#

"""
    post!(draft; by, kind, text = "", data = Dict()) -> Int

Posts an entry on the board of the team draft `draft` (a folder of [`fork_team`](@ref)) and returns
its number. The entry is the file `board/<n>-<by>-<kind>.toml` with `by` (the participant), `kind`
(e.g. `:task`, `:data`, `:done`), `text`, `time` (UTC) and the table `data`; values that TOML does
not know (e.g. symbols) are written as strings. Entries are numbered 1, 2, … in the order they are
posted, also by several processes: each number is taken with `mkdir` of `board/.seq/<n>/`, then
the file is written atomically. See [`board`](@ref), [`wait_for`](@ref).
"""
function post!(draft::AbstractString; by, kind::Symbol, text = "", data = Dict{String, Any}())
    dir = joinpath(abspath(draft), "board")
    seq = joinpath(dir, ".seq")
    mkpath(seq)
    entry = Dict{String, Any}("by" => String(by), "kind" => String(kind), "text" => String(text),
        "time" => unix2datetime(time()),
        "data" => Dict{String, Any}(string(k) => v for (k, v) in data))
    body = sprint((io, d) -> TOML.print(x -> x isa Symbol ? String(x) : string(x), io, d), entry)
    n = length(readdir(seq)) + 1
    while true
        try
            mkdir(joinpath(seq, string(n)))
            break
        catch e
            _exists_error(e) || rethrow()
            n += 1
        end
    end
    _write_atomic(joinpath(dir, string(n, "-", _file_part(by), "-", _file_part(kind), ".toml")), body)
    return n
end

"""
    board(draft) -> Vector{Dict{String, Any}}

The entries on the board of the team draft `draft` in the order they were posted, each with `n`
(its number), `by`, `kind` (a string), `text`, `time` and `data`, see [`post!`](@ref). A file that
does not parse is left out.
"""
board(draft::AbstractString) = _board(draft).entries

# The entries of the board of `draft` (see `board`) and the numbers that have a file, also one that
# does not parse
function _board(draft)
    dir = joinpath(abspath(draft), "board")
    out = Dict{String, Any}[]
    numbers = Set{Int}()
    isdir(dir) || return (; entries = out, numbers)
    for f in readdir(dir)
        m = match(r"^(\d+)-.*\.toml$", f)
        isnothing(m) && continue
        n = parse(Int, m.captures[1])
        push!(numbers, n)
        entry = try
            TOML.parsefile(joinpath(dir, f))
        catch e
            e isa InterruptException && rethrow()
            continue
        end
        entry["n"] = n
        push!(out, entry)
    end
    return (; entries = sort!(out; by = e -> e["n"]), numbers)
end

"""
    wait_for(draft; kind, after = 0, timeout = 60) -> Union{Nothing, Dict{String, Any}}

The first entry of the `kind` (e.g. `:done`) on the board of the team draft `draft` whose number is
larger than `after`, see [`board`](@ref). Only the entries `after + 1`, `after + 2`, … up to the
first number that is not on the board yet count: a number is taken before its entry is written
(see [`post!`](@ref)), so a later entry may appear first, and waiting on with `after` the number
of the returned entry never skips one. Looks every 0.5 s until there is one; `nothing` after
`timeout` seconds.
"""
function wait_for(draft::AbstractString; kind::Symbol, after::Int = 0, timeout::Real = 60)
    k = String(kind)
    stop = time() + timeout
    while true
        b = _board(draft)
        n = after + 1
        while n in b.numbers
            i = findfirst(e -> e["n"] == n, b.entries)
            !isnothing(i) && get(b.entries[i], "kind", "") == k && return b.entries[i]
            n += 1
        end
        left = stop - time()
        left <= 0 && return nothing
        sleep(min(_BOARD_POLL, left))
    end
end

#=
Merging a draft
=#

"""
The keys of the entries (or systems) `xs` of a project that changed from `base_xs`, as
[`diff_projects`](@ref) names their changes: the key of the paired one of `base_xs`, else their own.
"""
function _team_keys(base_xs, xs)
    m = match_entries(base_xs, xs)
    keys = String[_merge_key(x) for x in xs]
    for (old, new) in m.pairs
        keys[findfirst(x -> x === new, xs)] = _merge_key(old)
    end
    return keys
end

# The keys of the readable ids `names` of the project `p`, whose entries have the keys `keys` and
# whose groups have the keys `gkeys`
function _names_to_keys(p, keys, names, gkeys = String[])
    out = String[]
    for n in names
        i = findfirst(e -> e.name === n, p.entries)
        if !isnothing(i)
            push!(out, keys[i])
            continue
        end
        j = findfirst(g -> g.name === n, p.groups)
        isnothing(j) || j > length(gkeys) || push!(out, gkeys[j])
    end
    return out
end

# An entry, a system or a group under another readable id
_with_name(e::Entry, name) = Entry(e.kind, name, e.code, e.object, e.pos, e.rot, e.pose0, e.meta,
    e.label, e.uid)
_with_name(s::SystemEntry, name) = SystemEntry(name, s.members, s.sources, s.static, s.object,
    s.label, s.uid)
_with_name(g::GroupEntry, name) = GroupEntry(name, g.members, g.pos, g.rot, g.object, g.label, g.uid)

"""
Makes the project `live` as `draft` for the keys of `plan` (see [`merge_plan`](@ref) of `base`,
`live` and `draft`): takes the entries, systems and groups of `take` from `draft` (removed, added or
changed, under the id of `renames`), the members and sources of the systems and groups of `merged`,
and refers to the entries and groups by their final readable ids. Members that are gone are left
out. Returns the keys of the entries, systems and groups of `live` afterwards,
`(; entries, systems, groups)`.
"""
function _apply_plan!(live::Project, base::Project, draft::Project, plan)
    take = plan.take
    dkeys = _team_keys(base.entries, draft.entries)
    lkeys = _team_keys(base.entries, live.entries)
    dgkeys = _team_keys(base.groups, draft.groups)
    lgkeys = _team_keys(base.groups, live.groups)
    # (key, own key of the entry in its file, entry): a system may name it by either
    ents = Tuple{String, String, Entry}[(lkeys[i], _merge_key(e), e) for (i, e) in enumerate(live.entries)]
    for k in take
        i = findfirst(x -> x[1] == k, ents)
        j = findfirst(==(k), dkeys)
        isnothing(i) && isnothing(j) && continue
        if isnothing(j)
            deleteat!(ents, i)
            continue
        end
        e = draft.entries[j]
        new = _with_name(e, get(plan.renames, k, e.name))
        isnothing(i) ? push!(ents, (k, _merge_key(e), new)) : (ents[i] = (k, _merge_key(e), new))
    end
    # The systems with their keys and the keys of their members and sources
    dskeys = _team_keys(base.systems, draft.systems)
    lskeys = _team_keys(base.systems, live.systems)
    syss = Tuple{String, SystemEntry, Vector{String}, Vector{String}}[]
    # The keys of `set` in the order of the `lists`, the others after them
    order(set, lists...) = (seen = unique(vcat(lists...));
                            vcat(filter(in(set), seen), setdiff(collect(set), seen)))
    from_draft(k, ds) = (k, _with_name(ds, get(plan.renames, k, ds.name)),
        _names_to_keys(draft, dkeys, ds.members, dgkeys), _names_to_keys(draft, dkeys, ds.sources))
    for (i, s) in enumerate(live.systems)
        k = lskeys[i]
        lm, ls = _names_to_keys(live, lkeys, s.members, lgkeys), _names_to_keys(live, lkeys, s.sources)
        j = findfirst(==(k), dskeys)
        if haskey(plan.merged, k)
            m = plan.merged[k]
            _, _, dm, dsrc = isnothing(j) ? (k, s, String[], String[]) : from_draft(k, draft.systems[j])
            push!(syss, (k, s, order(m.members, lm, dm), order(m.sources, ls, dsrc)))
        elseif k in take
            isnothing(j) || push!(syss, from_draft(k, draft.systems[j]))
        else
            push!(syss, (k, s, lm, ls))
        end
    end
    for (j, ds) in enumerate(draft.systems)
        k = dskeys[j]
        k in take && !(k in lskeys) && push!(syss, from_draft(k, ds))
    end
    # The groups with their keys, the own key of the group in its file and the keys of their members
    grps = Tuple{String, String, GroupEntry, Vector{String}}[]
    group_from_draft(k, dg) = (k, _merge_key(dg), _with_name(dg, get(plan.renames, k, dg.name)),
        _names_to_keys(draft, dkeys, dg.members, dgkeys))
    for (i, g) in enumerate(live.groups)
        k = lgkeys[i]
        lm = _names_to_keys(live, lkeys, g.members, lgkeys)
        j = findfirst(==(k), dgkeys)
        if haskey(plan.merged, k)
            dm = isnothing(j) ? String[] : last(group_from_draft(k, draft.groups[j]))
            push!(grps, (k, _merge_key(g), g, order(plan.merged[k].members, lm, dm)))
        elseif k in take
            isnothing(j) || push!(grps, group_from_draft(k, draft.groups[j]))
        else
            push!(grps, (k, _merge_key(g), g, lm))
        end
    end
    for (j, dg) in enumerate(draft.groups)
        k = dgkeys[j]
        k in take && !(k in lgkeys) && push!(grps, group_from_draft(k, dg))
    end
    function id_of(key)
        i = something(findfirst(x -> x[1] == key, ents), findfirst(x -> x[2] == key, ents), 0)
        i == 0 || return ents[i][3].name
        j = something(findfirst(x -> x[1] == key, grps), findfirst(x -> x[2] == key, grps), 0)
        return j == 0 ? nothing : grps[j][3].name
    end
    ids(keys) = Symbol[n for n in map(id_of, keys) if !isnothing(n)]
    live.entries = Entry[x[3] for x in ents]
    live.systems = SystemEntry[SystemEntry(s.name, ids(m), ids(src), s.static, nothing, s.label, s.uid)
                               for (_, s, m, src) in syss]
    live.groups = GroupEntry[GroupEntry(g.name, ids(m), g.pos, g.rot, nothing, g.label, g.uid)
                             for (_, _, g, m) in grps]
    return (; entries = String[x[1] for x in ents], systems = String[x[1] for x in syss],
        groups = String[x[1] for x in grps])
end

"""
Gives the entries, systems and groups of the project `p` (a state that changed from `base`) the
readable ids of `renames` (key => id, see [`merge_plan`](@ref)), also where its systems and groups
name them.
"""
function _rename!(p::Project, base::Project, renames)
    ekeys = _team_keys(base.entries, p.entries)
    skeys = _team_keys(base.systems, p.systems)
    gkeys = _team_keys(base.groups, p.groups)
    new = Dict{Symbol, Symbol}()
    for (xs, keys) in ((p.entries, ekeys), (p.groups, gkeys)), (i, x) in enumerate(xs)
        id = get(renames, keys[i], nothing)
        isnothing(id) && continue
        new[x.name] = id
        xs[i] = _with_name(x, id)
    end
    ref(n) = get(new, n, n)
    for (i, s) in enumerate(p.systems)
        p.systems[i] = SystemEntry(get(renames, skeys[i], s.name), map(ref, s.members),
            map(ref, s.sources), s.static, s.object, s.label, s.uid)
    end
    for (i, g) in enumerate(p.groups)
        p.groups[i] = GroupEntry(g.name, map(ref, g.members), g.pos, g.rot, g.object, g.label, g.uid)
    end
    return p
end

# The own code of the project in the folder `dir`: the content of each file in `src/` (without
# hidden and temporary files) by its path there, with `/`
function _code_files(dir)
    files = Dict{String, Vector{UInt8}}()
    src = joinpath(dir, "src")
    isdir(src) || return files
    for (root, dirs, names) in walkdir(src)
        filter!(d -> !startswith(d, '.'), dirs)
        for f in names
            (startswith(f, '.') || endswith(f, ".tmp")) && continue
            path = joinpath(root, f)
            files[replace(relpath(path, src), '\\' => '/')] = read(path)
        end
    end
    return files
end

"""
The files of the own code that the draft in the folder `draft` changed since its base `base`, as
the project in the folder `live` has them: `take` those that the project did not change meanwhile
(path => the draft's content, `nothing` if the draft removed it), `same` those that both changed
alike (the same), `conflicts` those that both changed differently.
"""
function _code_plan(base, live, draft)
    b, l, d = _code_files(base), _code_files(live), _code_files(draft)
    take = Dict{String, Union{Nothing, Vector{UInt8}}}()
    same = Dict{String, Union{Nothing, Vector{UInt8}}}()
    conflicts = String[]
    for f in union(keys(b), keys(d))
        bf, lf, df = get(b, f, nothing), get(l, f, nothing), get(d, f, nothing)
        isequal(df, bf) && continue
        if isequal(lf, df)
            same[f] = df
        elseif isequal(lf, bf)
            take[f] = df
        else
            push!(conflicts, f)
        end
    end
    return (; take, same, conflicts)
end

# Writes the files of own code `files` (path in `src/` => content, `nothing`: removed) into the
# project in the folder `dir`
function _write_code(dir, files)
    for (f, content) in files
        path = joinpath(dir, "src", f)
        if isnothing(content)
            rm(path; force = true)
        else
            mkpath(dirname(path))
            _write_atomic(path, content)
        end
    end
    return nothing
end

# An entry, a system or a group with the machine id `uid`
_with_uid(e::Entry, uid) = Entry(e.kind, e.name, e.code, e.object, e.pos, e.rot, e.pose0, e.meta,
    e.label, uid)
_with_uid(s::SystemEntry, uid) = SystemEntry(s.name, s.members, s.sources, s.static, s.object,
    s.label, uid)
_with_uid(g::GroupEntry, uid) = GroupEntry(g.name, g.members, g.pos, g.rot, g.object, g.label, uid)

"""
Gives the team draft in the folder `draft` (the state `theirs`, unless it was written since) the
readable ids of `plan.renames` and, to the entries and systems that the merge took or merged and
that have no machine id there, the one that the project `live` gave them when it was saved (`done`
are the keys of `live`, see `_apply_plan!`), so that the next merge pairs them with the project and
the `base/` of the draft. Writes `system.jl` of the draft only if that changes it.
"""
function _rebase_draft!(draft, base::Project, live::Project, theirs::Project, plan, done)
    d = project_stamp(draft) == theirs.stamp ? theirs : load_project(draft)
    uids = Dict{String, String}()
    for (keys, xs) in ((done.entries, live.entries), (done.systems, live.systems), (done.groups, live.groups))
        for (k, x) in zip(keys, xs)
            (k in plan.take || haskey(plan.merged, k)) && !isnothing(x.uid) && (uids[k] = x.uid)
        end
    end
    # The keys before renaming, by which `plan` and `done` name them
    ekeys, skeys = _team_keys(base.entries, d.entries), _team_keys(base.systems, d.systems)
    gkeys = _team_keys(base.groups, d.groups)
    # A copy: `theirs` stays the state that was merged
    d = Project(d.path, d.name; entries = copy(d.entries), systems = copy(d.systems), groups = copy(d.groups))
    _rename!(d, base, plan.renames)
    for (xs, keys) in ((d.entries, ekeys), (d.systems, skeys), (d.groups, gkeys)), i in eachindex(xs)
        x = xs[i]
        isnothing(x.uid) && haskey(uids, keys[i]) && (xs[i] = _with_uid(x, uids[keys[i]]))
    end
    file = joinpath(draft, "system.jl")
    text = system_code(d)
    text == read(file, String) || _write_atomic(file, text)
    return nothing
end

"""
Rebases the team draft in the folder `draft` after a merge of `plan` and `code` (see
[`merge_draft!`](@ref)): the draft gets the readable ids of `plan.renames` and the machine ids that
the project gave the lines it took from the draft (see `_rebase_draft!`), and its `base/` the
state that the project `live` and the draft agree on now (the entries and systems of `live` for
the keys of `plan.take`, whose keys are `done`, the draft's systems of `plan.merged`, the files of
own code taken or changed alike), the old `base` elsewhere. So a change of the project that the
draft does not have stays a change of the project, a conflict stays one, and the next merge takes
only what the draft changes afterwards.
"""
function _rebase!(draft, base::Project, live::Project, theirs::Project, plan, done, code)
    _rebase_draft!(draft, base, live, theirs, plan, done)
    bkeys = String[_merge_key(e) for e in base.entries]
    ents = Tuple{String, Entry}[(k, e) for (k, e) in zip(bkeys, base.entries)]
    for (k, e) in zip(done.entries, live.entries)
        k in plan.take || continue
        i = findfirst(x -> x[1] == k, ents)
        isnothing(i) ? push!(ents, (k, e)) : (ents[i] = (k, e))
    end
    filter!(x -> !(x[1] in plan.take) || x[1] in done.entries, ents)
    bgkeys = String[_merge_key(g) for g in base.groups]
    # The systems with their keys and the keys of their members and sources
    syss = Tuple{String, SystemEntry, Vector{String}, Vector{String}}[
        (_merge_key(s), s, _names_to_keys(base, bkeys, s.members, bgkeys), _names_to_keys(base, bkeys, s.sources))
        for s in base.systems]
    function set!(k, s, members, sources)
        i = findfirst(x -> x[1] == k, syss)
        isnothing(i) ? push!(syss, (k, s, members, sources)) : (syss[i] = (k, s, members, sources))
    end
    for (k, s) in zip(done.systems, live.systems)
        k in plan.take || continue
        set!(k, s, _names_to_keys(live, done.entries, s.members, done.groups),
            _names_to_keys(live, done.entries, s.sources))
    end
    filter!(x -> !(x[1] in plan.take) || x[1] in done.systems, syss)
    dkeys = _team_keys(base.entries, theirs.entries)
    dgkeys = _team_keys(base.groups, theirs.groups)
    for (k, s) in zip(_team_keys(base.systems, theirs.systems), theirs.systems)
        haskey(plan.merged, k) || continue
        set!(k, s, _names_to_keys(theirs, dkeys, s.members, dgkeys), _names_to_keys(theirs, dkeys, s.sources))
    end
    # The groups likewise, with the keys of their members
    grps = Tuple{String, GroupEntry, Vector{String}}[
        (k, g, _names_to_keys(base, bkeys, g.members, bgkeys)) for (k, g) in zip(bgkeys, base.groups)]
    function gset!(k, g, members)
        i = findfirst(x -> x[1] == k, grps)
        isnothing(i) ? push!(grps, (k, g, members)) : (grps[i] = (k, g, members))
    end
    for (k, g) in zip(done.groups, live.groups)
        k in plan.take || continue
        gset!(k, g, _names_to_keys(live, done.entries, g.members, done.groups))
    end
    filter!(x -> !(x[1] in plan.take) || x[1] in done.groups, grps)
    for (k, g) in zip(dgkeys, theirs.groups)
        haskey(plan.merged, k) || continue
        gset!(k, g, _names_to_keys(theirs, dkeys, g.members, dgkeys))
    end
    function ids(keys)
        names = Symbol[]
        for k in keys
            i = findfirst(x -> x[1] == k, ents)
            if !isnothing(i)
                push!(names, ents[i][2].name)
                continue
            end
            j = findfirst(x -> x[1] == k, grps)
            isnothing(j) || push!(names, grps[j][2].name)
        end
        return names
    end
    p = Project(joinpath(draft, "base"), live.name; entries = Entry[e for (_, e) in ents],
        systems = SystemEntry[SystemEntry(s.name, ids(m), ids(src), s.static, nothing, s.label, s.uid)
                              for (_, s, m, src) in syss],
        groups = GroupEntry[GroupEntry(g.name, ids(m), g.pos, g.rot, nothing, g.label, g.uid)
                            for (_, g, m) in grps])
    _write_atomic(joinpath(draft, "base", "system.jl"), system_code(p))
    _write_code(joinpath(draft, "base"), merge(code.take, code.same))
    return nothing
end

"""
    merge_draft!(dir, name) -> (; taken::Vector{String}, conflicts::Vector{String})

Merges the draft of the team `name` (see [`fork_team`](@ref)) into the project in the folder `dir`:
the changes of the draft since its `base/` that the project did not change differently meanwhile
(see [`merge_plan`](@ref)) are written into `system.jl` of the project (see [`save_project`](@ref)),
and the files of the draft's own code (`src/`) that the project did not change since `base/` are
copied into it. The project then gets the version `"Team <name>: <summary>"` (see
[`save_version`](@ref)), whose summary names only what the merge changed. Systems that both changed
only in their members get the members of both; an entry or a system that the draft added or
renamed with a readable id that the project has already gets the next free one, also in the draft.
Returns the keys of the entries and systems that were taken (machine ids, `"id:L1"` for a line
without one, `"src/<file>"` for a file of own code), and those of the conflicts, sorted; the
conflicts are not written, the project keeps its state there.

Afterwards the draft's `base/` is the state that the project and the draft agree on, so the draft
can be merged again: a later merge takes what the team changed since, and a conflict stays one
until both agree. Meant to be called by the participant who has the say over the project. The
draft stays; delete its folder when the team is done.
"""
function merge_draft!(dir::AbstractString, name::AbstractString)
    dir = project_dir(dir)
    draft = joinpath(_drafts_dir(dir), name)
    isfile(joinpath(draft, "team.toml")) || throw(ArgumentError("no team \"$name\" in \"$dir\""))
    live = load_project(dir)
    base = load_project(joinpath(draft, "base"))
    theirs = load_project(draft)
    plan = merge_plan(base, live, theirs)
    code = _code_plan(joinpath(draft, "base"), dir, draft)
    # What the project has already is not taken again
    changed = String[k for k in union(plan.take, keys(plan.merged)) if !_same_state(base, live, theirs, k)]
    taken = sort!(vcat(changed, String["src/" * f for f in keys(code.take)]))
    conflicts = sort!(vcat(String[plan.conflicts...], String["src/" * f for f in code.conflicts]))
    isempty(taken) && return (; taken, conflicts)
    merged, done = _compose(base, live, theirs, plan)
    parts = String[]
    if !isempty(changed)
        file = joinpath(dir, "system.jl")
        before = read(file, String)
        save_project(merged)
        append!(parts, _system_changes(before, read(file, String)))
    end
    _write_code(dir, code.take)
    isempty(code.take) || push!(parts, "own code changed")
    save_version(dir; message = isempty(parts) ? "Team $name" : "Team $name: " * join(parts, "; "))
    _rebase!(draft, base, merged, theirs, plan, done, code)
    return (; taken, conflicts)
end
