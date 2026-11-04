#=
The package environment of each person and machine in a project folder: `.envs/<id>/`, a plain Pkg
environment that has the project by path (see `personal_environment!`). Nothing here replaces Pkg:
it only writes the `Project.toml` of that environment and lets Pkg resolve and install it.
=#

"""
    personal_environment!(dir = "."; name = person().id) -> String

Makes or updates the package environment of this person and machine in the project folder `dir`,
`<dir>/.envs/<name>/` (`name` like `"hugo@PC12"`, see [`person`](@ref)), and returns its path, for
`julia --project=<path>`. It is a plain Pkg environment, whose `Project.toml` holds

- the project itself, by `[sources] path = "../.."`, so the own code of `src/<Name>.jl` comes from
  the project folder;
- the `[deps]`, `[compat]` and `[sources]` of the project's `Project.toml`: Julia loads with
  `using` only the direct dependencies of the active environment (else it looks into the default
  environment and may load another version), and a package that is not registered resolves only
  with its source. The project's entries win, except a `path` source of the environment (e.g.
  a `Pkg.develop` of this person), and entries that only the environment has stay (e.g. `Revise`);

then `Pkg.resolve()` and `Pkg.instantiate()` run in it. Pkg writes only into this folder, so the
packages of another person or machine never change. Call it again when the packages of the
project changed (an open window says so); `] add`, `] dev` and `] up` in the environment work as
usual and affect only it. The active project of the session stays as it is.

```julia
env = personal_environment!(".")      # then: julia --project=<env>
```
"""
function personal_environment!(dir::AbstractString = "."; name::AbstractString = person().id)
    dir = project_dir(dir)
    project = TOML.parsefile(joinpath(dir, "Project.toml"))
    pname, puuid = get(project, "name", nothing), get(project, "uuid", nothing)
    (pname isa AbstractString && puuid isa AbstractString) ||
        throw(ArgumentError("the Project.toml of \"$dir\" has no name and uuid"))
    env = joinpath(dir, ".envs", _env_folder(name))
    file = joinpath(env, "Project.toml")
    own = isfile(file) ? TOML.parsefile(file) : Dict{String, Any}()
    toml = _personal_project(own, project, String(pname), String(puuid))
    if toml != own
        mkpath(env)
        open(io -> TOML.print(io, toml; sorted = true), file, "w")
    end
    Pkg.activate(env) do
        Pkg.resolve()
        Pkg.instantiate()
    end
    return env
end

# The name of the folder of a person and machine: characters outside `[A-Za-z0-9_.@-]` become `_`
_env_folder(name) = replace(String(name), r"[^A-Za-z0-9_.@-]" => "_")

# The `Project.toml` of a personal environment: `own` (as it is) with the deps, compat and sources of
# the `project` and the project itself by path, see `personal_environment!`
function _personal_project(own::AbstractDict, project::AbstractDict, pname::String, puuid::String)
    out = deepcopy(Dict{String, Any}(own))
    for key in ("deps", "compat")
        merge!(get!(out, key, Dict{String, Any}()), get(project, key, Dict{String, Any}()))
    end
    out["deps"][pname] = puuid
    sources = get!(out, "sources", Dict{String, Any}())
    for (k, v) in get(project, "sources", Dict{String, Any}())
        mine = get(sources, k, nothing)
        # a package that this person develops stays theirs
        mine isa AbstractDict && haskey(mine, "path") && continue
        sources[k] = _from_envs(v)
    end
    sources[pname] = Dict{String, Any}("path" => "../..")
    return out
end

# A source of the project as seen from `.envs/<name>/`: a relative `path` is two folders deeper
function _from_envs(v)
    v isa AbstractDict || return v
    p = get(v, "path", nothing)
    (p isa AbstractString && !isabspath(p)) || return v
    return merge(v, Dict{String, Any}("path" => replace(joinpath("..", "..", p), '\\' => '/')))
end
