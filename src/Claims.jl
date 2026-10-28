#=
Claims: the participant who changes an object holds its claim, and the others do not change it
meanwhile. A claim is a file of its own, created exclusively (the one atomic step of a shared
drive), named by the machine id of the line; it is alive while its holder's presence is
=#

# A claim of a holder without a presence file (e.g. an agent that never announced) counts that
# long after its file was written [s]
const _CLAIM_GRACE = 120.0
# A claim file that can not be read (of a writer that died while it created it without hard links)
# is stale that long after it was written [s]
const _CLAIM_UNREADABLE = 5.0

"""
The folder of the claims of the project or team draft in the folder `dir`: `claims/` of a draft
(see [`fork_team`](@ref)), else `.bmo/claims/` of the project.
"""
_claims_dir(dir) = isfile(joinpath(dir, "team.toml")) ? joinpath(dir, "claims") : joinpath(dir, ".bmo", "claims")

# The project folder whose presence files tell whether the holders of the claims in `dir` are
# there: the project of a draft (`<project>/.bmo/drafts/<team>`), else `dir`
_presence_dir(dir) = isfile(joinpath(dir, "team.toml")) ? dirname(dirname(dirname(dir))) : dir

# The participant id of `by`: as given if it has a host (`"anna@pc2"`), else an agent (`"w1@agent"`,
# see `announce`); characters outside `[A-Za-z0-9_.@-]` replaced by `_`, as in the names of the
# presence files
_holder_id(by) = occursin('@', by) ? _file_part(by) : _participant_id(String(by), "agent")

# The machine ids of the lines of `system.jl` in the folder `dir` by their readable id, read from
# the text without running it
function _line_uids(dir)
    file = joinpath(dir, "system.jl")
    lines = isfile(file) ? _parse_lines(read(file, String)) : nothing
    uid = Dict{Symbol, String}()
    isnothing(lines) || foreach(l -> isnothing(l.uid) || (uid[l.name] = l.uid), lines[1])
    return uid
end

"""
The keys (the machine id, else `"id:L1"`) of the readable ids `ids` in `system.jl` of the folder
`dir`, read from the text without running it; an id that is not a line there keeps `"id:<id>"`.
"""
_claim_keys(dir, ids) = _uid_keys(ids, _line_uids(dir))
_uid_keys(ids, uids) =
    Dict{Symbol, String}(id => get(uids, id, "id:" * String(id)) for id in ids)

# The key of the line that the claim key `key` stands for now: a claim `"id:L5"`, made while L5 had
# no machine id, is one of the line L5 of the file (its machine ids `uids`, see `_line_uids`) once
# that line has one
_claim_key(key, uids) = startswith(key, "id:") ? get(uids, Symbol(key[4:end]), key) : key

_claim_file(cdir, key) = joinpath(cdir, _file_part(key) * ".toml")

# The holder and readable id of the claim file `file`, `nothing` while it is unreadable
function _claim_read(file)
    try
        d = TOML.parsefile(file)
        by = get(d, "by", nothing)
        by isa AbstractString || return nothing
        return (; by = String(by), id = Symbol(get(d, "id", "")), key = String(get(d, "key", "")))
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

# The holder of the claim file `file`, `nothing` while it is unreadable
_claim_by(file) = (c = _claim_read(file); isnothing(c) ? nothing : c.by)

"""
Whether the claim file `file` of the holder `by` is alive: its holder's presence file in the project
folder `pdir` was written within its `ttl`, or, without a presence file, the claim was written
within `_CLAIM_GRACE`. The times of the files are compared with the clock of this machine, which
assumes clocks of the machines that agree within a few seconds (one Windows domain).
"""
function _claim_alive(pdir, file, by)
    now = time()
    pres = presence_file(pdir, _holder_id(by))
    if isfile(pres)
        ttl = try
            _presence_ttl(get(TOML.parsefile(pres), "ttl", nothing))
        catch
            _TTL_DEFAULT
        end
        return now - mtime(pres) < ttl
    end
    return now - mtime(file) < _CLAIM_GRACE
end

"""
Whether the claim file `file` is stale, with the presences in the project folder `pdir`: its
holder is gone (see `_claim_alive`), or it can not be read and was written more than
`_CLAIM_UNREADABLE` seconds ago (by a writer that died while it created the file).
"""
function _claim_stale(pdir, file)
    isfile(file) || return false
    c = _claim_read(file)
    isnothing(c) && return time() - mtime(file) > _CLAIM_UNREADABLE
    return !_claim_alive(pdir, file, c.by)
end

