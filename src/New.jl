#=
New projects: the folder, Project.toml with the versions, the own module and the instructions for agents
=#

"""
    new_project(path; name, packages = Module[]) -> Project

Creates an empty project in the folder `path`:

- `Project.toml` with the module name `name` (by default from the folder), a new uuid,
  `[beamletoptics] format` and the exact versions (`[compat]`, `= x.y.z`) of BeamletOptics,
  BeamletOpticsProjects and the modules `packages` (e.g. BeamletOpticsGUI, GLMakie);
- `src/<name>.jl` with the module `<name>` for own code;
- `system.jl` without entries;
- `AGENTS.md` and `CLAUDE.md` with the instructions for agents, and `.gitignore`;
- the project file `<folder name>.bmo`, by which people open it, see [`project_marker`](@ref).

Throws if `path` is a project already.
"""
function new_project(path::AbstractString; name::AbstractString = module_name(path),
        packages::Vector{Module} = Module[])
    path = abspath(path)
    isfile(joinpath(path, "Project.toml")) &&
        throw(ArgumentError("\"$path\" is a project already"))
    Base.isidentifier(name) || throw(ArgumentError("the name \"$name\" is not a valid module name"))
    _scaffold(path, String(name), packages)
    p = Project(path, name)
    _write_atomic(project_file(p, "system.jl"), system_code(p))
    return p
end

"""Writes the files of a new project except `system.jl`; never overwrites one."""
function _scaffold(path, name, packages)
    mkpath(joinpath(path, "src"))
    write_new(file, text) = isfile(joinpath(path, file)) || write(joinpath(path, file), text)
    write_new("Project.toml", _project_toml(name, packages))
    write_new(joinpath("src", name * ".jl"), _module_template(name))
    write_new("AGENTS.md", _agents_template(name))
    write_new("CLAUDE.md", "@AGENTS.md\n")
    write_new(".gitignore", "Manifest.toml\n*.tmp\n")
    marker = project_marker(path)
    isfile(marker) || write(marker, _marker_text(splitext(basename(marker))[1]))
    return nothing
end

function _project_toml(name, packages)
    mods = unique([BMO, @__MODULE__, packages...])
    deps = Dict{String, Any}()
    compat = Dict{String, Any}()
    for m in mods
        id = Base.PkgId(m)
        id.uuid === nothing && throw(ArgumentError("$m is not a package"))
        deps[id.name] = string(id.uuid)
        v = pkgversion(m)
        v === nothing || (compat[id.name] = "= $v")
    end
    compat["julia"] = string(VERSION.major, ".", VERSION.minor)
    io = IOBuffer()
    println(io, "name = ", repr(name))
    println(io, "uuid = \"", uuid4(), "\"")
    println(io, "version = \"0.1.0\"")
    println(io)
    TOML.print(io, Dict{String, Any}("deps" => deps, "compat" => compat,
        "beamletoptics" => Dict{String, Any}("format" => FORMAT)); sorted = true)
    return String(take!(io))
end

_module_template(name) = """
    module $name

    # Own code of the project: functions that build components or groups, own component types,
    # their `card_rows` for the GUI, ... Everything exported here can be used in `system.jl`.
    using BeamletOptics

    end
    """

_agents_template(name) = """
    # Project $name (BeamletOptics)

    An optical setup of [BeamletOptics](https://github.com/JuliaPhysics/BeamletOptics.jl), saved by
    the GUI (BeamletOpticsGUI) or written by an agent. People change it in the GUI, agents in the code.

    ## Files

    - `system.jl`: the setup. The GUI rewrites it on every save; agents may edit it in the form below.
    - `src/$name.jl`: own code (module `$name`): functions that build components or groups, own types.
      Its exported names can be used in `system.jl`. The GUI never writes it.
    - `view.toml`: view state of the GUI (camera, colors, clip planes). Do not edit it.
    - `*.bmo`: the project file that people open; it only marks the folder. Do not edit it.
    - `Project.toml`: the versions this project was made with (`[compat]`).

    ## The form of `system.jl`

    One line per entry; components first, then sources, then systems:

    ```julia
    @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, λ -> 1.5) pos = (0.0, 0.1, 0.0)
    @component M1 = RightAnglePrismMirror(0.025, 0.025) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 90.0)
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6) pos = (0.0, -0.05, 0.0)
    @system S1 = [L1, M1] sources = [B1]
    ```

    - The name after `@component`/`@source`/`@system` is the readable **id** (`L1`, `M2`, `D3`, `BS1`, `B1`,
      `S1`: a prefix of the family and a number). It is unique and stays; never rename an id. Give a new
      line the next free number of its prefix.
    - `label = "…"` is the name that people see and change in the GUI; optional.
    - `uid = "…"` (always last) is the machine id by which the GUI recognizes the line. Never change or
      copy it; a new line has no `uid`, it gets one when the GUI saves.
    - The right-hand side is any expression that builds a BeamletOptics component, group or source,
      also a call of a function of `src/$name.jl`. SI units: m, wavelengths in m.
    - `pos` is the absolute position (m), `rot` the rotation since construction in degrees: first
      about the global x-axis, then y, then z. Both are optional.
    - `catalog = (...)` belongs to the GUI (its page "Edit"); delete it when you change the constructor.
    - `@system`: members are components; a component may be in several systems, a source in at most
      one. `static = true` makes a `StaticSystem`.

    ## Working while the GUI is open

    The GUI may have the project open. It reloads `system.jl` and `src/` when they change, and it never
    overwrites them silently: if both changed, it asks the person. So write `system.jl` in one go (not
    line by line over minutes), and if a save of yours fails with `ProjectChanged`, load the project
    again instead of forcing it.

    ## Check

    ```julia
    using BeamletOptics, BeamletOpticsProjects
    p = load_project(".")   # throws with the line of system.jl on errors
    ```
    """

_marker_text(name) = """
    # BeamletOptics project "$name": open this file with BeamletOptics.
    # The project is the folder of this file (system.jl, src/, view.toml, ...), see AGENTS.md.
    format = $FORMAT
    """
