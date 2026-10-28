#=
Claims: the participant who changes an object holds its claim, and the others do not change it
meanwhile. A claim is a file of its own, created exclusively (the one atomic step of a shared
drive), named by the machine id of the line; it is alive while its holder's presence is
=#

# A claim of a holder without a presence file (e.g. an agent that never announced) counts that
# long after its file was written [s]
const _CLAIM_GRACE = 120.0

"""
The folder of the claims of the project or team draft in the folder `dir`: `claims/` of a draft
(see [`fork_team`](@ref)), else `.bmo/claims/` of the project.
"""
_claims_dir(dir) = isfile(joinpath(dir, "team.toml")) ? joinpath(dir, "claims") : joinpath(dir, ".bmo", "claims")

# The project folder whose presence files tell whether the holders of the claims in `dir` are
# there: the project of a draft (`<project>/.bmo/drafts/<team>`), else `dir`
_presence_dir(dir) = isfile(joinpath(dir, "team.toml")) ? dirname(dirname(dirname(dir))) : dir

# The participant id of `by`: as given if it has a host (`"anna@pc2"`), else an agent (`"w1@agent"`,
# see `announce`)
_holder_id(by) = occursin('@', by) ? String(by) : string(by, "@agent")

"""
The keys (the machine id, else `"id:L1"`) of the readable ids `ids` in `system.jl` of the folder
`dir`, read from the text without running it; an id that is not a line there keeps `"id:<id>"`.
"""
function _claim_keys(dir, ids)
    file = joinpath(dir, "system.jl")
    lines = isfile(file) ? _parse_lines(read(file, String)) : nothing
    uid = Dict{Symbol, String}()
    isnothing(lines) || foreach(l -> isnothing(l.uid) || (uid[l.name] = l.uid), lines[1])
    return Dict{Symbol, String}(id => get(uid, id, "id:" * String(id)) for id in ids)
end

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
Creates the claim file `file` with `body` if it does not exist, such that it never exists without
its holder: the body goes into a temporary file of this writer first, which is then linked to
`file` (a hard link fails if `file` exists). Falls back to an exclusive create where hard links
are not supported. `true` if it was created, `false` if it existed.
"""
function _claim_create(file, body)
    tmp = string(file, ".", getpid(), "-", rand(UInt32), ".tmp")
    write(tmp, body)
    try
        hardlink(tmp, file)
        return true
    catch e
        _exists_error(e) && return false
        e isa Base.IOError || rethrow()
        # No hard links on this file system: exclusive create, then write
        F = Base.Filesystem
        f = try
            F.open(file, F.JL_O_CREAT | F.JL_O_EXCL | F.JL_O_WRONLY, 0o644)
        catch e2
            _exists_error(e2) && return false
            rethrow()
        end
        try
            write(f, body)
        finally
            close(f)
        end
        return true
    finally
        rm(tmp; force = true)
    end
end

# Takes away the stale claim file `file`: of several that do it at once, exactly one moves it
function _claim_break(file)
    try
        Base.rename(file, string(file, ".stale-", getpid(), "-", rand(UInt32)))
    catch e
        e isa Base.IOError || rethrow()
        return false
    end
    for f in readdir(dirname(file); join = true)
        occursin(".stale-", f) && rm(f; force = true)
    end
    return true
end

"""
    claim!(dir; by, ids) -> Bool

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
with (`"w1"`); a claim also refreshes the agent's presence. Windows of people refuse to change an
object claimed by someone else, and [`save_project`](@ref) with `by` refuses to write its line.
See [`release!`](@ref), [`claims`](@ref).
"""
function claim!(dir::AbstractString; by, ids::Vector{Symbol})
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
        for _ in 1:2
            if _claim_create(file, body)
                push!(made, file)
                taken = true
                break
            end
            c = _claim_read(file)
            # An unreadable claim is one that is being written or taken away: not ours
            isnothing(c) && break
            c.by == by && (taken = true; touch(file); break)
            _claim_alive(pdir, file, c.by) && break
            _claim_break(file)
        end
        if !taken
            foreach(f -> rm(f; force = true), made)
            return false
        end
    end
    _refresh_presence(pdir, by)
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
    keys = isnothing(ids) ? nothing : Set(values(_claim_keys(dir, collect(Symbol, ids))))
    for f in readdir(cdir; join = true)
        endswith(f, ".toml") || continue
        c = _claim_read(f)
        (isnothing(c) || c.by != by) && continue
        (isnothing(keys) || c.key in keys) && rm(f; force = true)
    end
    return nothing
end

"""
    claims(dir) -> Dict{String, @NamedTuple{by::String, id::Symbol}}

The claims of the project or team draft in the folder `dir` whose holders are still there, by the
machine id of their line (`"id:L1"` for a line without one): the participant `by` and the readable
id `id` at the time of the claim. See [`claim!`](@ref).
"""
function claims(dir::AbstractString)
    dir = abspath(dir)
    cdir = _claims_dir(dir)
    pdir = _presence_dir(dir)
    out = Dict{String, @NamedTuple{by::String, id::Symbol}}()
    isdir(cdir) || return out
    for f in readdir(cdir; join = true)
        (endswith(f, ".toml") && !startswith(basename(f), ".")) || continue
        c = _claim_read(f)
        (isnothing(c) || isempty(c.key)) && continue
        _claim_alive(pdir, f, c.by) && (out[c.key] = (by = c.by, id = c.id))
    end
    return out
end

"""
The keys of the lines (entries, systems, groups) that the text `new` of `system.jl` changes, adds
or removes compared with the text `old`, by the machine id (`"id:L1"` without one).
"""
function _changed_keys(old, new)
    a, b = _parse_lines(old), _parse_lines(new)
    (isnothing(a) || isnothing(b)) && return nothing
    key(l) = isnothing(l.uid) ? "id:" * String(l.name) : l.uid
    pairs, added, removed = _pair(a[1], b[1])
    out = Set{String}(key(l) for l in Iterators.flatten((added, removed)))
    for (o, n) in pairs
        (o.name == n.name && o.macroname == n.macroname && o.code == n.code && o.pose == n.pose &&
         o.rest == n.rest) || push!(out, key(o))
    end
    return out
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
