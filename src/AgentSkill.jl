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
    Pkg installs packages read-only. The files are written anew instead of copied with their
    permissions, so that the copy can be edited and replaced later.
"""
function install_agent_skill(dest::AbstractString = joinpath(pwd(), ".claude", "skills"))
    src = joinpath(pkgdir(@__MODULE__), "skills", "beamletopticsprojects")
    isdir(src) || throw(ErrorException("Agent skill not found at $src"))
    target = joinpath(dest, "beamletopticsprojects")
    rm(target; force = true, recursive = true)
    _copy_contents(src, target)
    @info "Installed BeamletOpticsProjects agent skill (v$(pkgversion(@__MODULE__))) to $target"
    return target
end

# Copies the folder `src` to `dst` by the contents of its files: `cp` keeps the read-only
# permissions of an installed package, new files are writable
function _copy_contents(src, dst)
    for (root, _, files) in walkdir(src)
        dir = joinpath(dst, relpath(root, src))
        mkpath(dir)
        foreach(f -> write(joinpath(dir, f), read(joinpath(root, f))), files)
    end
    return nothing
end
