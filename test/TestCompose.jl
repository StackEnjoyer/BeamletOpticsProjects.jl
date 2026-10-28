module TestCompose

using BeamletOptics, BeamletOpticsProjects
using BeamletOpticsProjects: compose
using Test

const P = BeamletOpticsProjects

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
lens(id, y; uid = lowercase(String(id))) = "@component $id = $LENS pos = (0.0, $y, 0.0) uid = \"$uid\""
beam(id, y = 0.0) = "@source $id = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6) pos = (0.0, $y, 0.0) uid = \"$(lowercase(String(id)))\""
group(id, members, y) = "@group $id = [$(join(members, ", "))] pos = (0.0, $y, 0.0) uid = \"$(lowercase(String(id)))\""
sys(id, members, sources = Symbol[]) =
    "@system $id = [$(join(members, ", "))]" *
    (isempty(sources) ? "" : " sources = [$(join(sources, ", "))]") * " uid = \"$(lowercase(String(id)))\""

"""A project loaded from a new folder with the `lines` of its `system.jl`."""
function project(lines...)
    dir = joinpath(mktempdir(), "Bench")
    mkpath(dir)
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), join(lines, "\n") * "\n")
    return load_project(dir)
end

entry(p, id) = only(e for e in p.entries if e.name === id)
y(p, id) = entry(p, id).pos[2]
system(p, id) = only(s for s in p.systems if s.name === id)
grp(p, id) = only(g for g in p.groups if g.name === id)