# Whether the claim file `file` exists and is of a holder other than `by` who is there
function _held_by_other(pdir, file, by)
    isfile(file) || return false
    c = _claim_read(file)
    return !isnothing(c) && c.by != by && _claim_alive(pdir, file, c.by)
end

# Writes the time of the existing file `file` anew (never creates it); `false` if it is gone
function _touch_existing(file)
    F = Base.Filesystem
    f = try
        F.open(file, F.JL_O_WRONLY)
    catch e
        e isa Base.IOError || rethrow()
        return false
    end
    try
        t = time()
        F.futime(f, t, t)
    finally
        close(f)
    end
    return true
end

"""
    claim!(dir; by, ids, refresh = true) -> Bool

Claims the objects of the readable ids `ids` (e.g. `[:L1, :M2]`, the lines that the participant
`by` is going to change) in the project or team draft in the folder `dir`: `true` if all of them
are claimed by `by` now (also those it held already), `false` if one is claimed by another
participant who is still there; then none of `ids` is claimed by this call.

A claim is the file `.bmo/claims/<key>.toml` of the project (`claims/` of a draft) with `by`, the
readable id and the machine id of the line (`key`), so it keeps its object when the line is
renamed. Of two participants that claim the same object at the same time exactly one gets it; the
objects are claimed in sorted order, so this also holds for overlapping `ids`. A claim lives as
long as its holder's presence (see [`announce`](@ref)): one of a participant who is gone is taken
over. `by` is the participant id of the presence (`"anna@pc2"`) or the `name` an agent announced
with (`"w1"`); with `refresh`, a claim also writes the presence file of `by` again (a window, which
writes its presence itself, passes `false`). Windows of people refuse to change an object claimed
by someone else, and [`save_project`](@ref) with `by` refuses to write its line.
See [`release!`](@ref), [`claims`](@ref).
"""
function claim!(dir::AbstractString; by, ids::Vector{Symbol}, refresh::Bool = true)
    dir = abspath(dir)
    cdir = _claims_dir(dir)
    pdir = _presence_dir(dir)
    mkpath(cdir)
    by = String(by)
    keys = _claim_keys(dir, ids)
    # The claims that this call made, taken back if one of the objects is held by another
    made = String[]
    # In one order for all, so that of two participants that claim overlapping objects one gets them
    for (key, id) in sort!(unique([(keys[id], id) for id in ids]))
        file = _claim_file(cdir, key)
        body = sprint(TOML.print, Dict("by" => by, "id" => String(id), "key" => key))
        taken = false
        for _ in 1:3
            if _create_exclusive(file, body)
                push!(made, file)
                taken = true
                break
            end
            c = _claim_read(file)
            if !isnothing(c) && c.by == by
                # Held already: refreshed, unless it went meanwhile
                _touch_existing(file) && (taken = true; break)
                continue
            end
            # Gone meanwhile: create it
            isfile(file) || continue
            # Held by another who is there, or being written: not ours
            _claim_stale(pdir, file) || break
            _take_away(file, f -> _claim_stale(pdir, f))
        end
        # A claim of the line by its readable id, made before the line had a machine id
        taken && !startswith(key, "id:") &&
            _held_by_other(pdir, _claim_file(cdir, "id:" * String(id)), by) && (taken = false)
        if !taken
            foreach(f -> _take_away(f, g -> _claim_by(g) == by), made)
            return false
        end
    end
    refresh && _refresh_presence(pdir, by)
    return true
end

# Writes the presence file of the holder `by` again, if it has one (its beat shows it is there)
function _refresh_presence(pdir, by)
    file = presence_file(pdir, _holder_id(by))
    isfile(file) || return nothing
    try
        data = TOML.parsefile(file)
        delete!(data, "beat")
        write_presence(pdir, _holder_id(by), data)
    catch e
        e isa InterruptException && rethrow()
    end
    return nothing
end

"""
    release!(dir; by, ids = nothing)

Releases the claims of the participant `by` in the project or team draft in the folder `dir`: all
of them, or those of the readable ids `ids`. See [`claim!`](@ref).
"""
function release!(dir::AbstractString; by, ids = nothing)
    dir = abspath(dir)
    cdir = _claims_dir(dir)
    isdir(cdir) || return nothing
    by = String(by)
    uids = isnothing(ids) ? nothing : _line_uids(dir)
    keys = isnothing(ids) ? nothing : Set(values(_uid_keys(collect(Symbol, ids), uids)))
    for f in readdir(cdir; join = true)
        endswith(f, ".toml") || continue
        c = _claim_read(f)
        (isnothing(c) || c.by != by) && continue
        (isnothing(keys) || c.key in keys || _claim_key(c.key, uids) in keys) || continue
        # Only if it is still this one: another may have taken it over meanwhile
        _take_away(f, g -> _claim_by(g) == by)
    end
    return nothing
