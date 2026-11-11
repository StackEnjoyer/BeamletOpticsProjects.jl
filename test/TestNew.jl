module TestNew

using BeamletOptics, BeamletOpticsProjects
using LibGit2, TOML
using Test

@testset "new_project" begin
    dir = joinpath(mktempdir(), "laser-bench")
    p = new_project(dir; packages = [TOML])
    @test p.name == "Laser_bench"
    for f in ("system.jl", "AGENTS.md", "CLAUDE.md", ".gitignore",
              joinpath("src", "Laser_bench.jl"), "laser-bench.bmo")
        @test isfile(joinpath(dir, f))
    end
    # No Julia environment in the folder: the project file is the only file of metadata
    @test !isfile(joinpath(dir, "Project.toml")) && !isfile(joinpath(dir, "Manifest.toml"))
    marker = joinpath(dir, "laser-bench.bmo")
    @test project_marker(dir) == marker
    data = TOML.parsefile(marker)
    @test data["format"] == 1 && data["name"] == "Laser_bench"
    @test data["versions"] == Dict("BeamletOptics" => string(pkgversion(BeamletOptics)),
        "BeamletOpticsProjects" => string(pkgversion(BeamletOpticsProjects)),
        "TOML" => string(pkgversion(TOML)))
    @test data["packages"] == Dict()
    text = read(marker, String)
    @test startswith(text, "# BeamletOptics project \"laser-bench\": open this file with BeamletOptics.\n")
    # The plain values, then [versions], then [packages]
    @test occursin(r"^format = 1\nname = \"Laser_bench\"\n\n\[versions\]\n.*\n\[packages\]"ms, text)
    # The project file opens the project; a renamed folder keeps its project file
    @test load_project(marker).path == dir
    @test project_dir(marker) == dir && project_dir(dir * "/") == dir
    moved = joinpath(dirname(dir), "renamed")
    mv(dir, moved)
    @test project_marker(moved) == joinpath(moved, "laser-bench.bmo")
    @test BeamletOpticsProjects.project_name(moved) == "Laser_bench"
    mv(moved, dir)
    @test project_marker(joinpath(dirname(dir), "new folder")) ==
          joinpath(dirname(dir), "new folder", "new folder.bmo")
    @test read(joinpath(dir, "CLAUDE.md"), String) == "@AGENTS.md\n"
    # The empty project loads, and its module is there
    q = load_project(dir)
    @test isempty(q.entries) && isempty(q.systems)
    @test isdefined(q.mod, :Laser_bench)
    @test_throws ArgumentError new_project(dir)
    @test_throws ArgumentError new_project(joinpath(mktempdir(), "x"); name = "not valid")
    # A folder with other files but without system.jl becomes a project
    other = mktempdir()
    write(joinpath(other, "notes.txt"), "x")
    @test new_project(other; name = "Other").name == "Other"
    @test read(joinpath(other, "notes.txt"), String) == "x"
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
    for m in ("BeamletOptics", "BeamletOpticsProjects")
        @test occursin("$m.install_agent_skill()", agents)
    end
    # the agent works without the GUI (BeamletOpticsProjects#3)
    @test !occursin("BeamletOpticsGUI.install_agent_skill()", agents)
    # in an environment of the agent's own, never one in the folder, changed only after asking
    env = match(r"## Environment\n(.*?)(\n## |\z)"s, agents).captures[1]
    @test occursin("environment of your own, without the GUI", env)
    @test occursin("@bmo-agent", env) && occursin("check_versions", env)
    @test occursin("Never guess a path", env) && occursin("only after the person agreed", env)
    @test !occursin("environment of the person", agents)
    # the own code of the project has no hint at code for the GUI
    @test !occursin("card_rows", read(joinpath(dir, "src", "Example.jl"), String))
    @test occursin("`[packages]` of `$(basename(dir)).bmo`", env)
    @test occursin("Never make this folder", env)
    @test !occursin("Project.toml", agents) && !occursin(".envs", agents)
    @test split(read(joinpath(dir, ".gitignore"), String), '\n') ==
          ["*.tmp", ".bmo/", ".claude/skills/", ""]
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
    code = match(r"## Check\n.*?```julia\n(.*?)```"s, agents).captures[1]
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
    # The installers are silent
    logs, _ = Test.collect_test_logs(() -> new_project(dir; name = "Example"))
    @test !any(l -> occursin("Installed", string(l.message)), logs)
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

@testset "a new project loads in an environment with only BeamletOptics and BeamletOpticsProjects" begin
    dir = joinpath(mktempdir(), "Bench")
    new_project(dir)
    # An environment of its own that has only the two packages, resolved as for the tests
    env = mktempdir()
    uuid(m) = string(Base.PkgId(m).uuid)
    write(joinpath(env, "Project.toml"), """
        [deps]
        BeamletOptics = "$(uuid(BeamletOptics))"
        BeamletOpticsProjects = "$(uuid(BeamletOpticsProjects))"
        """)
    manifest = read(Base.project_file_manifest_path(Base.active_project()), String)
    root = replace(pkgdir(BeamletOpticsProjects), '\\' => '/')
    write(joinpath(env, "Manifest.toml"), replace(manifest, "path = \".\"" => "path = \"$root\""))
    code = """
        using BeamletOptics, BeamletOpticsProjects
        p = load_project(ARGS[1])
        print(p.name, " ", isempty(p.entries), " ", Base.active_project())
        """
    # Without the default environment of the user
    sep = Sys.iswindows() ? ";" : ":"
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --project=$env -e $code $dir`,
        "JULIA_LOAD_PATH" => string("@", sep, "@stdlib"))
    @test read(cmd, String) == string("Bench true ", joinpath(env, "Project.toml"))
end

end
