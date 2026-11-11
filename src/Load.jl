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
A project whose format (`format` of its project file `<name>.bmo`, none: 1) is newer than the one
this package reads is refused; the versions that the project file records are not checked (see
[`check_versions`](@ref)). If the own code uses (`using`, `import`) a package that is not
installed in the active environment, throws an `ArgumentError` that names it.
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
Throws if the project in the folder `path` has a newer format (`format` of its project file, see
[`project_marker`](@ref)) than `FORMAT`; a missing entry or file is format 1.
"""
function _check_format(path)
    format = get(_read_marker(path), "format", 1)
    format isa Integer ||
        throw(ArgumentError("format of \"$(project_marker(path))\" must be an integer, got $(repr(format))"))
    format ≤ FORMAT && return nothing
    throw(ArgumentError("the project in \"$path\" has format $format, this BeamletOpticsProjects reads format $FORMAT and older: update BeamletOpticsProjects"))
end

"""File extension of the project file, see [`project_marker`](@ref)."""
const EXTENSION = ".bmo"

"""
    project_marker(dir) -> String

The path of the project file of the project in the folder `dir`: the file `*.bmo` in it, or
`<folder name>.bmo` if there is none yet. People and the dialogs of the GUI open a project by it;
the project is the folder. It is the only file of metadata of the project, a TOML file with

- `format`: the version of the format of `system.jl` (see `FORMAT`), none: 1;
- `name`: the module name of the own code `src/<name>.jl` (none: [`module_name`](@ref) of the
  folder);
- `[versions]`: the newest versions of BeamletOptics, BeamletOpticsProjects and the packages of
  the program that saved it (e.g. BeamletOpticsGUI) that the project was saved with: every save
  raises them, none lowers them;
- `[packages]`: the packages that the own code in `src/` uses (`using`, `import`), with the newest
  version they were saved with (`""` if it was not known).

See [`project_versions`](@ref), [`check_versions`](@ref).
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

The module name of the project in the folder `path` (or of its project file): `name` of its
project file (see [`project_marker`](@ref)), else [`module_name`](@ref) of the folder.
"""
function project_name(path)
    path = project_dir(path)
    name = get(_read_marker(path), "name", nothing)
    return name isa AbstractString && !isempty(name) ? String(name) : module_name(path)
end

"""
The content of the project file of the project in the folder `dir` (see [`project_marker`](@ref)),
empty if there is none. Throws an `ArgumentError` if it does not parse.
"""
function _read_marker(dir)
    file = project_marker(dir)
    isfile(file) || return Dict{String, Any}()
    try
        return TOML.parsefile(file)
    catch e
        e isa TOML.ParserError || rethrow()
        throw(ArgumentError("the project file \"$file\" is not valid TOML: $(sprint(showerror, e))"))
    end
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
        try
            Base.include(mod, src)
        catch e
            pkg = _missing_package(e)
            isnothing(pkg) && rethrow()
            throw(ArgumentError("the project's code uses $pkg, which is not installed in this environment: `] add $pkg`"))
        end
        sym = Symbol(name)
        # The module was defined by the include, in a newer world than this function's
        Base.invokelatest(isdefined, mod, sym) &&
            Base.invokelatest(getfield, mod, sym) isa Module &&
            Core.eval(mod, :(using .$sym))
    end
    return mod
end

"""
The name of the package that the error `e` of an `include` says is not installed (`using X` of a
package that the active environments do not have, or have without installing it), else `nothing`.
"""
function _missing_package(e)
    while e isa LoadError
        e = e.error
    end
    e isa ArgumentError || return nothing
    m = match(r"^Package (\w+) not found in current path", e.msg)
    isnothing(m) &&
        (m = match(r"^Package (\w+) \[[^\]]*\] is required but does not seem to be installed", e.msg))
    return isnothing(m) ? nothing : String(m.captures[1])
end

#=
The versions that the project file records, and those of this session
=#

"""
    project_versions(path) -> (; versions::Dict{String, String}, packages::Dict{String, String})

