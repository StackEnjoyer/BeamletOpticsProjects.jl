#=
Loading a project
=#

"""
    load_project(path) -> Project

Loads the project in the folder `path`, or of the project file `path` (`<name>.bmo`, see
[`project_marker`](@ref)): includes the own code `src/<name>.jl` (a module `<name>`,
whose exported names `system.jl` can use) and runs `system.jl`, whose [`@component`](@ref),
[`@source`](@ref), [`@group`](@ref) and [`@system`](@ref) fill the returned [`Project`](@ref).
Both run in a new module of their own, which `using BeamletOptics, BeamletOpticsProjects`. The
groups are built when all lines are read, inner groups first, and then the systems.

Errors name the line of `system.jl`. A load that fails while another participant writes
`system.jl` (it is half written at that moment, or cannot be opened while it is replaced, e.g. on
Windows or a shared drive) is tried again, up to 3 times, if the file changed or could not be read
a quarter of a second later; an error of a file that stays as it is is thrown after that one wait.
A project whose format (`[beamletoptics] format` of `Project.toml`, none: 1) is newer than the one
this package reads is refused; the versions of the packages in `Project.toml` are not checked.
"""
function load_project(path::AbstractString)
    path = project_dir(path)
    file = joinpath(path, "system.jl")
    isfile(file) || throw(ArgumentError("no system.jl in \"$path\""))
    for attempt in 1:4
        before = _read_now(file)
        try
            return _load_project(path, file)
        catch e
            e isa InterruptException && rethrow()
            attempt < 4 || rethrow()
            # A file that another participant is writing: try again once it changed
            sleep(_LOAD_RETRY)
            after = _read_now(file)
            isnothing(before) || isnothing(after) || after != before || rethrow()
        end
    end
end

# The bytes of `file`, `nothing` if it can not be read at the moment (e.g. while it is replaced)
function _read_now(file)
    try
        return read(file)
    catch e
        (e isa SystemError || e isa Base.IOError) || rethrow()
        return nothing
    end
end

# How long `load_project` waits after a failed load before it looks whether the file changed [s]
const _LOAD_RETRY = 0.25

function _load_project(path, file)
    _check_format(path)
    name = project_name(path)
    # Before reading: a change while loading makes the stamp differ
    stamp = project_stamp(path)
    mod = _project_module(path, name)
    p = Project(path, name; stamp)
    p.mod = mod
    task_local_storage(_LOADING, p) do
        task_local_storage(_WHERE, String[]) do
            task_local_storage(_GROUP_WHERE, String[]) do
                Base.include(mod, file)
                _build_groups!(p, task_local_storage(_GROUP_WHERE))
                _build_systems!(p, task_local_storage(_WHERE))
            end
        end
    end
    return p
end

"""
Throws if the project in the folder `path` has a newer format (`[beamletoptics] format` of its
`Project.toml`) than [`FORMAT`](@ref); a missing entry is format 1.
"""
function _check_format(path)
    toml = joinpath(path, "Project.toml")
    isfile(toml) || return nothing
    format = get(get(TOML.parsefile(toml), "beamletoptics", Dict{String, Any}()), "format", 1)
    format isa Integer || throw(ArgumentError("[beamletoptics] format of \"$toml\" must be an integer, got $(repr(format))"))
    format ≤ FORMAT && return nothing
    throw(ArgumentError("the project in \"$path\" has format $format, this BeamletOpticsProjects reads format $FORMAT and older: update BeamletOpticsProjects"))
end

"""File extension of the project file, see [`project_marker`](@ref)."""
const EXTENSION = ".bmo"

"""
    project_marker(dir) -> String

The path of the project file of the project in the folder `dir`: the file `*.bmo` in it, or
`<folder name>.bmo` if there is none yet. People and the dialogs of the GUI open a project by it;
it holds only the format, the project is the folder.
"""
function project_marker(dir::AbstractString)
    dir = abspath(dir)
    if isdir(dir)
        for f in sort(readdir(dir))
            endswith(f, EXTENSION) && isfile(joinpath(dir, f)) && return joinpath(dir, f)
        end
    end
    return joinpath(dir, basename(rstrip(dir, ['/', '\\'])) * EXTENSION)
end

"""
    project_dir(path) -> String

The folder of a project from `path`, which is the folder or its project file (`*.bmo`).
"""
function project_dir(path::AbstractString)
    path = abspath(path)
    return endswith(path, EXTENSION) && !isdir(path) ? dirname(path) : rstrip(path, ['/', '\\'])
end

"""
    project_name(path) -> String

The module name of the project in the folder `path`: `name` of its `Project.toml`, else
[`module_name`](@ref) of the folder.
"""
function project_name(path)
    toml = joinpath(path, "Project.toml")
    isfile(toml) && return String(get(TOML.parsefile(toml), "name", module_name(path)))
    return module_name(path)
end

"""
    module_name(path) -> String

A valid module name from the name of the folder `path`, e.g. `"Laser_bench"` for `laser-bench`.
"""
function module_name(path)
    s = replace(basename(rstrip(abspath(path), ['/', '\\'])), r"[^A-Za-z0-9_]" => "_")
    s = isempty(s) || !isletter(s[1]) ? "Project_" * s : s
    return uppercase(s[1:1]) * s[2:end]
end

"""A new module with BeamletOptics, BeamletOpticsProjects and the own code of the project."""
function _project_module(path, name)
    mod = Module(:SystemModule)
    # The packages by identity, so that it works in any active environment
    Core.eval(mod, :(const BeamletOptics = $BMO))
    Core.eval(mod, :(const BeamletOpticsProjects = $(@__MODULE__)))
    Core.eval(mod, :(using .BeamletOptics, .BeamletOpticsProjects))
    src = joinpath(path, "src", name * ".jl")
    if isfile(src)
        Base.include(mod, src)
        sym = Symbol(name)
        # The module was defined by the include, in a newer world than this function's
        Base.invokelatest(isdefined, mod, sym) &&
            Base.invokelatest(getfield, mod, sym) isa Module &&
            Core.eval(mod, :(using .$sym))
    end
    return mod
end
