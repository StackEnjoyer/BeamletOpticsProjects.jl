#=
Writing system.jl: the same project always gives the same text
=#

"""
    system_code(project) -> String

The text of `system.jl` of `project`: a header, then one line per `@component`, `@source` and
`@system`, in this order and in the order of the entries. Numbers are written exactly and as short
as possible; a rotation given as a matrix is written as angles in degrees if it can be, see
[`rotation_matrix`](@ref).
"""
function system_code(p::Project)
    io = IOBuffer()
    println(io, "# BeamletOptics project \"", p.name, "\" (format ", FORMAT, "). Agents: see AGENTS.md.")
    for kind in (:component, :source)
        for e in p.entries
            e.kind === kind && println(io, _entry_line(e))
        end
    end
    for s in p.systems
        println(io, _system_line(s))
    end
    return String(take!(io))
end

function _entry_line(e::Entry)
    io = IOBuffer()
    print(io, "@", e.kind, " ", e.name, " = ", _code_string(e.code))
    e.pos === nothing || print(io, " pos = ", _tuple_string(e.pos))
    r = _rot_string(e.rot)
    r === nothing || print(io, " rot = ", r)
    for (k, v) in e.meta
        print(io, " ", k, " = ", _code_string(v))
    end
    return String(take!(io))
end

function _system_line(s::SystemEntry)
    io = IOBuffer()
    print(io, "@system ", s.name, " = [", join(s.members, ", "), "]")
    isempty(s.sources) || print(io, " sources = [", join(s.sources, ", "), "]")
    s.static && print(io, " static = true")
    return String(take!(io))
end

"""Code on one line: an expression as Julia prints it, a string of code parsed first."""
_code_string(code::AbstractString) = _code_string(Meta.parse(code))
function _code_string(@nospecialize(code))
    s = code isa Union{Expr, Symbol} ? string(normalize_code(code)) : repr(code)
    occursin('\n', s) && throw(ArgumentError("code does not fit on one line: $s"))
    return s
end

_float_string(x) = repr(iszero(x) ? 0.0 : Float64(x))
_tuple_string(t) = string("(", join(map(_float_string, t), ", "), ")")

_rot_string(::Nothing) = nothing
_rot_string(t::Tuple) = _tuple_string(t)
function _rot_string(R::AbstractMatrix)
    maximum(abs, R - I) ≤ _ROT_TOL && return nothing
    angles = euler_angles(R)
    angles === nothing && return string("[", join((join(map(_float_string, R[i, :]), " ")
                                                   for i in 1:3), "; "), "]")
    return _tuple_string(angles)
end

"""How close a written rotation must be to the matrix it stands for."""
const _ROT_TOL = 1e-13

"""
    euler_angles(R) -> Union{Nothing, NTuple{3, Float64}}

The angles `(a, b, c)` in degrees with `rotation_matrix((a, b, c)) ≈ R`, each the shortest
decimal that keeps the deviation within `1e-13`; `nothing` near gimbal lock (`b` close to ±90°).
"""
function euler_angles(R::AbstractMatrix)
    cb = hypot(R[1, 1], R[2, 1])
    cb < 1e-6 && return nothing
    angles = [rad2deg(atan(R[3, 2], R[3, 3])), rad2deg(atan(-R[3, 1], cb)),
              rad2deg(atan(R[2, 1], R[1, 1]))]
    for i in 1:3
        for digits in 1:17
            trial = copy(angles)
            trial[i] = round(angles[i]; sigdigits = digits)
            if maximum(abs, rotation_matrix(Tuple(trial)) - R) ≤ _ROT_TOL
                angles = trial
                break
            end
        end
    end
    return Tuple(a == 0 ? 0.0 : a for a in angles)
end

"""
    save_project(project; packages = Module[]) -> String
    save_project(project, path; packages = Module[]) -> String

Writes `system.jl` of `project` (in the folder `path`, which becomes the folder of the project)
and returns its path. A folder that is not a project yet gets the files of [`new_project`](@ref),
whose `Project.toml` records the versions of BeamletOptics, BeamletOpticsProjects and `packages`.
"""
function save_project(p::Project; packages::Vector{Module} = Module[])
    mkpath(p.path)
    isfile(project_file(p, "Project.toml")) || _scaffold(p.path, p.name, packages)
    # A project of the time before project files
    marker = project_marker(p.path)
    isfile(marker) || write(marker, _marker_text(splitext(basename(marker))[1]))
    file = project_file(p, "system.jl")
    _write_atomic(file, system_code(p))
    return file
end

function save_project(p::Project, path::AbstractString; packages::Vector{Module} = Module[])
    p.path = abspath(path)
    return save_project(p; packages)
end

"""Writes `text` to a temporary file next to `file` and then moves it there."""
function _write_atomic(file, text)
    tmp = file * ".tmp"
    write(tmp, text)
    mv(tmp, file; force = true)
    return file
end
