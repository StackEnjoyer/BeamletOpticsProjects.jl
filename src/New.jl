#=
New projects: the folder, the project file with the versions, the own module and the instructions
for agents
=#

"""
    new_project(path; name, packages = Module[]) -> Project

Creates an empty project in the folder `path`:

- the project file `<folder name>.bmo`, by which people open it (see [`project_marker`](@ref)),
  with the module name `name` (by default from the folder, see [`module_name`](@ref)), `format`
  and the versions (`[versions]`) of BeamletOptics, BeamletOpticsProjects and the modules
  `packages` (e.g. BeamletOpticsGUI); the folder is no Julia environment: a project is opened from
  any environment that has these packages;
- `src/<name>.jl` with the module `<name>` for own code;
- `system.jl` without entries;
- `AGENTS.md` and `CLAUDE.md` with the instructions for agents that are specific to the project,
  `.gitignore` and `.claude/settings.json`, whose hook shows `.bmo/session*.md` (the selection and
  the recent actions in every open GUI window) to Claude Code with every prompt when Claude Code is
  started in the project folder;
- the agent skills of the installed BeamletOptics and BeamletOpticsProjects in `.claude/skills/`
  (see `install_agent_skill` of both), which `.gitignore` keeps out of the versions: they come
  from the installed packages.

Then saves the first version, "New project", see [`save_version`](@ref): in the git repository
that holds the folder, else in a new one in the folder.

Throws if `path` is a project already (it has a `system.jl`).
"""
function new_project(path::AbstractString; name::AbstractString = module_name(path),
        packages::Vector{Module} = Module[])
    path = abspath(path)
    isfile(joinpath(path, "system.jl")) &&
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
    write_new(joinpath("src", name * ".jl"), _module_template(name))
    write_new("AGENTS.md", _agents_template(name, basename(project_marker(path))))
    write_new("CLAUDE.md", "@AGENTS.md\n")
    write_new(".gitignore", "*.tmp\n.bmo/\n.claude/skills/\n")
    mkpath(joinpath(path, ".claude"))
    write_new(joinpath(".claude", "settings.json"), _claude_settings())
    _install_skills(joinpath(path, ".claude", "skills"))
    _update_marker(path, name, packages)
    return nothing
end

"""
Installs the agent skills of BeamletOptics and BeamletOpticsProjects into `dest`, each only if it
is not there yet, without their messages. BeamletOptics 0.14.0 makes its copy writable with
`chmod` after the files are copied, which a network drive on Windows refuses: then the copy stays
as it is (drop the `try` once BeamletOptics writes the files anew, as `install_agent_skill` here).
"""
function _install_skills(dest)
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        bmo = joinpath(dest, "beamletoptics")
        if !isdir(bmo)
            try
                BMO.install_agent_skill(dest)
            catch e
                (e isa Base.IOError && isfile(joinpath(bmo, "SKILL.md"))) || rethrow()
            end
        end
        isdir(joinpath(dest, "beamletopticsprojects")) || install_agent_skill(dest)
    end
    return nothing
end

_module_template(name) = """
    module $name

    # Own code of the project: functions that build components or groups, own component types,
    # their `card_rows` for the GUI, ... Everything exported here can be used in `system.jl`.
    using BeamletOptics

    end
    """

_agents_template(name, marker) = """
    # Project $name (BeamletOptics)

    An optical setup of [BeamletOptics](https://github.com/StackEnjoyer/BeamletOptics.jl) as a
    project of BeamletOpticsProjects. People change it in the GUI (BeamletOpticsGUI), agents in the
    code, at the same time.

    ## Skills

    How to work on a project (the form of `system.jl`, `load_project`, `trace`, `look`, the open
    windows, taking part, versions) is in the agent skill `beamletopticsprojects`, the optics in
    `beamletoptics`, the window in `beamletopticsgui`. They come from the installed packages and lie
    in `.claude/skills/` (not part of the versions). Read them before you change the project. If
    one is missing or the packages were updated, install them again from the packages, in this
    folder and in the environment of the person (see "Environment"):

    ```julia
    using BeamletOptics, BeamletOpticsProjects
    BeamletOptics.install_agent_skill()
    BeamletOpticsProjects.install_agent_skill()
    using BeamletOpticsGUI; BeamletOpticsGUI.install_agent_skill()   # if the GUI is installed
    ```

    ## Report on the tools

    At the start of the work, ask the person once whether you should keep a report on where
    BeamletOptics, BeamletOpticsProjects and BeamletOpticsGUI got in your way and what you would
    have needed (see "Report on the tools" in the skill `beamletopticsprojects`). Agents' reports
    are how these packages become easier to use for agents.

    ## Files

    - `system.jl`: the setup, one line per component, source and system.
    - `src/$name.jl`: own code (module `$name`): functions that build components or groups, own
      types. Its exported names can be used in `system.jl`. The GUI never writes it.
    - `$marker`: the project file that people open. It records the module name, the newest
      versions the project was saved with (`[versions]`) and the packages that `src/` uses
      (`[packages]`); the saves write it, do not edit it.
    - `view.toml`, `.bmo/`: belong to the windows, see the skill `beamletopticsprojects`.

    ## Environment

    Run Julia in the environment of the person you work for (ask them); it has BeamletOptics,
    BeamletOpticsProjects and the packages under `[packages]` of `$marker`. Never make this folder
    a Julia environment (no `--project=.`, no `Pkg.activate(".")`, no file of Pkg in it).

    ## Check

    ```julia
    using BeamletOptics, BeamletOpticsProjects
    p = load_project(".")   # throws with the line of system.jl on errors
    r = trace(p, :S1)       # solves the system S1 with its sources
    r.detectors             # hits and power of each detector of S1
    look(p)                 # the setup as text: versions, chains of ids, distances, detectors, participants
    ```
    """

# The order of the keys of the project file: the plain values first, then `[versions]`, then
# `[packages]`, else by name
_marker_order(k) = (k == "versions" ? 1 : k == "packages" ? 2 : 0, k)

"""
The text of the project file `file` with the content `data`: a comment line for people who open it
in an editor, then `data` as TOML, see [`project_marker`](@ref).
"""
function _marker_text(file, data::AbstractDict)
    io = IOBuffer()
    println(io, "# BeamletOptics project \"", splitext(basename(file))[1],
        "\": open this file with BeamletOptics.")
    TOML.print(io, data; sorted = true, by = _marker_order)
    return String(take!(io))
end
