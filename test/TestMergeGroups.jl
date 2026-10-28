module TestMergeGroups

using BeamletOptics, BeamletOpticsProjects
using Test

const P = BeamletOpticsProjects

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
lens(id, y) = "@component $id = $LENS pos = (0.0, $y, 0.0) uid = \"$(lowercase(String(id)))\""
beam(id) = "@source $id = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6) uid = \"$(lowercase(String(id)))\""

"""
A project with the lenses `ys` (`id => y`), the source B1, the `systems` (`id => members`, the
first with B1) and the `groups` (`id => members`, or `id => (members, pos)`), built in memory: the
groups and systems are added to the loaded entries, so that the merge is tested on its own.
"""
function project(ys; systems = [:S1 => [:L1, :M1, :D1]], groups = Pair[], uids = Dict{Symbol, String}())
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), join([[lens(id, y) for (id, y) in ys]; beam(:B1)], "\n") * "\n")
    p = load_project(dir)
    uid(id) = get(uids, id, lowercase(String(id)))
    for (id, g) in groups
        members, pos = g isa Tuple ? g : (g, (0.0, 0.0, 0.0))
        push!(p.groups, GroupEntry(id, members; pos, uid = uid(id)))
    end
    for (i, (id, members)) in enumerate(systems)
        push!(p.systems, SystemEntry(id, members, i == 1 ? [:B1] : Symbol[]; uid = uid(id)))
    end
    return p
end

const YS = [:L1 => 0.1, :M1 => 0.2, :D1 => 0.3]
moved(ys, id, y) = [k == id ? k => y : k => v for (k, v) in ys]

@testset "merge of groups" begin
    base = project(YS)
    grouped = project(YS; groups = [:G1 => [:L1, :M1]], systems = [:S1 => [:G1, :D1]])

    @testset "a group made on one side, a member moved on the other" begin
        theirs = project(moved(YS, :L1, 0.15))
        plan = P.merge_plan(base, grouped, theirs)
        @test plan.take == Set(["l1"]) && isempty(plan.conflicts)
        # the other window takes the group and the system
        plan = P.merge_plan(base, theirs, grouped)
        @test plan.take == Set(["g1", "s1"]) && isempty(plan.conflicts)
        @test only(c for c in plan.theirs.groups).kind === :added
    end

    @testset "one entry grouped into two groups: a conflict" begin
        other = project(YS; groups = [:G2 => [:L1, :D1]], systems = [:S1 => [:G2, :M1]])
        plan = P.merge_plan(base, other, grouped)
        @test issubset(["g1", "g2"], plan.conflicts) && "s1" in plan.conflicts
        @test isempty(intersect(plan.take, Set(["g1", "s1"])))
    end

    @testset "a group ungrouped on one side and moved on the other: a conflict" begin
        gbase = project(YS; groups = [:G1 => ([:L1, :M1], (0.0, 0.15, 0.0))], systems = [:S1 => [:G1, :D1]])
        ungrouped = project(YS)
        theirs = project([:L1 => 0.11, :M1 => 0.21, :D1 => 0.3];
            groups = [:G1 => ([:L1, :M1], (0.0, 0.16, 0.0))], systems = [:S1 => [:G1, :D1]])
        plan = P.merge_plan(gbase, ungrouped, theirs)
        @test plan.conflicts == ["g1"]
        @test plan.take == Set(["l1", "m1"])
        @test only(c for c in plan.theirs.groups).kind === :moved
    end

    @testset "both add a member to a group: merged as sets" begin
        ys = [YS; :L2 => 0.4; :L3 => 0.5]
        gbase = project(ys; groups = [:G1 => [:L1, :M1]], systems = [:S1 => [:G1, :D1]])
        mine = project(ys; groups = [:G1 => [:L1, :M1, :L2]], systems = [:S1 => [:G1, :D1]])
        theirs = project(ys; groups = [:G1 => [:L1, :M1, :L3]], systems = [:S1 => [:G1, :D1]])
        plan = P.merge_plan(gbase, mine, theirs)
        @test isempty(plan.conflicts)
        @test plan.merged["g1"].members == Set(["l1", "m1", "l2", "l3"])
        @test isempty(plan.merged["g1"].sources)
        # the same members in another order are no change
        same = project(ys; groups = [:G1 => [:M1, :L1]], systems = [:S1 => [:G1, :D1]])
        @test isempty(P.diff_projects(gbase, same).groups)
    end

    @testset "an entry added to a system while the other side grouped it: a conflict" begin
        ys = [YS; :D2 => 0.6]
        b2 = project(ys; systems = [:S1 => [:L1, :M1, :D1], :S2 => [:D2]])
        mine = project(ys; groups = [:G1 => [:L1, :M1]], systems = [:S1 => [:G1, :D1], :S2 => [:D2]])
        theirs = project(ys; systems = [:S1 => [:L1, :M1, :D1], :S2 => [:D2, :L1]])
        plan = P.merge_plan(b2, mine, theirs)
        @test "s2" in plan.conflicts && !("s2" in plan.take)
    end

    @testset "the same readable id added on both sides: renamed" begin
        ys = [YS; :L2 => 0.4]
        b2 = project(ys; systems = [:S1 => [:L1, :M1, :D1, :L2]])
        mine = project(ys; groups = [:G1 => [:L1, :M1]], systems = [:S1 => [:G1, :D1, :L2]],
            uids = Dict(:G1 => "g1-mine"))
        theirs = project(ys; groups = [:G1 => [:D1, :L2]], systems = [:S1 => [:L1, :M1, :G1]],
            uids = Dict(:G1 => "g1-theirs"))
        plan = P.merge_plan(b2, mine, theirs)
        @test isempty(plan.conflicts)
        @test "g1-theirs" in plan.take && plan.renames["g1-theirs"] === :G2
        @test plan.merged["s1"].members == Set(["g1-mine", "g1-theirs"])
    end

    @testset "a renamed and relabeled group" begin
        # the same uid: renamed, and the system that lists it by the new id is unchanged
        renamed = project(YS; groups = [:G7 => [:L1, :M1]], systems = [:S1 => [:G7, :D1]],
            uids = Dict(:G7 => "g1"))
        d = P.diff_projects(grouped, renamed)
        @test [c.kind for c in d.groups] == [:renamed] && isempty(d.systems)
        plan = P.merge_plan(grouped, grouped, renamed)
        @test plan.take == Set(["g1"]) && isempty(plan.conflicts)
    end