end

"""
    claims(dir) -> Dict{String, @NamedTuple{by::String, id::Symbol}}

The claims of the project or team draft in the folder `dir` whose holders are still there, by the
machine id of their line (`"id:L1"` for a line without one): the participant `by` and the readable
id `id` at the time of the claim. A claim made while its line had no machine id counts for the
line of its readable id once that line has one. See [`claim!`](@ref).
"""
function claims(dir::AbstractString)
    dir = abspath(dir)
    cdir = _claims_dir(dir)
    pdir = _presence_dir(dir)
    out = Dict{String, @NamedTuple{by::String, id::Symbol}}()
    isdir(cdir) || return out
    # The claims by readable id, after those by machine id
    byid = Pair{String, @NamedTuple{by::String, id::Symbol}}[]
    uids = nothing
    for f in readdir(cdir; join = true)
        (endswith(f, ".toml") && !startswith(basename(f), ".")) || continue
        c = _claim_read(f)
        (isnothing(c) || isempty(c.key)) && continue
        _claim_alive(pdir, f, c.by) || continue
        if startswith(c.key, "id:")
            isnothing(uids) && (uids = _line_uids(dir))
            push!(byid, _claim_key(c.key, uids) => (by = c.by, id = c.id))
        else
            out[c.key] = (by = c.by, id = c.id)
        end
    end
    for (k, v) in byid
        haskey(out, k) || (out[k] = v)
    end
    return out
end

"""
The keys of the lines (entries, systems, groups) that the text `new` of `system.jl` changes, adds
or removes compared with the text `old`, by the machine id (`"id:L1"` without one). Lines are
compared by value: a line that `save_project` writes in its own way (`(0.1, 0.0, 0.0)` for
`(0.1, 0, 0)`, no `rot` for a rotation of zero) is not changed.
"""
function _changed_keys(old, new)
    a, b = _parse_lines(old), _parse_lines(new)
    (isnothing(a) || isnothing(b)) && return nothing
    key(l) = isnothing(l.uid) ? "id:" * String(l.name) : l.uid
    pairs, added, removed = _pair(a[1], b[1])
    out = Set{String}(key(l) for l in Iterators.flatten((added, removed)))
    for (o, n) in pairs
        _same_line(o, n) || push!(out, key(o))
    end
    return out
end

# Whether the lines `o` and `n` (see `_parse_lines`) are the same but for the machine id, the
# rotations within `_ROT_TOL`
function _same_line(o::_Line, n::_Line)
    (o.name == n.name && o.macroname == n.macroname && o.code == n.code && o.rest == n.rest) ||
        return false
    get(o.pose, :pos, nothing) == get(n.pose, :pos, nothing) || return false
    a, b = get(o.pose, :rot, nothing), get(n.pose, :rot, nothing)
    a == b && return true
    A, B = _rot_value(a), _rot_value(b)
    return !isnothing(A) && !isnothing(B) && maximum(abs, A - B) <= _ROT_TOL
end

# The rotation matrix of the text `s` of a `rot` (`nothing`: none), `nothing` if it is not written
# with numbers (angles or a matrix)
function _rot_value(s)
    isnothing(s) && return rotation_matrix(nothing)
    ex = Meta.parse(s; raise = false)
    ex isa Expr || return nothing
    if ex.head === :tuple
        t = map(_number_value, ex.args)
        (length(t) == 3 && !any(isnothing, t)) || return nothing
        return rotation_matrix(Tuple(Float64.(t)))
    elseif ex.head === :vcat && length(ex.args) == 3
        rows = map(ex.args) do r
            r isa Expr && r.head === :row || return nothing
            v = map(_number_value, r.args)
            (length(v) == 3 && !any(isnothing, v)) ? Float64.(v) : nothing
        end
        any(isnothing, rows) && return nothing
        return permutedims(reduce(hcat, rows))
    end
    return nothing
end

"""
Throws an `ArgumentError` if the text `new` of `system.jl` of the project folder `dir` changes a
line claimed by a participant other than `by`, naming the line and the holder.
"""
function _check_claims(dir, by, new)
    cl = claims(dir)
    isempty(cl) && return nothing
    file = joinpath(dir, "system.jl")
    isfile(file) || return nothing
    changed = _changed_keys(read(file, String), new)
    isnothing(changed) && return nothing
    for k in changed
        c = get(cl, k, nothing)
        (isnothing(c) || c.by == by || _holder_id(c.by) == _holder_id(by)) && continue
        throw(ArgumentError("$(c.id) is claimed by $(c.by); the project is not written"))
    end
    return nothing
end
