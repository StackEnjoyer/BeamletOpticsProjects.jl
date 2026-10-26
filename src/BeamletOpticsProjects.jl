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
using LinearAlgebra
using TOML
using UUIDs

const BMO = BeamletOptics

export Project, Entry, SystemEntry, new_project, load_project, save_project, system_code,
       project_file, apply_pose!, rotation_matrix, @component, @source, @system

"""Version of the format of `system.jl`, written to `[beamletoptics] format` of `Project.toml`."""
const FORMAT = 1

"""
    Entry(kind, name, code, object; pos = nothing, rot = nothing, pose0, meta = Pair{Symbol, Any}[])

One `@component` (`kind = :component`) or `@source` (`kind = :source`) of a project: its unique
`name`, the constructor expression `code`, the constructed and posed `object`, its pose `pos`
(absolute position in m, `nothing` = as constructed) and `rot` (rotation since construction, as
`(x, y, z)` angles in degrees, extrinsic `Rz(z)·Ry(y)·Rx(x)`, or a 3×3 matrix, `nothing` = none),
the pose `pose0 = (position, frame)` right after construction and further keywords `meta`, which
the project keeps but does not interpret (e.g. `:catalog` of the GUI).

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
end

function Entry(kind::Symbol, name, code, object; pos = nothing, rot = nothing, pose0,
        meta = Pair{Symbol, Any}[])
    kind in (:component, :source) ||
        throw(ArgumentError("kind must be :component or :source, got :$kind"))
    pos = pos === nothing ? nothing : NTuple{3, Float64}(Tuple(pos))
    rot = rot === nothing ? nothing :
          rot isa AbstractMatrix ? Matrix{Float64}(rot) : NTuple{3, Float64}(Tuple(rot))
    pose0 = (Vector{Float64}(pose0[1]), Matrix{Float64}(pose0[2]))
    return Entry(kind, Symbol(name), code, object, pos, rot, pose0,
        Pair{Symbol, Any}[Symbol(k) => v for (k, v) in meta])
end

"""
    SystemEntry(name, members, sources = Symbol[]; static = false, object = nothing)

One `@system` of a project: its `name`, the names of its `members` and `sources`, whether it is
a `StaticSystem` and the built system `object`.
"""
struct SystemEntry
    name::Symbol
    members::Vector{Symbol}
    sources::Vector{Symbol}
    static::Bool
    object::Any
end

SystemEntry(name, members, sources = Symbol[]; static::Bool = false, object = nothing) =
    SystemEntry(Symbol(name), Symbol.(collect(members)), Symbol.(collect(sources)), static, object)

"""
    Project(path, name; entries = Entry[], systems = SystemEntry[])

A project in the folder `path` with the module name `name` (of `src/<name>.jl`), its `entries`
(`@component` and `@source` in file order), its `systems` and the module `mod` that `system.jl`
ran in (`nothing` for a project built in memory).
"""
mutable struct Project
    path::String
    name::String
    entries::Vector{Entry}
    systems::Vector{SystemEntry}
    mod::Union{Nothing, Module}
end

Project(path::AbstractString, name::AbstractString; entries = Entry[], systems = SystemEntry[]) =
    Project(abspath(path), String(name), collect(Entry, entries), collect(SystemEntry, systems),
        nothing)

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
    throw(KeyError(n))
end

"""
    project_file(project, file) -> String

The path of `file` in the folder of `project`, e.g. `project_file(p, "view.toml")`.
"""
project_file(p::Project, file::AbstractString) = joinpath(p.path, file)

function Base.show(io::IO, p::Project)
    print(io, "Project(\"", p.name, "\" at ", repr(p.path), ", ", length(p.entries), " entries, ",
        length(p.systems), " systems)")
end

include("Pose.jl")
include("Macros.jl")
include("Load.jl")
include("Write.jl")
include("New.jl")

end
