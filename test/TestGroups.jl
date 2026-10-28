module TestGroups

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using Test

const P = BeamletOpticsProjects
const BMO = BeamletOptics

const HEADER = "# BeamletOptics project \"Bench\" (format 1). Agents: see AGENTS.md.\n"

# Inner group G1 first, G2 holds G1 and M2; the system lists the outermost group G2
const SYSTEM = HEADER * """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.1, 0.0) uid = "u-l1"
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 45.0) uid = "u-m1"
@component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.1, 0.2, 0.0) rot = (0.0, 0.0, -45.0) uid = "u-m2"
@component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0) uid = "u-d1"
@component F1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.2, 0.0, 0.0) uid = "u-f1"
@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6) uid = "u-b1"
@group G1 = [L1, M1] pos = (0.0, 0.15, 0.0) rot = (0.0, 0.0, 10.0) label = "Telescope" uid = "u-g1"
@group G2 = [G1, M2] pos = (0.05, 0.2, 0.0) uid = "u-g2"
@system S1 = [G2, D1] sources = [B1] uid = "u-s1"
@system S2 = [F1, D1] uid = "u-s2"
"""

function project_dir(system = SYSTEM; toml = "name = \"Bench\"\n")
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), toml)
    write(joinpath(dir, "system.jl"), system)
    return dir
end

"""The message of the error that `f` throws, with the causes of a `LoadError`."""
function message(f)
    try
        f()
    catch err
        return sprint(showerror, err)
    end
    return ""
end

@testset "@group loads" begin
    p = load_project(project_dir())
    @test [g.name for g in p.groups] == [:G1, :G2]
    g1, g2 = p.groups
    @test g1.members == [:L1, :M1] && g2.members == [:G1, :M2]
    @test g1.label == "Telescope" && g1.uid == "u-g1" && g2.rot === nothing
    @test p[:G1] isa BMO.ObjectGroup && p[:G1] === g1.object
    @test BMO.objects(p[:G1]) == Any[p[:L1], p[:M1]]
    @test BMO.objects(p[:G2])[1] === p[:G1] && BMO.objects(p[:G2])[2] === p[:M2]
    # The system holds the outermost group, not its members
    @test p[:S1].objects[1] === p[:G2] && p[:S1].objects[2] === p[:D1]
    @test !any(o -> o === p[:L1], p[:S1].objects)

    @testset "no member moved" begin
        for e in p.entries
            e.pos === nothing && continue
            @test maximum(abs, BMO.position(e.object) - collect(e.pos)) ≤ 1e-12
            R = P.frame(e.object)
            @test maximum(abs, R - rotation_matrix(e.rot) * e.pose0[2]) ≤ 1e-12
        end
        for g in p.groups
            @test maximum(abs, BMO.position(g.object) - collect(g.pos)) ≤ 1e-12
            @test maximum(abs, BMO.orientation(g.object) - rotation_matrix(g.rot)) ≤ 1e-12
        end
    end

    @testset "text round trip" begin
        @test system_code(p) == SYSTEM
        dir = project_dir()
        q = load_project(dir)
        save_project(q)
        @test read(joinpath(dir, "system.jl"), String) == SYSTEM
        @test system_code(load_project(dir)) == SYSTEM
    end

    @testset "members and groups below the line" begin
        lines = split(chomp(SYSTEM), "\n")
        # The groups first, outer before inner, then the members
        text = join([lines[1]; lines[9]; lines[8]; lines[2:7]; lines[10:11]], "\n") * "\n"
        q = load_project(project_dir(text))
        @test [g.name for g in q.groups] == [:G2, :G1]
        @test BMO.objects(q[:G2])[1] === q[:G1]
        @test maximum(abs, BMO.position(q[:L1]) - [0.0, 0.1, 0.0]) ≤ 1e-12
        @test maximum(abs, BMO.orientation(q[:G1]) - rotation_matrix((0.0, 0.0, 10.0))) ≤ 1e-12
        # Written inner groups first
        @test system_code(q) == SYSTEM
    end

    @testset "the group moves its members" begin
        q = load_project(project_dir())
        translate3d!(q[:G2], [0.0, 0.0, 0.01])
        @test BMO.position(q[:L1]) ≈ [0.0, 0.1, 0.01]
        @test BMO.position(q[:G1]) ≈ [0.0, 0.15, 0.01]
    end
end

