"""
    install_agent_skill(dest = joinpath(pwd(), ".claude", "skills"))

Copies the agent skill that ships with the installed BeamletOpticsProjects version into
`joinpath(dest, "beamletopticsprojects")` and returns that path. The skill teaches AI coding
assistants (e.g. Claude Code) how to work on a project: the form of `system.jl`, loading, tracing
and reading it (`load_project`, `trace`, `look`), the open windows of the people, taking part and
versions.

The default `dest` is the project-level skill directory of Claude Code in the current working
directory. Use e.g. `joinpath(homedir(), ".claude", "skills")` for a personal installation.
[`new_project`](@ref) installs it, and the skill of BeamletOptics, into the new project.

An existing `beamletopticsprojects` skill in `dest` is replaced, so calling this function again
after `Pkg.update` keeps the skill in sync with the installed package version. Local edits to the
copy are lost.

!!! info "File permissions"
    Pkg installs packages read-only. The copied files are made writable so that the copy can be
    edited and replaced later.
"""
function install_agent_skill(dest::AbstractString = joinpath(pwd(), ".claude", "skills"))
    src = joinpath(pkgdir(@__MODULE__), "skills", "beamletopticsprojects")
    isdir(src) || throw(ErrorException("Agent skill not found at $src"))
    target = joinpath(dest, "beamletopticsprojects")
    mkpath(dest)
    # a read-only copy (as Pkg leaves it) can not be replaced on every OS: writable first
    isdir(target) && _make_writable(target)
    cp(src, target; force = true)
    _make_writable(target)
    @info "Installed BeamletOpticsProjects agent skill (v$(pkgversion(@__MODULE__))) to $target"
    return target
end

function _make_writable(dir)
    for (root, _, files) in walkdir(dir)
        chmod(root, 0o755)
        foreach(f -> chmod(joinpath(root, f), 0o644), files)
    end
    return nothing
end
