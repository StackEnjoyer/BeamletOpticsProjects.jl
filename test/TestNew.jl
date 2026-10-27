module TestNew

using BeamletOptics, BeamletOpticsProjects
using TOML
using Test

@testset "new_project" begin
    dir = joinpath(mktempdir(), "laser-bench")
    p = new_project(dir; packages = [TOML])
    @test p.name == "Laser_bench"
    for f in ("Project.toml", "system.jl", "AGENTS.md", "CLAUDE.md", ".gitignore",
              joinpath("src", "Laser_bench.jl"), "laser-bench.bmo")
        @test isfile(joinpath(dir, f))
    end
    marker = joinpath(dir, "laser-bench.bmo")
    @test project_marker(dir) == marker
    @test TOML.parsefile(marker)["format"] == 1
    # The project file opens the project; a renamed folder keeps its project file
    @test load_project(marker).path == dir
    @test project_dir(marker) == dir && project_dir(dir * "/") == dir
    moved = joinpath(dirname(dir), "renamed")
    mv(dir, moved)
    @test project_marker(moved) == joinpath(moved, "laser-bench.bmo")
    mv(moved, dir)
    @test project_marker(joinpath(dirname(dir), "new folder")) ==
          joinpath(dirname(dir), "new folder", "new folder.bmo")
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

@testset "AGENTS.md: taking part" begin
    dir = mktempdir()
    new_project(dir; name = "Example")
    agents = read(joinpath(dir, "AGENTS.md"), String)
    section = match(r"## Taking part\n(.*?)\n## "s, agents).captures[1]
    for key in ("presence-<your name>@agent.toml", "kind = \"agent\"", "beat", "ttl = 600",
                "selected_id", "doing", "session-<your name>@agent.md", "delete it")
        @test occursin(key, section)
    end
    # the earlier "do not edit" rules make an exception for the agent's own files
    @test occursin(r"Do not edit it, except your own files"s, agents)
    @test occursin(r"do not\s+edit them \(your own `\*@agent` files are the exception"s, agents)
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
