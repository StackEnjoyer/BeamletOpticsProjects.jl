# The log of the changes of the people: `.bmo/changes-<id>.toml`, written by their windows

const _CHANGE_KINDS = (:added, :removed, :renamed, :rebuilt, :relabeled, :meta, :moved, :members, :system)

_change_time(x::DateTime) = x
_change_time(x::AbstractString) = DateTime(replace(String(x), r"Z$" => ""))
_change_time(x) = throw(ArgumentError("no time: $x"))

_change_pos(x) = x isa AbstractVector && length(x) == 3 && all(v -> v isa Real, x) ?
                 NTuple{3, Float64}(Float64.(x)) : nothing

function _change_rot(x)
    x isa AbstractVector || return nothing
    all(v -> v isa Real, x) || return nothing
    length(x) == 3 && return NTuple{3, Float64}(Float64.(x))
    length(x) == 9 && return Matrix{Float64}(permutedims(reshape(Float64.(x), 3, 3)))  # row-major
    return nothing
end

"""
    changes(dir; by = nothing, since = nothing) -> Vector{Change}

The changes that the people made in their windows to the project in the folder `dir`, newest
first, read from the logs `.bmo/changes-<id>.toml` (see [`changes_file`](@ref)). A window logs
every change of its session (adding, removing, renaming, moving, ... ), so this is the whole
history with old and new poses, e.g. to put the layout of a person back; the session file shows
only the last 20.

With `by` (the id of a person, see [`person`](@ref)) only the log of that person is read, with
`since` (a `DateTime`, UTC) only changes at or after it are returned. A missing or unreadable log
gives no changes of that person (a broken one a warning).

Each `Change` is a `NamedTuple` `(; by, time, kind, id, text, old_pos, new_pos, old_rot, new_rot,
version)`: the person's id, the time (UTC), the kind (`:added`, `:removed`, `:renamed`,
`:rebuilt`, `:relabeled`, `:meta`, `:moved`, `:members` or `:system`), the id of the entry, a
sentence, the poses (`nothing` if not part of the change; `pos` an `NTuple{3, Float64}`, `rot` three
angles in degrees or a 3×3 matrix) and `version`, the id of the first version (see
[`versions`](@ref)) at or after the change, `nothing` if none was saved yet or the folder is in no
repository.
"""
function changes(dir::AbstractString; by = nothing, since = nothing)
    files = String[]
    if isnothing(by)
        bmo = joinpath(dir, ".bmo")
        isdir(bmo) && for f in sort(readdir(bmo))
            occursin(r"^changes-.+\.toml$", f) && push!(files, joinpath(bmo, f))
        end
    else
        f = changes_file(dir, String(by))
        isfile(f) && push!(files, f)
    end
    T = @NamedTuple{by::String, time::DateTime, kind::Symbol, id::Symbol, text::String,
        old_pos::Union{Nothing, NTuple{3, Float64}}, new_pos::Union{Nothing, NTuple{3, Float64}},
        old_rot::Union{Nothing, NTuple{3, Float64}, Matrix{Float64}},
        new_rot::Union{Nothing, NTuple{3, Float64}, Matrix{Float64}}, version::Union{Nothing, String}}
    out = T[]
    for file in files
        data = try
            TOML.parsefile(file)
        catch err
            @warn "The change log $file can not be read" exception = err
            continue
        end
        who = String(get(data, "person", ""))
        isempty(who) && (m = match(r"^changes-(.+)\.toml$", basename(file)); who = isnothing(m) ? "" : String(m.captures[1]))
        list = get(data, "change", nothing)
        list isa AbstractVector || continue
        for c in list
            c isa AbstractDict || continue
            try
                t = _change_time(c["time"])
                isnothing(since) || t >= since || continue
                push!(out, (; by = who, time = t, kind = Symbol(c["kind"]), id = Symbol(c["id"]),
                    text = String(get(c, "text", "")),
                    old_pos = _change_pos(get(c, "old_pos", nothing)),
                    new_pos = _change_pos(get(c, "new_pos", nothing)),
                    old_rot = _change_rot(get(c, "old_rot", nothing)),
                    new_rot = _change_rot(get(c, "new_rot", nothing)),
                    version = nothing))
            catch err
                @warn "A change in $file is skipped" exception = err
            end
        end
    end
    sort!(out; by = c -> c.time, rev = true)
    isempty(out) && return out
    vs = try
        versions(dir)
    catch
        []
    end
    isempty(vs) && return out
    for (i, c) in enumerate(out)
        t = floor(c.time, Second)
        k = nothing  # the oldest at or after (by time; of equal time the one further down the list)
        for (j, v) in enumerate(vs)
            v.time >= t && (isnothing(k) || v.time <= vs[k].time) && (k = j)
        end
        isnothing(k) || (out[i] = (; c..., version = vs[k].id))
    end
    return out
end