The versions that the project file of the project in the folder `path` (or the project file
`path`) records, by package name (see [`project_marker`](@ref)): `versions`, the newest versions
of BeamletOptics, BeamletOpticsProjects and the programs that saved it (e.g. BeamletOpticsGUI),
and `packages`, the packages that the own code in `src/` uses with their newest versions (`""`:
not known). Both are empty for a project file without them (or without a project file).
"""
function project_versions(path::AbstractString)
    data = _read_marker(project_dir(path))
    return (; versions = _string_table(get(data, "versions", nothing)),
        packages = _string_table(get(data, "packages", nothing)))
end

# A table of the project file as strings by string, without entries that are not strings
_string_table(x) = x isa AbstractDict ?
    Dict{String, String}(String(k) => String(v) for (k, v) in x if v isa AbstractString) :
    Dict{String, String}()

"""
    VersionCheck(package, recorded, installed, status)

The result of [`check_versions`](@ref) for one package: its name, the version that the project
records (`nothing`: none or not a version), the version of this session (`nothing`: not known or
not installed) and `status`:

- `:same`: the same version, or nothing to compare (no version recorded or known);
- `:newer`: a newer version is installed that is compatible with the recorded one (same major
  version from 1.0 on, same minor version for 0.x);
- `:breaking`: a newer version is installed that is not compatible with the recorded one;
- `:older`: an older version is installed than the project was saved with;
- `:missing`: the package is not installed in the active environment.
"""
struct VersionCheck
    package::String
    recorded::Union{VersionNumber, Nothing}
    installed::Union{VersionNumber, Nothing}
    status::Symbol
end

"""
    check_versions(path; packages = Module[]) -> Vector{VersionCheck}

Compares the versions that the project file of the project in the folder `path` records (see
[`project_versions`](@ref)) with those of this session, one [`VersionCheck`](@ref) per package:

- BeamletOptics, BeamletOpticsProjects and the modules `packages` (e.g. the program that opens the
  project passes itself) with `pkgversion` against `[versions]`; the other entries of `[versions]`
  are not checked;
- every entry of `[packages]` with what the active environment would load for `using` (`:missing`
  if it does not have the package or has not installed it).

Checks only: nothing is loaded or installed, and [`load_project`](@ref) does not call it.
"""
function check_versions(path::AbstractString; packages::Vector{Module} = Module[])
    recorded = project_versions(path)
    out = VersionCheck[]
    for m in unique!(Module[BMO, @__MODULE__, packages...])
        name = string(nameof(m))
        rec = _version_or_nothing(get(recorded.versions, name, nothing))
        inst = _version_or_nothing(pkgversion(m))
        push!(out, VersionCheck(name, rec, inst, _version_status(rec, inst)))
    end
    for name in sort!(collect(keys(recorded.packages)))
        rec = _version_or_nothing(recorded.packages[name])
        found, inst = _installed_version(name)
        push!(out, VersionCheck(name, rec, inst, found ? _version_status(rec, inst) : :missing))
    end
    return out
end

# A `VersionNumber` of `v` (a string or a version), `nothing` if it is none
function _version_or_nothing(v)
    v isa VersionNumber && return v
    v isa AbstractString || return nothing
    return tryparse(VersionNumber, v)
end

# The status of a `VersionCheck` of an installed package, see `VersionCheck`
function _version_status(recorded, installed)
    (isnothing(recorded) || isnothing(installed)) && return :same
    installed == recorded && return :same
    installed < recorded && return :older
    return _compatible(recorded, installed) ? :newer : :breaking
end

# Whether `b` is compatible with `a` by semantic versioning: the same major version from 1.0 on,
# the same minor version for 0.x
_compatible(a::VersionNumber, b::VersionNumber) =
    a.major == b.major && (a.major ≥ 1 || a.minor == b.minor)

"""
Whether the active environment has the package `name` installed, and its version (`nothing` if it
is not known): of the module if it is loaded, else from the project file of Pkg of the installed
package. Loads nothing.
"""
function _installed_version(name::AbstractString)
    id = Base.identify_package(String(name))
    isnothing(id) && return (false, nothing)
    if Base.root_module_exists(id)
        return (true, _version_or_nothing(pkgversion(Base.root_module(id))))
    end
    entry = Base.locate_package(id)
    isnothing(entry) && return (false, nothing)
    root = dirname(dirname(entry))
    for f in Base.project_names
        file = joinpath(root, f)
        isfile(file) || continue
        v = try
            get(TOML.parsefile(file), "version", nothing)
        catch
            nothing
        end
        return (true, _version_or_nothing(v))
    end
    return (true, nothing)
end
