module TestStamp

using BeamletOptics, BeamletOpticsProjects
using Test

@testset "project_stamp" begin
    dir = mktempdir()
    new_project(dir; name = "Bench")
    s = project_stamp(dir)
    @test s == project_stamp(dir) && length(s) == 40
    # system.jl and src/ count, the files of the GUI do not
    write(joinpath(dir, "view.toml"), "x = 1\n")
    @test project_stamp(dir) == s
    write(joinpath(dir, "src", "Extra.jl"), "f() = 1\n")
    s2 = project_stamp(dir)
    @test s2 != s
    write(joinpath(dir, "system.jl"), read(joinpath(dir, "system.jl"), String) * "# comment\n")
    @test project_stamp(dir) != s2
end

@testset "project_stamp ignores dotfiles in src" begin
    dir = mktempdir()
    new_project(dir; name = "Bench")
    s = project_stamp(dir)
    write(joinpath(dir, "src", "._Bench.jl"), "garbage\0")
    mkpath(joinpath(dir, "src", ".hidden"))
    write(joinpath(dir, "src", ".hidden", "X.jl"), "f() = 1\n")
    @test project_stamp(dir) == s
    write(joinpath(dir, "src", "Extra.jl"), "f() = 1\n")
    @test project_stamp(dir) != s
end

@testset "save_project checks the stamp" begin
    dir = mktempdir()
    new_project(dir; name = "Bench")
    lens = "@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)\n"
    write(joinpath(dir, "system.jl"), lens)
    p = load_project(dir)
    @test p.stamp == project_stamp(dir)
    # unchanged on disk: saved, and the stamp follows
    save_project(p)
    @test p.stamp == project_stamp(dir)
    # an agent changes the file: not saved, nothing written
    agent = lens * "@component L2 = SphericalLens(0.1, -0.1, 0.005, 0.0254, 1.5)\n"
    write(joinpath(dir, "system.jl"), agent)
    err = try
        save_project(p)
        nothing
    catch e
        e
    end
    @test err isa ProjectChanged && err.path == dir
    @test occursin("changed since it was loaded or saved", sprint(showerror, err))
    @test read(joinpath(dir, "system.jl"), String) == agent
    # also a change of the own code
    q = load_project(dir)
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nend\n")
    @test_throws ProjectChanged save_project(q)
    # force overwrites
    save_project(p; force = true)
    @test !occursin("L2", read(joinpath(dir, "system.jl"), String))
    @test p.stamp == project_stamp(dir)
    # saving to another folder does not check
    other = mktempdir()
    write(joinpath(dir, "system.jl"), agent)
    save_project(p, other)
    @test p.path == other && p.stamp == project_stamp(other)
    # a project built in memory has no stamp and is not checked
    m = Project(dir, "Bench")
    @test isnothing(m.stamp)
    save_project(m)
    @test m.stamp == project_stamp(dir)
end

end
