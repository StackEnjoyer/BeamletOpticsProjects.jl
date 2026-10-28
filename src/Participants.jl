#=
Participants of a project: the people in their windows and the coding agents that change the
files, alike. Each participant has a presence file `.bmo/presence-<id>.toml` and optionally a
session file `.bmo/session-<id>.md`. No function here looks at `kind`: it is a label for display.
=#

# The `ttl` of a presence file without a valid one [s] and the range its `ttl` is clamped to
const _TTL_DEFAULT = 60.0
const _TTL_RANGE = (5.0, 3600.0)

# `"name@host"` with every character outside `[A-Za-z0-9_.@-]` replaced by `_`
_participant_id(name::AbstractString, host::AbstractString) =
    replace("$name@$host", r"[^A-Za-z0-9_.@-]" => "_")

"""
    person() -> (; id, name, host)

The person at this machine: `name` from `ENV["BMO_PERSON"]`, else the user name of the system
(`USERNAME`, `USER`), else `"someone"`; `host` the name of the machine; `id` is `"name@host"` with
every character outside `[A-Za-z0-9_.@-]` replaced by `_`, for the names of the files of the person
in `.bmo/` (see [`presence_file`](@ref), [`session_file`](@ref)).
"""
function person()
    name = get(ENV, "BMO_PERSON", get(ENV, "USERNAME", get(ENV, "USER", "someone")))
    isempty(strip(name)) && (name = "someone")
    host = gethostname()
    return (; id = _participant_id(name, host), name = String(name), host = String(host))
end

"""
    presence_file(dir, id) -> String

The presence file `.bmo/presence-<id>.toml` of the participant `id` (e.g. `person().id` or the id
that [`announce`](@ref) returns) in the project folder `dir`. Every participant, a window or a
coding agent, has one while it works on the project. It is a TOML file with the fields

- `name`: how the others see the participant, e.g. `"Claude (Opus 5.5)"` (default: the id);
- `host`: the name of the machine;
- `kind`: e.g. `"person"` or `"agent"` (default `"person"`), a label for display only;
- `beat`: an integer that grows by one with every write (required; a file without it is ignored);
- `ttl`: the seconds that the last change of `beat` counts (default 60, clamped to 5…3600);
  windows write 60, agents 120 by default (`announce`), since they write only when they act;
- `selected`: the machine id (uid) of the object it works on, `""` if none;
- `selected_id`: the readable id of that object (e.g. `"L1"`), used when `selected` is missing or
  unknown;
- `doing`: a few words of what it does;
- `written`: the [`project_stamp`](@ref) of the files after its last write, by which the others
  find the writer of a change.

Whether a participant is there is judged on the clock of the reader only, see [`alive`](@ref).
Write the file with [`write_presence`](@ref), read those of the others with
[`read_presences`](@ref).
"""
presence_file(dir::AbstractString, id::AbstractString) = joinpath(dir, ".bmo", "presence-$id.toml")

"""
    session_file(dir, id) -> String

The session file `.bmo/session-<id>.md` of the participant `id` in the project folder `dir`: a few
lines of prose of what it sees and does, for the agents that work on the same project (the hook of
the project shows every `.bmo/session*.md` to Claude Code).
"""
session_file(dir::AbstractString, id::AbstractString) = joinpath(dir, ".bmo", "session-$id.md")

# The id of the participant of a presence file name, `nothing` for other files
function _presence_id(name::AbstractString)
    m = match(r"^presence-(.+)\.toml$", name)
    return isnothing(m) ? nothing : String(m.captures[1])
end

# The `beat` of the presence file `file`, 0 if it is missing, does not parse or has none
function _file_beat(file::AbstractString)
    isfile(file) || return 0
    try
        b = get(TOML.parsefile(file), "beat", 0)
        return b isa Integer ? Int(b) : 0
    catch
        return 0
    end
end

# The `written` of the presence file `file`, `""` if it is missing, does not parse or has none
function _file_written(file::AbstractString)
    isfile(file) || return ""
    try
        return _presence_string(TOML.parsefile(file), "written")
    catch
        return ""
    end
end

"""
    write_presence(dir, id, data) -> Int

Writes the presence file of the participant `id` in the project folder `dir` (see
[`presence_file`](@ref)) with the fields of `data` (keys converted to strings) and `beat` one
higher than in the file before (1 for a new file; a `beat` in `data` is ignored), so that a
participant that comes back continues its counter and the others see a change. Creates `.bmo/`.
The write is atomic: a temporary file is moved into place, and a move that fails (e.g. a sharing
violation on a network drive) is tried again. Returns the new `beat`.
"""
function write_presence(dir::AbstractString, id::AbstractString, data::AbstractDict)
    file = presence_file(dir, id)
    out = Dict{String, Any}(string(k) => v for (k, v) in data)
    beat = _file_beat(file) + 1
    out["beat"] = beat
    mkpath(dirname(file))
    _write_atomic(file, sprint(io -> TOML.print(io, out; sorted = true)))
    return beat