end

sys(id, members) = "@system $id = [$(join(members, ", "))] sources = [B1] uid = \"$(lowercase(String(id)))\""
grp(id, members; y = 0.15) = "@group $id = [$(join(members, ", "))] pos = (0.0, $y, 0.0) uid = \"$(lowercase(String(id)))\""

function folder(lines...)
    dir = joinpath(mktempdir(), "Bench")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nend\n")
    write(joinpath(dir, "system.jl"), join(lines, "\n") * "\n")
    return dir
end

@testset "a team groups in its draft" begin
    dir = folder(lens(:L1, 0.1), lens(:M1, 0.2), lens(:D1, 0.3), beam(:B1), sys(:S1, ["L1", "M1", "D1"]))
    draft = fork_team(dir, "t1"; by = "anna")
    write(joinpath(draft, "system.jl"), join([lens(:L1, 0.1), lens(:M1, 0.2), lens(:D1, 0.3), beam(:B1),
        grp(:G1, ["L1", "M1"]), sys(:S1, ["G1", "D1"])], "\n") * "\n")
    # meanwhile the project moves D1
    write(joinpath(dir, "system.jl"), join([lens(:L1, 0.1), lens(:M1, 0.2), lens(:D1, 0.35), beam(:B1),
        sys(:S1, ["L1", "M1", "D1"])], "\n") * "\n")
    r = merge_draft!(dir, "t1")
    @test isempty(r.conflicts) && issubset(["g1", "s1"], r.taken)
    p = load_project(dir)
    g = only(p.groups)
    @test g.name === :G1 && g.members == [:L1, :M1] && g.pos == (0.0, 0.15, 0.0)
    @test only(p.systems).members == [:G1, :D1]
    @test p[:D1] isa BeamletOptics.AbstractObject && BeamletOptics.position(p[:D1])[2] == 0.35
    # the draft merges again without changes
    @test isempty(merge_draft!(dir, "t1").taken)
    # look shows the group in its system with its members
    text = sprint(io -> look(p; io))
    @test occursin("G1 (L1, M1)", text)
end

@testset "a draft removes an entry that the project moved (F18)" begin
    dir = folder(lens(:L1, 0.1), lens(:L2, 0.2), beam(:B1), sys(:S1, ["L1", "L2"]))
    draft = fork_team(dir, "t1"; by = "anna")
    # the draft removes L1 and adds L3 to S1
    write(joinpath(draft, "system.jl"), join([lens(:L2, 0.2), lens(:L3, 0.3), beam(:B1),
        sys(:S1, ["L2", "L3"])], "\n") * "\n")
    # meanwhile the project moves L1
    write(joinpath(dir, "system.jl"), join([lens(:L1, 0.15), lens(:L2, 0.2), beam(:B1),
        sys(:S1, ["L1", "L2"])], "\n") * "\n")
    r = merge_draft!(dir, "t1")
    @test r.conflicts == ["l1"]
    p = load_project(dir)
    @test p.entries[findfirst(e -> e.name === :L1, p.entries)].pos[2] == 0.15
    # L1 keeps its place in S1, the member that the draft added comes
    @test Set(only(p.systems).members) == Set([:L1, :L2, :L3])
end

end
