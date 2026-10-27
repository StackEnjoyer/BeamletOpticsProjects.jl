#=
Loading a project
=#

"""
    load_project(path) -> Project

Loads the project in the folder `path`, or of the project file `path` (`<name>.bmo`, see
[`project_marker`](@ref)): includes the own code `src/<name>.jl` (a module `<name>`,
whose exported names `system.jl` can use) and runs `system.jl`, whose [`@component`](@ref),
[`@source`](@ref) and [`@system`](@ref) fill the returned [`Project`](@ref). Both run in a new
module of their own, which `using BeamletOptics, BeamletOpticsProjects`.

Errors name the line of `system.jl`. The versions in `Project.toml` are not checked.
"""
function load_project(path::AbstractString)
    path = project_dir(path)
    file = joinpath(path, "system.jl")
    isfile(file) || throw(ArgumentError("no system.jl in \"$path\""))
    name = project_name(path)
    # Before reading: a change while loading makes the stamp differ
    stamp = project_stamp(path)
    mod = _project_module(path, name)
    p = Project(path, name; stamp)
    p.mod = mod
    task_local_storage(_LOADING, p) do
        task_local_storage(_WHERE, String[]) do
            Base.include(mod, file)
            _build_systems!(p, task_local_storage(_WHERE))
        end
    end
    return p
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