@testset "rule violations name the line" begin
    lines = split(chomp(SYSTEM), "\n")
    with(i, line) = join([lines[1:(i - 1)]; line; lines[(i + 1):end]], "\n") * "\n"
    load(text) = message(() -> load_project(project_dir(text)))

    # Rule 1: a source or a system is no member, nor an unknown name
    @test occursin("system.jl:9", load(with(9, "@group G2 = [G1, M2, B1] pos = (0.0, 0.0, 0.0)")))
    @test occursin("source", load(with(9, "@group G2 = [G1, M2, B1] pos = (0.0, 0.0, 0.0)")))
    m = load(with(9, "@group G2 = [G1, M2, S2] pos = (0.0, 0.0, 0.0)"))
    @test occursin("system.jl:9", m) && occursin("system", m)
    m = load(with(9, "@group G2 = [G1, M2, X9] pos = (0.0, 0.0, 0.0)"))
    @test occursin("system.jl:9", m) && occursin("X9", m)
    # Rule 2: in two groups, twice in one group, a cycle
    m = load(with(9, "@group G2 = [G1, M2, L1] pos = (0.0, 0.0, 0.0)"))
    @test occursin("system.jl:9", m) && occursin("already in the group `G1`", m)
    m = load(with(9, "@group G2 = [G1, M2, M2] pos = (0.0, 0.0, 0.0)"))
    @test occursin("system.jl:9", m) && occursin("twice", m)
    m = load(with(8, "@group G1 = [L1, M1, G2] pos = (0.0, 0.0, 0.0)"))
    @test occursin(r"system\.jl:[89]", m) && occursin("cycle", m)
    m = load(with(9, "@group G2 = [G2, M2] pos = (0.0, 0.0, 0.0)"))
    @test occursin("system.jl:9", m) && occursin("itself", m)
    # Rule 3: a system lists an entry or an inner group of a group
    m = load(with(10, "@system S1 = [G2, D1, L1] sources = [B1]"))
    @test occursin("system.jl:10", m) && occursin("outermost group `G2`", m)
    m = load(with(10, "@system S1 = [G1, D1] sources = [B1]"))
    @test occursin("system.jl:10", m) && occursin("`G1` is in the group `G2`", m)
    # The name of a group is unique, as is its uid
    m = load(with(9, "@group L1 = [G1, M2] pos = (0.0, 0.0, 0.0)"))
    @test occursin("system.jl:9", m) && occursin("used twice", m)
    m = load(with(9, "@group G2 = [G1, M2] pos = (0.0, 0.0, 0.0) uid = \"u-g1\""))
    @test occursin("system.jl:9", m) && occursin("used twice", m)
    # The line itself: pos is required, no other keywords, a finite pose
    m = load(with(9, "@group G2 = [G1, M2]"))
    @test occursin("system.jl:9", m) && occursin("pos", m)
    m = load(with(9, "@group G2 = [G1, M2] pos = (0.0, 0.0, 0.0) static = true"))
    @test occursin("system.jl:9", m) && occursin("no keyword `static`", m)
    m = load(with(9, "@group G2 = [G1, M2] pos = (0.0, NaN, 0.0)"))
    @test occursin("system.jl:9", m) && occursin("not finite", m)
end

@testset "groups are written" begin
    p = load_project(project_dir())
    g = p.groups[1]
    # A matrix orientation is written as angles; the identity is left out
    p.groups[1] = GroupEntry(g.name, g.members; pos = g.pos, rot = rotation_matrix((0.0, 0.0, 10.0)),
        label = g.label, uid = g.uid)
    @test system_code(p) == SYSTEM
    p.groups[1] = GroupEntry(g.name, g.members; pos = g.pos, rot = Matrix(1.0I, 3, 3), uid = g.uid)
    @test occursin("@group G1 = [L1, M1] pos = (0.0, 0.15, 0.0) uid = \"u-g1\"\n", system_code(p))
    p.groups[1] = GroupEntry(g.name, g.members; pos = (NaN, 0.0, 0.0))
    @test_throws ArgumentError system_code(p)
    # A new group gets a uid when saved; next_id sees groups
    p.groups[1] = GroupEntry(g.name, g.members; pos = g.pos)
    @test next_id(p, "G") === :G3
    save_project(p)
    @test p.groups[1].uid isa String && !isempty(p.groups[1].uid)
end

@testset "a plain include builds the groups" begin
    m = Module()
    Core.eval(m, :(using BeamletOptics, BeamletOpticsProjects))
    Core.eval(m, quote
        @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.1, 0.0)
        @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0)
        @group G1 = [L1, M1] pos = (0.0, 0.15, 0.0) rot = (0.0, 0.0, 90.0)
        @system S1 = [G1]
    end)
    G1 = Core.eval(m, :G1)
    @test G1 isa BMO.ObjectGroup
    @test BMO.position(G1) == [0.0, 0.15, 0.0]
    @test BMO.orientation(G1) == rotation_matrix((0.0, 0.0, 90.0))
    @test BMO.position(Core.eval(m, :L1)) == [0.0, 0.1, 0.0]
    @test Core.eval(m, :S1).objects[1] === G1
end

@testset "@component of an ObjectGroup as before" begin
    text = HEADER * """
    @component G1 = ObjectGroup([SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5), RoundPlanoMirror(0.0254, 0.006)]) pos = (0.0, 0.1, 0.0) uid = "u-g1"
    @system S1 = [G1] uid = "u-s1"
    """
    p = load_project(project_dir(text))
    @test isempty(p.groups) && p[:G1] isa BMO.ObjectGroup
    @test p.entries[1].kind === :component
    @test system_code(p) == text
end

@testset "format gate" begin
    toml(f) = "name = \"Bench\"\n\n[beamletoptics]\nformat = $f\n"
    m = message(() -> load_project(project_dir(; toml = toml(2))))
    @test occursin("format 2", m) && occursin("format 1", m)
    @test_throws ArgumentError load_project(project_dir(; toml = toml(2)))
    @test load_project(project_dir(; toml = toml(1))) isa Project
    @test load_project(project_dir()) isa Project
end

end
