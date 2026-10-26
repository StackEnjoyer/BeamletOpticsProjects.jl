#=
New projects (being implemented)
=#

"""
    new_project(path; name = basename(path), packages = Module[]) -> Project

Creates a project in the folder `path`.
"""
function new_project(path::AbstractString; name::AbstractString = basename(abspath(path)),
        packages::Vector{Module} = Module[])
    error("new_project is not implemented yet")
end
