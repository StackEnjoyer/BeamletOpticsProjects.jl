"""
    BeamletOpticsProjects

Projects of BeamletOptics: a folder that holds an optical setup as code (`system.jl`), own code
(`src/<Name>.jl`) and the versions it was made with (`Project.toml`). The GUI saves to and opens
from it; agents edit `system.jl` and `src/` directly.

See [`load_project`](@ref), [`save_project`](@ref), [`new_project`](@ref) and the macros
[`@component`](@ref), [`@source`](@ref) and [`@system`](@ref).
"""
module BeamletOpticsProjects

using BeamletOptics
using Dates: DateTime, unix2datetime
using FileWatching.Pidfile: mkpidlock
using LibGit2
using LinearAlgebra
using Pkg: Pkg
using SHA
using TOML
using UUIDs

const BMO = BeamletOptics

export Project, Entry, SystemEntry, GroupEntry, new_project, load_project, save_project, system_code,
       project_file, project_marker, project_dir, project_stamp, ProjectChanged, apply_pose!,
       rotation_matrix, @component, @source, @system, @group, id_prefix, next_id, diff_projects,
       EntryChange, SystemChange, GroupChange, copy_code, save_version, version_summary, versions, trace, look,
       announce, leave, fork_team, teams, post!, board, claim!, release!, claims, wait_for, merge_draft!,
       evaluate
public project_name, module_name, normalize_code, EXTENSION, same_entry, same_system, same_group, new_uid, match_entries,
       install_agent_skill, person, presence_file, session_file, write_presence, read_presences, alive,
       merge_plan, compose

"""Version of the format of `system.jl`, written to `[beamletoptics] format` of `Project.toml`."""
const FORMAT = 1

"""
    Entry(kind, name, code, object; pos = nothing, rot = nothing, pose0, meta = Pair{Symbol, Any}[],
          label = nothing, uid = nothing)

One `@component` (`kind = :component`) or `@source` (`kind = :source`) of a project: its unique
readable id `name` (e.g. `L1`, see [`next_id`](@ref)), the constructor expression `code`, the constructed and posed `object`, its pose `pos`
(absolute position in m, `nothing` = as constructed) and `rot` (rotation since construction, as
`(x, y, z)` angles in degrees, extrinsic `Rz(z)·Ry(y)·Rx(x)`, or a 3×3 matrix, `nothing` = none),
the pose `pose0 = (position, frame)` right after construction and further keywords `meta`, which
the project keeps but does not interpret (e.g. `:catalog` of the GUI), the `label` that is shown
instead of the id (`nothing`: the id) and the machine id `uid`, a UUID that never changes
(`nothing` until the first save), by which the GUI recognizes the entry after a rename.

The `frame` of `pose0` is the orientation, or for things with only a direction (beams) a
right-handed frame with the local y-axis along the direction, see `frame`.
"""
struct Entry
    kind::Symbol
    name::Symbol
    code::Any
    object::Any
    pos::Union{Nothing, NTuple{3, Float64}}
    rot::Union{Nothing, NTuple{3, Float64}, Matrix{Float64}}
    pose0::Tuple{Vector{Float64}, Matrix{Float64}}
    meta::Vector{Pair{Symbol, Any}}
    label::Union{Nothing, String}
    uid::Union{Nothing, String}
end

function Entry(kind::Symbol, name, code, object; pos = nothing, rot = nothing, pose0,
        meta = Pair{Symbol, Any}[], label = nothing, uid = nothing)
    kind in (:component, :source) ||
        throw(ArgumentError("kind must be :component or :source, got :$kind"))
    pos = pos === nothing ? nothing : NTuple{3, Float64}(Tuple(pos))
    rot = rot === nothing ? nothing :
          rot isa AbstractMatrix ? Matrix{Float64}(rot) : NTuple{3, Float64}(Tuple(rot))
    pose0 = (Vector{Float64}(pose0[1]), Matrix{Float64}(pose0[2]))
    return Entry(kind, Symbol(name), code, object, pos, rot, pose0,
        Pair{Symbol, Any}[Symbol(k) => v for (k, v) in meta], _string_or_nothing(label),
        _string_or_nothing(uid))
end

_string_or_nothing(::Nothing) = nothing
_string_or_nothing(s) = String(s)

