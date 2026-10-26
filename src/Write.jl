#=
Writing system.jl (being implemented)
=#

"""
    system_code(project) -> String

The canonical text of `system.jl` of `project`.
"""
function system_code(p::Project)
    error("system_code is not implemented yet")
end

"""
    save_project(project; packages = Module[]) -> String
    save_project(project, path; packages = Module[]) -> String

Writes `system.jl` of `project` (to the folder `path`) and returns its path.
"""
function save_project(p::Project; packages::Vector{Module} = Module[])
    error("save_project is not implemented yet")
end

function save_project(p::Project, path::AbstractString; packages::Vector{Module} = Module[])
    p.path = abspath(path)
    return save_project(p; packages)
end