end

# The `ttl` of a presence file: a positive real clamped to `_TTL_RANGE`, else `_TTL_DEFAULT`
function _presence_ttl(x)
    (x isa Real && isfinite(x) && x > 0) || return _TTL_DEFAULT
    return clamp(Float64(x), _TTL_RANGE...)
end

# A string field of a presence file, `""` if it is missing or not a string
_presence_string(data, key) = (x = get(data, key, ""); x isa AbstractString ? String(x) : "")

"""
    read_presences(dir; except = nothing) -> Dict{String, Dict{String, Any}}

The presence files of the participants of the project folder `dir` (see [`presence_file`](@ref))
by id, without the one of the id `except` (e.g. the own `person().id`). A file that does not parse
(e.g. half written on a network drive) or has no integer `beat` is skipped. The fields are
normalized: `beat` an `Int`; `ttl` a `Float64` clamped to 5…3600 s (60 if missing or invalid);
`name` (default: the id), `kind` (default `"person"`), `host`, `selected`, `selected_id`, `doing`
and `written` strings (default `""`); other fields are kept as they are. Whether a participant is
there is up to the reader, which notes when it saw `beat` change, see [`alive`](@ref).
"""
function read_presences(dir::AbstractString; except = nothing)
    out = Dict{String, Dict{String, Any}}()
    bmo = joinpath(dir, ".bmo")
    isdir(bmo) || return out
    for name in readdir(bmo)
        id = _presence_id(name)
        (isnothing(id) || id == except) && continue
        data = try
            TOML.parsefile(joinpath(bmo, name))
        catch
            continue
        end
        beat = get(data, "beat", nothing)
        beat isa Integer || continue
        d = Dict{String, Any}(data)
        d["beat"] = Int(beat)
        d["ttl"] = _presence_ttl(get(data, "ttl", nothing))
        n = _presence_string(data, "name")
        d["name"] = isempty(n) ? id : n
        k = _presence_string(data, "kind")
        d["kind"] = isempty(k) ? "person" : k
        for key in ("host", "selected", "selected_id", "doing", "written")
            d[key] = _presence_string(data, key)
        end
        out[id] = d
    end
    return out
end

"""
    alive(o, now) -> Bool

Whether the participant `o` is there at the time `now` (s, e.g. `time()`): its `beat` changed
within its `ttl` seconds, `now - o.seen_at < o.ttl`. `o` is anything with the properties `seen_at`,
the time on the clock of the reader at which the reader last saw the `beat` of the participant
change, and `ttl` (see [`read_presences`](@ref)). Only the clock of the reader is used, so the
clocks of the machines are never compared.
"""
alive(o, now::Real) = now - o.seen_at < o.ttl

"""
    announce(dir; name, doing = "", selected_id = "", ttl = 120, kind = "agent", wrote = false) -> String

Takes part in the project in the folder `dir`, or tells the others the next step: writes the
presence file (see [`presence_file`](@ref)) of the id `"<name>@agent"` (characters outside
`[A-Za-z0-9_.@-]` replaced by `_`) with `name`, the host, `kind` (a label only), `ttl`, the
readable id `selected_id` of the object it works on and `doing` (a few words). `beat` grows by one
with every call (see [`write_presence`](@ref)). Call it before changing the project, after each
change and at every step; call [`leave`](@ref) when done. Returns the id. The claims of the
participant (see [`claim!`](@ref)) live as long as its presence, i.e. `ttl` seconds after its
last call; `claim!` writes the presence again.

`name` is the id of the participant and must be unique per participant (e.g. `"claude-w1"` for a
worker of a team): participants with the same `name` share one presence file, so their calls
overwrite each other and the first [`leave`](@ref) removes all of them.

With `wrote = true`, call right after writing the files: it publishes `written`, the stamp of the
files now (see [`project_stamp`](@ref)), so that the windows name this participant as the writer
of that change, as they do for a window after a save, also when the call comes after the windows
merged the change. Otherwise the `written` of the presence file before is kept (`""` if there is
none), so a call that wrote nothing never claims the change of someone else.
"""
function announce(dir::AbstractString; name, doing = "", selected_id = "", ttl = 120, kind = "agent",
        wrote::Bool = false)
    id = _participant_id(String(name), "agent")
    written = wrote ? project_stamp(dir) : _file_written(presence_file(dir, id))
    data = Dict{String, Any}("name" => String(name), "host" => gethostname(), "kind" => String(kind),
        "ttl" => ttl, "selected_id" => String(selected_id), "doing" => String(doing),
        "written" => written)
    write_presence(dir, id, data)
    return id
end

"""
    leave(dir; name)

Ends taking part in the project in the folder `dir`: deletes the presence file that
[`announce`](@ref) with the same `name` wrote, the one of every participant of that `name`. A
missing file is fine.
"""
function leave(dir::AbstractString; name)
    rm(presence_file(dir, _participant_id(String(name), "agent")); force = true)
    return nothing
end
