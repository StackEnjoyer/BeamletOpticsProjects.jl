module TestNew

using BeamletOptics, BeamletOpticsProjects
using LibGit2, TOML
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

@testset "AGENTS.md: only what is specific to the project" begin
    dir = mktempdir()
    new_project(dir; name = "Example")
    agents = read(joinpath(dir, "AGENTS.md"), String)
    # the generic parts are in the skill of the package
    @test !occursin("## The form of `system.jl`", agents)
    @test !occursin("## Taking part", agents)
    @test !occursin("## The open windows", agents)
    @test occursin("src/Example.jl", agents)
    # how to get the skills from the packages
    for m in ("BeamletOptics", "BeamletOpticsProjects", "BeamletOpticsGUI")
        @test occursin("$m.install_agent_skill()", agents)
    end
    # in the environment of the project, not the default one
    @test occursin("--project=.", agents)
    check = match(r"## Check\n(.*?)(\n## |\z)"s, agents).captures[1]
    for key in ("p = load_project(", "r = trace(p, :S1)", "r.detectors", "look(p)")
        @test occursin(key, check)
    end
end

@testset "AGENTS.md: the check runs" begin
    dir = mktempdir()
    new_project(dir; name = "Example")
    write(joinpath(dir, "system.jl"), """
        @component D1 = Detector(0.02) pos = (0.0, 0.1, 0.0)
        @source B1 = GaussianBeamlet([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6, 1.0e-3)
        @system S1 = [D1] sources = [B1]
        """)
    agents = read(joinpath(dir, "AGENTS.md"), String)
    code = match(r"## Check\n+```julia\n(.*?)```"s, agents).captures[1]
    m = Module()
    text = redirect_stdout(devnull) do
        cd(() -> include_string(m, code), dir)
    end
    @test text isa String && occursin("D1: hits 1", text)
    @test Core.eval(m, :(r.detectors[:D1].hits)) == 1
end

@testset "new_project installs the skills of the packages once" begin
    skill(dir, name) = joinpath(dir, ".claude", "skills", name, "SKILL.md")
    dir = mktempdir()
    @test_logs new_project(dir; name = "Example")   # silent
    @test read(skill(dir, "beamletoptics"), String) ==
          read(joinpath(pkgdir(BeamletOptics), "skills", "beamletoptics", "SKILL.md"), String)
    @test read(skill(dir, "beamletopticsprojects"), String) ==
          read(joinpath(pkgdir(BeamletOpticsProjects), "skills", "beamletopticsprojects", "SKILL.md"), String)
    # never in a version: .gitignore keeps them out, the settings of Claude Code are versioned
    @test ".claude/skills/" in split(read(joinpath(dir, ".gitignore"), String), '\n')
    LibGit2.with(LibGit2.GitRepo(dir)) do repo
        @test LibGit2.status(repo, ".claude/skills/beamletoptics/SKILL.md") &
              LibGit2.Consts.STATUS_IGNORED != 0
        @test LibGit2.status(repo, ".claude/settings.json") == LibGit2.Consts.STATUS_CURRENT
    end
    # a skill that is there already stays
    dir = mktempdir()
    mkpath(dirname(skill(dir, "beamletoptics")))
    write(skill(dir, "beamletoptics"), "mine")
    new_project(dir; name = "Example")
    @test read(skill(dir, "beamletoptics"), String) == "mine"
    @test isfile(skill(dir, "beamletopticsprojects"))
end

end
