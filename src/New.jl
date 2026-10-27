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
- `AGENTS.md` and `CLAUDE.md` with the instructions for agents that are specific to the project,
  `.gitignore` and `.claude/settings.json`, whose hook shows `.bmo/session*.md` (the selection and
  the recent actions in every open GUI window) to Claude Code with every prompt when Claude Code is
  started in the project folder;
- the agent skills of the installed BeamletOptics and BeamletOpticsProjects in `.claude/skills/`
  (see `install_agent_skill` of both), which `.gitignore` keeps out of the versions: they come
  from the packages in the versions the project pins;
- the project file `<folder name>.bmo`, by which people open it, see [`project_marker`](@ref).

Then saves the first version, "New project", see [`save_version`](@ref): in the git repository
that holds the folder, else in a new one in the folder.

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
    _first_version(path)
    return p
end

"""
Saves the first version of a new project; warns instead of throwing if that is not possible (e.g.
changes outside the folder are staged in the repository that holds it).
"""
function _first_version(path)
    try
        save_version(path; message = "New project")
    catch e
        e isa Union{ArgumentError, LibGit2.GitError} || rethrow()
        @warn "The first version of the project at \"$path\" was not saved" exception = e
    end
    return nothing
end

"""The command of the hook of Claude Code that shows every `.bmo/session*.md` with every prompt."""
const _SESSION_HOOK = raw"""cat "$CLAUDE_PROJECT_DIR"/.bmo/session*.md 2>/dev/null || true"""

_claude_settings() = """
    {
      "hooks": {
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "$(replace(_SESSION_HOOK, '"' => "\\\""))"
              }
            ]
          }
        ]
      }
    }
    """

"""Writes the files of a new project except `system.jl`; never overwrites one."""
function _scaffold(path, name, packages)
    mkpath(joinpath(path, "src"))
    write_new(file, text) = isfile(joinpath(path, file)) || write(joinpath(path, file), text)
    write_new("Project.toml", _project_toml(name, packages))
    write_new(joinpath("src", name * ".jl"), _module_template(name))
    write_new("AGENTS.md", _agents_template(name))
    write_new("CLAUDE.md", "@AGENTS.md\n")
    write_new(".gitignore", "Manifest.toml\n*.tmp\n.bmo/\n.claude/skills/\n")
    mkpath(joinpath(path, ".claude"))
    write_new(joinpath(".claude", "settings.json"), _claude_settings())
    _install_skills(joinpath(path, ".claude", "skills"))
    marker = project_marker(path)
    isfile(marker) || write(marker, _marker_text(splitext(basename(marker))[1]))
    return nothing
end

"""
Installs the agent skills of BeamletOptics and BeamletOpticsProjects into `dest`, each only if it
is not there yet, without their messages.
"""
function _install_skills(dest)
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        isdir(joinpath(dest, "beamletoptics")) || BMO.install_agent_skill(dest)
        isdir(joinpath(dest, "beamletopticsprojects")) || install_agent_skill(dest)
    end
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

    An optical setup of [BeamletOptics](https://github.com/JuliaPhysics/BeamletOptics.jl) as a
    project of BeamletOpticsProjects. People change it in the GUI (BeamletOpticsGUI), agents in the
    code, at the same time.

    ## Skills

    How to work on a project (the form of `system.jl`, `load_project`, `trace`, `look`, the open
    windows, taking part, versions) is in the agent skill `beamletopticsprojects`, the optics in
    `beamletoptics`, the window in `beamletopticsgui`. They come from the installed packages, in the
    versions this project pins (`Project.toml`), and lie in `.claude/skills/` (not part of the
    versions). Read them before you change the project. If one is missing or the packages were
    updated, install them again from the packages, in this folder and in the environment of this
    project (`julia --project=.`, which loads the versions it pins):

    ```julia
    using BeamletOptics, BeamletOpticsProjects
    BeamletOptics.install_agent_skill()
    BeamletOpticsProjects.install_agent_skill()
    using BeamletOpticsGUI; BeamletOpticsGUI.install_agent_skill()   # if the GUI is installed
    ```

    ## Files

    - `system.jl`: the setup, one line per component, source and system.
    - `src/$name.jl`: own code (module `$name`): functions that build components or groups, own
      types. Its exported names can be used in `system.jl`. The GUI never writes it.
    - `view.toml`, `*.bmo`, `.bmo/`: belong to the windows, see the skill `beamletopticsprojects`.
    - `Project.toml`: the versions this project was made with (`[compat]`).

    ## Check

    ```julia
    using BeamletOptics, BeamletOpticsProjects
    p = load_project(".")   # throws with the line of system.jl on errors
    r = trace(p, :S1)       # solves the system S1 with its sources
    r.detectors             # hits and power of each detector of S1
    look(p)                 # the setup as text: chains of ids, distances, detectors, participants
    ```
    """

_marker_text(name) = """
    # BeamletOptics project "$name": open this file with BeamletOptics.
    # The project is the folder of this file (system.jl, src/, view.toml, ...), see AGENTS.md.
    format = $FORMAT
    """
