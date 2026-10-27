module TestMerge

using BeamletOptics, BeamletOpticsProjects
using Test

const P = BeamletOpticsProjects

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
lens(id, y; uid = lowercase(String(id)), rest = "") = "@component $id = $LENS pos = (0.0, $y, 0.0)$rest uid = \"$uid\""
beam(id) = "@source $id = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6) uid = \"$(lowercase(String(id)))\""
sys(id, members; rest = "") = "@system $id = [$(join(members, ", "))] sources = [B1]$rest uid = \"$(lowercase(String(id)))\""

"""A project in a new folder from the `lines` of its `system.jl`."""
function project(lines...)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), join(lines, "\n") * "\n")
    return load_project(dir)
end

const BASE = (lens(:L1, 0.1), beam(:B1), sys(:S1, ["L1"]))

@testset "merge_plan" begin
    base = project(BASE...)

    @testset "a change of theirs only is taken" begin
        mine = project(BASE...)
        theirs = project(lens(:L1, 0.2), beam(:B1), sys(:S1, ["L1"]))
        plan = P.merge_plan(base, mine, theirs)
        @test plan.take == Set(["l1"]) && isempty(plan.conflicts) && isempty(plan.merged)
        @test only(plan.theirs.entries).kind === :moved && isempty(plan.mine.entries)
    end

    @testset "both changed: the same state is taken, another is a conflict" begin
        moved = project(lens(:L1, 0.2), beam(:B1), sys(:S1, ["L1"]))
        plan = P.merge_plan(base, moved, moved)
        @test plan.take == Set(["l1"]) && isempty(plan.conflicts)
        other = project(lens(:L1, 0.3), beam(:B1), sys(:S1, ["L1"]))
        plan = P.merge_plan(base, other, moved)
        @test plan.conflicts == ["l1"] && isempty(plan.take)
    end

    @testset "stale and kept conflicts" begin
        mine = project(BASE...)
        theirs = project(lens(:L1, 0.2), beam(:B1), sys(:S1, ["L1"]))
        @test P.merge_plan(base, mine, theirs; stale = k -> k == "l1").conflicts == ["l1"]
        # A conflict of before stays while mine and theirs differ there, and ends when they agree
        other = project(lens(:L1, 0.3), beam(:B1), sys(:S1, ["L1"]))
        @test P.merge_plan(theirs, other, theirs; keep = ["l1"]).conflicts == ["l1"]
        @test isempty(P.merge_plan(theirs, theirs, theirs; keep = ["l1"]).conflicts)
    end

    @testset "both add to a system: members merged as sets" begin
        mine = project(lens(:L1, 0.1), lens(:L2, 0.2), beam(:B1), sys(:S1, ["L1", "L2"]))
        theirs = project(lens(:L1, 0.1), lens(:L3, 0.3), beam(:B1), sys(:S1, ["L1", "L3"]))
        plan = P.merge_plan(base, mine, theirs)
        @test isempty(plan.conflicts)
        @test plan.merged["s1"].members == Set(["l1", "l2", "l3"])
        @test plan.merged["s1"].sources == Set(["b1"])
        @test "l3" in plan.take && !("s1" in plan.take)
        # Theirs removes L1 from the system, mine adds L2: both are kept
        theirs = project(lens(:L1, 0.1), beam(:B1), sys(:S1, String[]))
        plan = P.merge_plan(base, mine, theirs)
        @test plan.merged["s1"].members == Set(["l2"])
        # Another label on both sides is a conflict, not a merge
        mine = project(lens(:L1, 0.1), lens(:L2, 0.2), beam(:B1), sys(:S1, ["L1", "L2"]; rest = " label = \"a\""))
        theirs = project(lens(:L1, 0.1), lens(:L3, 0.3), beam(:B1), sys(:S1, ["L1", "L3"]; rest = " label = \"b\""))
        @test P.merge_plan(base, mine, theirs).conflicts == ["s1"]
    end

    @testset "a new id of theirs that mine has already is renumbered" begin
        mine = project(lens(:L1, 0.1), lens(:L2, 0.2; uid = "mine-l2"), beam(:B1), sys(:S1, ["L1"]))
        theirs = project(lens(:L1, 0.1), lens(:L2, 0.3; uid = "their-l2"), beam(:B1), sys(:S1, ["L1"]))
        plan = P.merge_plan(base, mine, theirs)
        @test plan.renames == Dict("their-l2" => :L3)
        @test "their-l2" in plan.take
        # The same entry (same uid) on both sides is no clash
        @test isempty(P.merge_plan(base, mine, mine).renames)
    end

    @testset "a new or renamed system or entry of theirs with an id of mine is renumbered" begin
        # Both add a system S2: mine saved it with a uid, theirs has none yet
        s2 = "@system S2 = [L1]"
        mine = project(BASE..., s2 * " uid = \"mine-s2\"")
        theirs = project(BASE..., s2)
        plan = P.merge_plan(base, mine, theirs)
        @test plan.renames == Dict("id:S2" => :S3) && "id:S2" in plan.take
        # Theirs renames L1 to L2, which mine added
        mine = project(BASE..., lens(:L2, 0.2; uid = "mine-l2"))
        theirs = project(replace(lens(:L1, 0.1), "L1 =" => "L2 ="), beam(:B1), sys(:S1, ["L2"]))
        @test P.merge_plan(base, mine, theirs).renames == Dict("l1" => :L3)
    end

    @testset "a source moved into two systems is a conflict on both" begin
        src(id) = "@source $id = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6) uid = \"$(lowercase(id))\""
        line(id, sources) = "@system $id = [L1] sources = [$(join(sources, ", "))] uid = \"$(lowercase(id))\""
        state(s1, s2, s3) = project(lens(:L1, 0.1), src("B1"), src("B2"), line("S1", s1), line("S2", s2), line("S3", s3))
        base3 = state(["B1", "B2"], String[], String[])
        plan = P.merge_plan(base3, state(["B1"], ["B2"], String[]), state(["B1"], String[], ["B2"]))
        @test sort(plan.conflicts) == ["s2", "s3"] && !("s3" in plan.take)
        # Moved into the same system by both: no conflict
        moved = state(["B1"], ["B2"], String[])
        @test isempty(P.merge_plan(base3, moved, moved).conflicts)
    end

    @testset "a kept conflict whose members are merged now ends" begin
        base1 = project(BASE[1:2]..., sys(:S1, ["L1"]; rest = " label = \"b\""))
        mine = project(BASE[1:2]..., lens(:L2, 0.2), sys(:S1, ["L1", "L2"]; rest = " label = \"a\""))
        theirs = project(BASE[1:2]..., lens(:L3, 0.3), sys(:S1, ["L1", "L3"]; rest = " label = \"a\""))
        plan = P.merge_plan(base1, mine, theirs; keep = ["s1"])
        @test isempty(plan.conflicts) && plan.merged["s1"].members == Set(["l1", "l2", "l3"])
    end

    @testset "members merged by their partners in the base" begin
        # L7 has no uid in the base and in theirs, mine gave it one when saving
        l7 = "@component L7 = $LENS pos = (0.0, 0.7, 0.0)"
        base7 = project(BASE[1:2]..., l7, sys(:S1, ["L1", "L7"]))
        mine = project(BASE[1:2]..., l7 * " uid = \"u7\"", lens(:L2, 0.2), sys(:S1, ["L1", "L7", "L2"]))
        theirs = project(BASE[1:2]..., l7, sys(:S1, ["L1"]))
        @test P.merge_plan(base7, mine, theirs).merged["s1"].members == Set(["l1", "l2"])
    end

    @testset "a uid given to a member is no change of the system" begin
        # Mine only gave L7 a uid when saving, theirs relabeled S1: S1 is taken
        l7 = "@component L7 = $LENS pos = (0.0, 0.7, 0.0)"
        base7 = project(BASE[1:2]..., l7, sys(:S1, ["L7"]))
        mine = project(BASE[1:2]..., l7 * " uid = \"u7\"", sys(:S1, ["L7"]))
        theirs = project(BASE[1:2]..., l7, sys(:S1, ["L7"]; rest = " label = \"b\""))
        plan = P.merge_plan(base7, mine, theirs)
        @test "s1" in plan.take && isempty(plan.conflicts)
    end

    @testset "lines without uid are paired by their id" begin
        nouid(text) = replace(text, r" uid = \"[^\"]*\"" => "")
        base0 = project(nouid.(BASE)...)
        theirs = project(nouid(lens(:L1, 0.2)), nouid(beam(:B1)), nouid(sys(:S1, ["L1"])))
        plan = P.merge_plan(base0, base0, theirs)
        @test plan.take == Set(["id:L1"])
    end
end

end
