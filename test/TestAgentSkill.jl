module TestAgentSkill

using BeamletOptics, BeamletOpticsProjects
using Test

const SKILL_DIR = joinpath(@__DIR__, "..", "skills", "beamletopticsprojects")

@testset "Agent skill" begin
    @testset "API.md export table matches names(BeamletOpticsProjects)" begin
        api = read(joinpath(SKILL_DIR, "API.md"), String)
        table = split(split(api, "## Exported names")[2], "\n## ")[1]
        rows = filter(l -> startswith(l, "|") && !occursin(r"^\|\s*(Category|-)", l),
            split(table, '\n'))
        documented = Set{Symbol}()
        for row in rows, m in eachmatch(r"`(@?[A-Za-z_][A-Za-z0-9_!]*)`", split(row, '|')[3])
            push!(documented, Symbol(m.captures[1]))
        end
        exported = Set(filter(n -> n !== :BeamletOpticsProjects && Base.isexported(BeamletOpticsProjects, n),
            names(BeamletOpticsProjects)))
        @test isempty(setdiff(documented, exported))  # documented but not exported
        @test isempty(setdiff(exported, documented))  # exported but not documented
    end

    @testset "SKILL.md targets the current minor version" begin
        skill = read(joinpath(SKILL_DIR, "SKILL.md"), String)
        m = match(r"beamletopticsprojects-version:\s*\"(\d+)\.(\d+)\"", skill)
        @test m !== nothing
        v = pkgversion(BeamletOpticsProjects)
        @test parse.(Int, m.captures) == [v.major, v.minor]
    end

    @testset "SKILL.md covers taking part" begin
        skill = read(joinpath(SKILL_DIR, "SKILL.md"), String)
        section = match(r"## Taking part\n(.*?)\n## "s, skill).captures[1]
        for key in ("announce(", "leave(", "selected_id", "doing", "written")
            @test occursin(key, section)
        end
    end

    @testset "the example of FORMAT.md loads" begin
        format = read(joinpath(SKILL_DIR, "FORMAT.md"), String)
        example = match(r"```julia\n(@component.*?)```"s, format).captures[1]
        dir = mktempdir()
        write(joinpath(dir, "Project.toml"), "name = \"Example\"\n")
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "Example.jl"), "module Example\nend\n")
        write(joinpath(dir, "system.jl"), example)
        p = load_project(dir)
        @test [e.name for e in p.entries] == [:L1, :M1, :B1]
        @test p[:S1] isa System
    end

    @testset "install_agent_skill copies the shipped skill" begin
        mktempdir() do dest
            skill_md = joinpath(dest, "beamletopticsprojects", "SKILL.md")
            original = read(joinpath(SKILL_DIR, "SKILL.md"), String)

            path = @test_logs (:info, r"Installed BeamletOpticsProjects agent skill") BeamletOpticsProjects.install_agent_skill(dest)
            @test path == joinpath(dest, "beamletopticsprojects")
            @test read(skill_md, String) == original
            @test isfile(joinpath(path, "API.md"))
            @test isfile(joinpath(path, "FORMAT.md"))

            # a reinstall replaces an edited, read-only copy (as left behind by a read-only Pkg install)
            write(skill_md, "edited")
            for (root, _, files) in walkdir(path)
                foreach(f -> chmod(joinpath(root, f), 0o444), files)
            end
            @test_logs (:info,) BeamletOpticsProjects.install_agent_skill(dest)
            @test read(skill_md, String) == original
            @test uperm(skill_md) & 0x02 != 0   # writable again
        end
    end
end

end
