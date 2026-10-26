module TestNew

using BeamletOptics, BeamletOpticsProjects
using TOML
using Test

@testset "new_project" begin
    dir = joinpath(mktempdir(), "laser-bench")
    p = new_project(dir; packages = [TOML])
    @test p.name == "Laser_bench"
    for f in ("Project.toml", "system.jl", "AGENTS.md", "CLAUDE.md", ".gitignore",
              joinpath("src", "Laser_bench.jl"))
        @test isfile(joinpath(dir, f))
    end
    toml = TOML.parsefile(joinpath(dir, "Project.toml"))
    @test toml["name"] == "Laser_bench"
    @test toml["beamletoptics"]["format"] == 1
    @test toml["deps"]["BeamletOptics"] == string(Base.PkgId(BeamletOptics).uuid)
    @test toml["compat"]["BeamletOptics"] == "= $(pkgversion(BeamletOptics))"
    @test toml["compat"]["BeamletOpticsProjects"] == "= $(pkgversion(BeamletOpticsProjects))"
    @test haskey(toml["deps"], "TOML")
    @test read(joinpath(dir, "CLAUDE.md"), String) == "@AGENTS.md\n"
    # The empty project loads, and its module is there
    q = load_project(dir)
    @test isempty(q.entries) && isempty(q.systems)
    @test isdefined(q.mod, :Laser_bench)
    @test_throws ArgumentError new_project(dir)
    @test_throws ArgumentError new_project(joinpath(mktempdir(), "x"); name = "not valid")
end

@testset "AGENTS.md example loads" begin
    dir = mktempdir()
    new_project(dir; name = "Example")
    agents = read(joinpath(dir, "AGENTS.md"), String)
    example = match(r"```julia\n(@component.*?)```"s, agents).captures[1]
    write(joinpath(dir, "system.jl"), example)
    p = load_project(dir)
    @test [e.name for e in p.entries] == [:L1, :M1, :B1]
    @test p[:S1] isa System
end

end
