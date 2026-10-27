#=
Stamps: did someone else change the files of a project? The GUI and agents may work on a project at
the same time
=#

"""
    project_stamp(dir) -> String

A fingerprint of the files of the project in the folder `dir` that define the setup: `system.jl`
and every `.jl` file in `src/`, with their paths. It changes with any change of their content; the
GUI's own files (`view.toml`) do not count, nor do files and folders in `src/` whose name starts
with `.` (e.g. the `._X.jl` that macOS leaves on network drives).
"""
function project_stamp(dir::AbstractString)
    dir = abspath(dir)
    files = String[]
    isfile(joinpath(dir, "system.jl")) && push!(files, "system.jl")
    src = joinpath(dir, "src")
    if isdir(src)
        for (root, dirs, names) in walkdir(src)
            filter!(d -> !startswith(d, '.'), dirs)
            for f in names
                startswith(f, '.') && continue
                endswith(f, ".jl") && push!(files, relpath(joinpath(root, f), dir))
            end
        end
    end
    ctx = SHA.SHA1_CTX()
    for f in sort!(replace.(files, '\\' => '/'))
        SHA.update!(ctx, codeunits(f * "\0"))
        SHA.update!(ctx, read(joinpath(dir, f)))
        SHA.update!(ctx, codeunits("\0"))
    end
    return bytes2hex(SHA.digest!(ctx))
end

"""
    ProjectChanged(path)

The error of [`save_project`](@ref) when the files of the project in the folder `path` changed
since it was loaded or saved (see [`project_stamp`](@ref)), e.g. by an agent while the GUI was
open: saving would overwrite that change. `save_project(...; force = true)` saves anyway.
"""
struct ProjectChanged <: Exception
    path::String
end

Base.showerror(io::IO, e::ProjectChanged) =
    print(io, "ProjectChanged: the files of the project in \"", e.path, "\" changed since it was ",
        "loaded or saved; load it again, or save with force = true to overwrite the change")