@testset "compose" begin
    @testset "theirs at the keys, mine elsewhere" begin
        base = project(lens(:L1, 0.1), lens(:M1, 0.2), lens(:D1, 0.3), beam(:B1), sys(:S1, [:L1, :M1, :D1], [:B1]))
        mine = project(lens(:L1, 0.15), lens(:M1, 0.25), lens(:D1, 0.3), beam(:B1), sys(:S1, [:L1, :M1, :D1], [:B1]))
        theirs = project(lens(:L1, 0.12), lens(:M1, 0.2), lens(:D1, 0.35), beam(:B1), sys(:S1, [:L1, :M1, :D1], [:B1]))
        before = system_code(mine)
        r = compose(base, mine, theirs, ["l1"])
        @test r.keys == ["l1"]
        @test y(r.project, :L1) == 0.12 && y(r.project, :M1) == 0.25 && y(r.project, :D1) == 0.3
        @test system(r.project, :S1).members == [:L1, :M1, :D1]
        @test system_code(mine) == before
        # No keys: mine; all keys: theirs
        @test system_code(compose(base, mine, theirs, String[]).project) == before
        all = ["l1", "m1", "d1", "b1", "s1"]
        @test system_code(compose(base, mine, theirs, all).project) == system_code(theirs)
        # The folder, name and stamp of mine: a save checks the files
        @test r.project.path == mine.path && r.project.stamp == mine.stamp
        save_project(r.project)
        @test y(load_project(mine.path), :L1) == 0.12
        stale = compose(base, mine, theirs, ["d1"]).project
        @test_throws ProjectChanged save_project(stale)
    end

    @testset "removed and added at the keys" begin
        base = project(lens(:L1, 0.1), lens(:M1, 0.2), beam(:B1), sys(:S1, [:L1, :M1], [:B1]))
        mine = project(lens(:L1, 0.1), lens(:M1, 0.25), beam(:B1), sys(:S1, [:L1, :M1], [:B1]))
        theirs = project(lens(:M1, 0.2), lens(:L2, 0.4), beam(:B1), sys(:S1, [:M1, :L2], [:B1]))
        # L1 removed by theirs, the system of mine without it
        r = compose(base, mine, theirs, ["l1"])
        @test [e.name for e in r.project.entries] == [:M1, :B1]
        @test system(r.project, :S1).members == [:M1]
        @test y(r.project, :M1) == 0.25
        # L2 added by theirs, the system of theirs with M1 of mine
        r = compose(base, mine, theirs, ["l1", "l2", "s1"])
        @test Set(e.name for e in r.project.entries) == Set([:M1, :L2, :B1])
        @test system(r.project, :S1).members == [:M1, :L2]
        @test y(r.project, :M1) == 0.25
    end

    @testset "the tree rule widens the keys to a system" begin
        lines = (lens(:L1, 0.1), lens(:M1, 0.2), lens(:D1, 0.3), beam(:B1))
        base = project(lines..., sys(:S1, [:L1, :M1, :D1], [:B1]))
        mine = project(lens(:L1, 0.15), lines[2:end]..., sys(:S1, [:L1, :M1, :D1], [:B1]))
        theirs = project(lines..., group(:G1, [:L1, :M1], 0.15), sys(:S1, [:G1, :D1], [:B1]))
        r = compose(base, mine, theirs, ["g1"])
        @test r.keys == ["g1", "s1"]
        @test grp(r.project, :G1).members == [:L1, :M1]
        @test system(r.project, :S1).members == [:G1, :D1]
        # the group of theirs holds the lens of mine
        @test y(r.project, :L1) == 0.15
        # the other way: the group stays in mine, theirs ungrouped at the system
        r = compose(base, theirs, mine, ["s1"])
        @test r.keys == ["g1", "s1"]
        @test isempty(r.project.groups)
        @test system(r.project, :S1).members == [:L1, :M1, :D1]
        @test y(r.project, :L1) == 0.1
    end

    @testset "an entry in two groups widens the keys to the other group" begin
        lines = (lens(:L1, 0.1), lens(:M1, 0.2), lens(:D1, 0.3), beam(:B1))
        base = project(lines..., group(:G1, [:L1, :M1], 0.15), sys(:S1, [:G1, :D1], [:B1]))
        mine = base
        theirs = project(lines..., group(:G1, [:L1], 0.1), group(:G2, [:M1, :D1], 0.25), sys(:S1, [:G1, :G2], [:B1]))
        r = compose(base, mine, theirs, ["g2"])
        @test r.keys == ["g1", "g2", "s1"]
        @test system_code(r.project) == system_code(theirs)
    end

    @testset "the source rule widens the keys to the other system" begin
        lines = (lens(:L1, 0.1), lens(:M1, 0.2), beam(:B1))
        base = project(lines..., sys(:S1, [:L1, :M1], [:B1]))
        mine = project(lines..., sys(:S1, [:L1, :M1], [:B1]))
        theirs = project(lines..., sys(:S1, [:L1, :M1]), sys(:S2, [:M1], [:B1]))
        r = compose(base, mine, theirs, ["s2"])
        @test r.keys == ["s1", "s2"]
        @test isempty(system(r.project, :S1).sources)
        @test system(r.project, :S2).sources == [:B1]
    end

    @testset "a readable id of mine that stays: the next free one" begin
        base = project(lens(:L1, 0.1), beam(:B1))
        mine = project(lens(:L1, 0.1), lens(:L2, 0.2; uid = "mine-l2"), beam(:B1))
        theirs = project(lens(:L1, 0.1), lens(:L2, 0.3; uid = "their-l2"), beam(:B1))
        r = compose(base, mine, theirs, ["their-l2"])
        @test y(r.project, :L2) == 0.2
        @test only(e for e in r.project.entries if e.uid == "their-l2").name === :L3
        # replaced at the same key: no new id
        r = compose(base, mine, theirs, ["their-l2", "mine-l2"])
        @test only(e for e in r.project.entries if e.uid == "their-l2").name === :L2
        @test !any(e -> e.uid == "mine-l2", r.project.entries)
    end

    @testset "the places of an entry in conflict come with it (F18)" begin
        # (a) mine removed L2 (also from S1) and added L5 to S1, theirs moved L2
        base = project(lens(:L1, 0.1), lens(:L2, 0.2), beam(:B1), sys(:S1, [:L1, :L2], [:B1]))
        mine = project(lens(:L1, 0.1), lens(:L5, 0.5), beam(:B1), sys(:S1, [:L1, :L5], [:B1]))
        theirs = project(lens(:L1, 0.1), lens(:L2, 0.25), beam(:B1), sys(:S1, [:L1, :L2], [:B1]))
        r = compose(base, mine, theirs, ["l2"])
        @test r.keys == ["l2"]
        @test y(r.project, :L2) == 0.25
        @test Set(system(r.project, :S1).members) == Set([:L1, :L2, :L5])
        # (b) theirs removed L1 (also from S1), mine moved L1 and added L5 to S1
        mine = project(lens(:L1, 0.15), lens(:L2, 0.2), lens(:L5, 0.5), beam(:B1), sys(:S1, [:L1, :L2, :L5], [:B1]))
        theirs = project(lens(:L2, 0.2), beam(:B1), sys(:S1, [:L2], [:B1]))
        r = compose(base, mine, theirs, ["l1"])
        @test !any(e -> e.name === :L1, r.project.entries)
        @test system(r.project, :S1).members == [:L2, :L5]
        # moved into another system by theirs: there, and no longer in the one of mine
        base = project(lens(:L1, 0.1), lens(:L2, 0.2), beam(:B1), sys(:S1, [:L1, :L2], [:B1]), sys(:S2, [:L1]))
        mine = project(lens(:L1, 0.1), lens(:L2, 0.2), beam(:B1), sys(:S1, [:L1, :L2], [:B1]), sys(:S2, [:L1]))
        theirs = project(lens(:L1, 0.1), lens(:L2, 0.3), beam(:B1), sys(:S1, [:L1], [:B1]), sys(:S2, [:L1, :L2]))
        r = compose(base, mine, theirs, ["l2"])
        @test system(r.project, :S1).members == [:L1]
        @test Set(system(r.project, :S2).members) == Set([:L1, :L2])
    end

    @testset "the places of a source and of a member of a group come with them (F18)" begin
        base = project(lens(:L1, 0.1), lens(:L2, 0.2), beam(:B1), group(:G1, [:L1, :L2], 0.15), sys(:S1, [:G1], [:B1]))
        # mine removed L2 and B1, theirs moved both
        mine = project(lens(:L1, 0.1), group(:G1, [:L1], 0.15), sys(:S1, [:G1]))
        theirs = project(lens(:L1, 0.1), lens(:L2, 0.3), beam(:B1, 0.01), group(:G1, [:L1, :L2], 0.15),
            sys(:S1, [:G1], [:B1]))
        r = compose(base, mine, theirs, ["l2", "b1"])
        @test r.keys == ["b1", "l2"]
        @test grp(r.project, :G1).members == [:L1, :L2]
        @test system(r.project, :S1).sources == [:B1]
        save_project(r.project)
        p = load_project(mine.path)
        @test grp(p, :G1).members == [:L1, :L2] && system(p, :S1).sources == [:B1]
    end
end

end