"""
    SystemEntry(name, members, sources = Symbol[]; static = false, object = nothing, label = nothing,
                uid = nothing)

One `@system` of a project: its readable id `name`, the ids of its `members` and `sources`, whether
it is a `StaticSystem`, the built system `object`, its `label` and machine id `uid`, see [`Entry`](@ref).
"""
struct SystemEntry
    name::Symbol
    members::Vector{Symbol}
    sources::Vector{Symbol}
    static::Bool
    object::Any
    label::Union{Nothing, String}
    uid::Union{Nothing, String}
end

SystemEntry(name, members, sources = Symbol[]; static::Bool = false, object = nothing,
    label = nothing, uid = nothing) =
    SystemEntry(Symbol(name), Symbol.(collect(members)), Symbol.(collect(sources)), static, object,
        _string_or_nothing(label), _string_or_nothing(uid))

"""
    GroupEntry(name, members; pos, rot = nothing, object = nothing, label = nothing, uid = nothing)

One `@group` of a project, a `BeamletOptics.ObjectGroup`: its readable id `name` (e.g. `G1`), the
ids of its `members` (entries of `@component` or other groups, in the order of the group's
objects), its pivot `pos` (absolute position in m) and orientation `rot` (as for an [`Entry`](@ref),
`nothing` = the identity), the built group `object`, its `label` and machine id `uid`.

The members keep their own lines with their absolute poses; building the group moves none of them.
An entry or group is a member of at most one group, and an entry inside a group is in systems only
through its outermost group, which the systems list, see [`@group`](@ref).
"""
struct GroupEntry
    name::Symbol
    members::Vector{Symbol}
    pos::NTuple{3, Float64}
    rot::Union{Nothing, NTuple{3, Float64}, Matrix{Float64}}
    object::Any
    label::Union{Nothing, String}
    uid::Union{Nothing, String}
end

function GroupEntry(name, members; pos, rot = nothing, object = nothing, label = nothing, uid = nothing)
    rot = rot === nothing ? nothing :
          rot isa AbstractMatrix ? Matrix{Float64}(rot) : NTuple{3, Float64}(Tuple(rot))
    return GroupEntry(Symbol(name), Symbol.(collect(members)), NTuple{3, Float64}(Tuple(pos)), rot,
        object, _string_or_nothing(label), _string_or_nothing(uid))
end

"""
    Project(path, name; entries = Entry[], systems = SystemEntry[], groups = GroupEntry[])

A project in the folder `path` with the module name `name` (of `src/<name>.jl`), its `entries`
(`@component` and `@source` in file order), its `systems`, its `groups`, the module `mod` that
`system.jl` ran in (`nothing` for a project built in memory) and the `stamp` of its files when it
was loaded or saved (see [`project_stamp`](@ref), `nothing` for a project built in memory), against
which [`save_project`](@ref) checks that nobody else changed them meanwhile.
"""
mutable struct Project
    path::String
    name::String
    entries::Vector{Entry}
    systems::Vector{SystemEntry}
    groups::Vector{GroupEntry}
    mod::Union{Nothing, Module}
    stamp::Union{Nothing, String}
end

Project(path::AbstractString, name::AbstractString; entries = Entry[], systems = SystemEntry[],
    groups = GroupEntry[], stamp = nothing) =
    Project(abspath(path), String(name), collect(Entry, entries), collect(SystemEntry, systems),
        collect(GroupEntry, groups), nothing, stamp)

"""
    project[name]

The object or system called `name` (a `Symbol` or a string) in `project`.
"""
function Base.getindex(p::Project, name::Union{Symbol, AbstractString})
    n = Symbol(name)
    for e in p.entries
        e.name === n && return e.object
    end
    for s in p.systems
        s.name === n && return s.object
    end
    for g in p.groups
        g.name === n && return g.object
    end
    throw(KeyError(n))
end

"""
    project_file(project, file) -> String

The path of `file` in the folder of `project`, e.g. `project_file(p, "view.toml")`.
"""
project_file(p::Project, file::AbstractString) = joinpath(p.path, file)

function Base.show(io::IO, p::Project)
    print(io, "Project(\"", p.name, "\" at ", repr(p.path), ", ", length(p.entries), " entries, ",
        length(p.systems), " systems", isempty(p.groups) ? "" : ", $(length(p.groups)) groups", ")")
end

include("Stamp.jl")
include("Pose.jl")
include("Macros.jl")
include("Load.jl")
include("Write.jl")
include("New.jl")
include("Ids.jl")
include("Diff.jl")
include("Versions.jl")
include("AgentSkill.jl")
include("Trace.jl")
include("Look.jl")
include("Participants.jl")
include("Merge.jl")
include("Teams.jl")
include("Claims.jl")
include("Guards.jl")

end
