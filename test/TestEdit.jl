module TestEdit

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using Test

const P = BeamletOpticsProjects
const BMO = BeamletOptics

const HEADER = "# BeamletOptics project \"Bench\" (format 1). Agents: see AGENTS.md.\n"

# G2 holds the group G1 and M2; F1, D1 and the source B1 are in no group
const SYSTEM = HEADER * """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.1, 0.0) label = "Collimator" uid = "u-l1"
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 45.0) uid = "u-m1"
@component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.1, 0.2, 0.0) rot = (0.0, 0.0, -45.0) uid = "u-m2"
@component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0) uid = "u-d1"
@component F1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.2, 0.0, 0.0) rot = (10.0, 0.0, 20.0) uid = "u-f1"
@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6) pos = (0.0, -0.05, 0.0) uid = "u-b1"
@group G1 = [L1, M1] pos = (0.0, 0.15, 0.0) rot = (0.0, 0.0, 10.0) uid = "u-g1"
@group G2 = [G1, M2] pos = (0.05, 0.2, 0.0) uid = "u-g2"
@system S1 = [G2, D1] sources = [B1] uid = "u-s1"
@system S2 = [F1, D1] uid = "u-s2"
"""

function bench(system = SYSTEM)
    dir = joinpath(mktempdir(), "Bench")
    mkpath(dir)
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), system)
    return dir
end

text(dir) = read(joinpath(dir, "system.jl"))
entry(p, id) = p.entries[findfirst(e -> e.name === id, p.entries)]
group(p, id) = p.groups[findfirst(g -> g.name === id, p.groups)]
system(p, id) = p.systems[findfirst(s -> s.name === id, p.systems)]
has(p, id) = any(e -> e.name === id, p.entries) || any(g -> g.name === id, p.groups)
line_pos(x::Entry) = x.pos === nothing ? x.pose0[1] : collect(x.pos)
line_pos(x::GroupEntry) = collect(x.pos)

message(f) = try
    f()
    ""
catch err
    sprint(showerror, err)
end

"""Throws an `ArgumentError` whose message holds `id`, and `system.jl` of `dir` stays byte for byte."""
function refused(f, dir, id)
    before = text(dir)
    err = try
        f()
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    err isa ArgumentError && @test occursin(String(id), err.msg)
    @test text(dir) == before
end

"""
Checks that the line `copy` of `b` is the line `orig` of `a` moved by `x ↦ c + R (x − c) + t`:
positions within 1e-12 m, rotations within 1e-13, and the built objects too.
"""
function rigid_copy(a, b, orig, copy, c, R, t)
    x, y = any(e -> e.name === orig, a.entries) ? (entry(a, orig), entry(b, copy)) :
           (group(a, orig), group(b, copy))
    want = c + R * (line_pos(x) - c) + t
    @test maximum(abs, line_pos(y) - want) ≤ 1e-12
    @test maximum(abs, rotation_matrix(y.rot) - R * rotation_matrix(x.rot)) ≤ 1e-13
    @test maximum(abs, BMO.position(y.object) - want) ≤ 1e-12
    if y isa GroupEntry
        @test maximum(abs, BMO.orientation(y.object) - R * BMO.orientation(x.object)) ≤ 1e-12
    else
        @test maximum(abs, P.frame(y.object) - R * P.frame(x.object)) ≤ 1e-12
        @test y.code == x.code
    end
end

@testset "add!" begin
    @testset "a component and a source with the next free id" begin
        dir = bench()
        id = P.add!(dir, "RoundPlanoMirror(0.0254, 0.006)"; pos = (0.1, 0.4, 0.0), rot = (0, 0, 45),
            systems = [:S2])
        @test id === :M3
        p = load_project(dir)
        e = entry(p, :M3)
        @test e.kind === :component && e.pos == (0.1, 0.4, 0.0) && e.rot == (0.0, 0.0, 45.0)
        @test e.uid !== nothing && e.label === nothing
        @test system(p, :S2).members == [:F1, :D1, :M3]
        @test :M3 ∉ system(p, :S1).members
        @test maximum(abs, BMO.position(p[:M3]) - [0.1, 0.4, 0.0]) ≤ 1e-15
        @test occursin("@component M3 = RoundPlanoMirror(0.0254, 0.006) pos = (0.1, 0.4, 0.0) rot = (0.0, 0.0, 45.0) uid",
            String(text(dir)))
        # zero angles are no rotation
        @test P.add!(dir, "Detector(0.01)"; label = "Camera") === :D2
        p = load_project(dir)
        @test entry(p, :D2).rot === nothing && entry(p, :D2).pos == (0.0, 0.0, 0.0)
        @test entry(p, :D2).label == "Camera"

        id = P.add!(dir, "Beam([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 6.33e-7)"; pos = (0.0, 0.0, 0.01),
            systems = [:S2])
        @test id === :B2
        p = load_project(dir)
        @test entry(p, :B2).kind === :source
        @test system(p, :S2).sources == [:B2] && system(p, :S2).members == [:F1, :D1, :M3]
        # a given id that is free
        @test P.add!(dir, "Detector(0.01)"; id = :Cam) === :Cam
        @test has(load_project(dir), :Cam)
    end

    @testset "a taken id, a source in two systems" begin
        dir = bench()
        refused(() -> P.add!(dir, "Detector(0.01)"; id = :L1), dir, :L1)
        refused(() -> P.add!(dir, "Detector(0.01)"; id = :S1), dir, :S1)
        refused(() -> P.add!(dir, "Beam([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 6.33e-7)";
            systems = [:S1, :S2]), dir, :B2)
    end

    @testset "checks name the id and write nothing" begin
        dir = bench()
        refused(() -> P.add!(dir, "NoSuchLens(0.01)"; id = :X5), dir, :X5)
        refused(() -> P.add!(dir, "RoundPlanoMirror(0.0254,"; id = :X5), dir, :X5)
        refused(() -> P.add!(dir, "1 + 1"; id = :X5), dir, :X5)
        refused(() -> P.add!(dir, "Detector(0.01)"; pos = (NaN, 0.0, 0.0)), dir, :D2)
        refused(() -> P.add!(dir, "Detector(0.01)"; rot = (0.0, Inf, 0.0)), dir, :D2)
        refused(() -> P.add!(dir, "Detector(0.01)"; pos = (0.0, 0.0)), dir, :D2)
        m = message(() -> P.add!(dir, "Detector(0.01)"; systems = [:S9]))
        @test occursin("D2", m) && occursin("S9", m)
        # a line claimed by another: the system that would get the new member
        @test claim!(dir; by = "anna@pc2", ids = [:S2])
        refused(() -> P.add!(dir, "Detector(0.01)"; systems = [:S2], by = "ben@pc3"), dir, :S2)
        @test P.add!(dir, "Detector(0.01)"; systems = [:S2], by = "anna@pc2") === :D2
    end
end

@testset "set!" begin
    @testset "only the given fields, the uid stays" begin
        dir = bench()
        b = P.set!(dir, :F1; pos = (0.3, 0.0, 0.0))
        @test b isa Project
        e = entry(b, :F1)
        @test e.pos == (0.3, 0.0, 0.0) && e.rot == (10.0, 0.0, 20.0) && e.uid == "u-f1"
        @test e.code == :(RoundPlanoMirror(0.0254, 0.006))
        b = P.set!(dir, :F1; rot = (0, 0, 30))
        e = entry(b, :F1)
        @test e.pos == (0.3, 0.0, 0.0) && e.rot == (0.0, 0.0, 30.0) && e.uid == "u-f1"
        # code: the object is built again
        b = P.set!(dir, :L1; code = "SphericalLens(0.05, -0.05, 0.006, 0.0254, 1.5)")
        e = entry(b, :L1)
        @test e.code == :(SphericalLens(0.05, -0.05, 0.006, 0.0254, 1.5))
        @test e.pos == (0.0, 0.1, 0.0) && e.label == "Collimator" && e.uid == "u-l1"
        # label: "" removes it; of a group and a system too
        @test entry(P.set!(dir, :L1; label = ""), :L1).label === nothing
        @test entry(P.set!(dir, :D1; label = "Camera"), :D1).label == "Camera"
        @test group(P.set!(dir, :G1; label = "Telescope"), :G1).label == "Telescope"
        @test system(P.set!(dir, :S2; label = "Side arm"), :S2).label == "Side arm"
        # the other lines are as they were
        a = load_project(bench())
        b = load_project(dir)
        for id in (:M1, :M2, :B1)
            @test entry(a, id).pos == entry(b, id).pos && entry(a, id).rot == entry(b, id).rot
        end
    end

    @testset "checks name the id and write nothing" begin
        dir = bench()
        refused(() -> P.set!(dir, :F1; code = "NoSuchMirror(1)"), dir, :F1)
        refused(() -> P.set!(dir, :F1; code = "Beam([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 6.33e-7)"), dir, :F1)
        refused(() -> P.set!(dir, :F1; pos = (0.0, NaN, 0.0)), dir, :F1)
        refused(() -> P.set!(dir, :F1; rot = [1.0 0 0; 0 1 0; 0 0 Inf]), dir, :F1)
        refused(() -> P.set!(dir, :Q7; pos = (0.0, 0.0, 0.0)), dir, :Q7)
        refused(() -> P.set!(dir, :G1; pos = (0.0, 0.0, 0.0)), dir, :G1)
        refused(() -> P.set!(dir, :S1; code = "Detector(0.01)"), dir, :S1)
        @test claim!(dir; by = "anna@pc2", ids = [:F1])
        refused(() -> P.set!(dir, :F1; pos = (0.3, 0.0, 0.0), by = "ben@pc3"), dir, :F1)
        @test entry(P.set!(dir, :F1; pos = (0.3, 0.0, 0.0), by = "anna@pc2"), :F1).pos == (0.3, 0.0, 0.0)
    end
end

@testset "duplicate!" begin
    @testset "a component and a source, moved as move! moves" begin
        dir = bench()
        a = load_project(dir)
        new = P.duplicate!(dir, [:F1, :B1]; offset = (0.01, -0.02, 0.03), rot = (0, 0, 30))
        @test new == [:M3, :B2]
        b = load_project(dir)
        R = rotation_matrix((0, 0, 30))
        c = (line_pos(entry(a, :F1)) + line_pos(entry(a, :B1))) / 2
        rigid_copy(a, b, :F1, :M3, c, R, [0.01, -0.02, 0.03])
        rigid_copy(a, b, :B1, :B2, c, R, [0.01, -0.02, 0.03])
        @test maximum(abs, BMO.direction(b[:B2]) - R * BMO.direction(a[:B1])) ≤ 1e-13
        # the originals stay; the copies have no label and a new uid
        @test entry(b, :F1).pos == entry(a, :F1).pos && entry(b, :F1).rot == entry(a, :F1).rot
        @test entry(b, :M3).uid ∉ ("u-f1", nothing) && entry(b, :M3).kind === :component
        @test entry(b, :B2).kind === :source
        # systems = :same
        @test system(b, :S2).members == [:F1, :D1, :M3]
        @test system(b, :S1).sources == [:B1, :B2]
    end

    @testset "a nested group with its members" begin
        dir = bench()
        a = load_project(dir)
        R = rotation_matrix((20, -35, 70))
        t = [0.1, 0.2, -0.3]
        new = P.duplicate!(dir, [:G2, :D1]; rot = (20, -35, 70), offset = (0.1, 0.2, -0.3), pivot = :G2)
        # the order of ids and of the members, a group after its members
        @test new == [:L2, :M3, :G3, :M4, :G4, :D2]
        b = load_project(dir)
        @test group(b, :G4).members == [:G3, :M4] && group(b, :G3).members == [:L2, :M3]
        @test group(b, :G2).members == [:G1, :M2] && group(b, :G1).members == [:L1, :M1]
        c = collect(group(a, :G2).pos)
        for (orig, copy) in zip([:L1, :M1, :G1, :M2, :G2, :D1], new)
            rigid_copy(a, b, orig, copy, c, R, t)
        end
        @test entry(b, :L2).label === nothing
        @test system(b, :S1).members == [:G2, :D1, :G4, :D2]
        @test system(b, :S2).members == [:F1, :D1, :D2]
        # a group and one of its members: the member is copied once, with the group; the copies
        # of the members are in systems only through the copy of the group
        @test P.duplicate!(dir, [:G2, :M2]; offset = (0.0, 0.0, 0.1)) == [:L3, :M5, :G5, :M6, :G6]
        b = load_project(dir)
        @test system(b, :S1).members == [:G2, :D1, :G4, :D2, :G6]
        @test all(s -> :G5 ∉ s.members && :M6 ∉ s.members, b.systems)
    end

    @testset "systems as a vector, errors" begin
        dir = bench()
        @test P.duplicate!(dir, [:D1]; systems = [:S2]) == [:D2]
        b = load_project(dir)
        @test :D2 ∈ system(b, :S2).members && :D2 ∉ system(b, :S1).members
        @test P.duplicate!(dir, [:F1]; systems = Symbol[]) == [:M3]
        @test all(s -> :M3 ∉ s.members, load_project(dir).systems)
        refused(() -> P.duplicate!(dir, [:L1]), dir, :L1)
        refused(() -> P.duplicate!(dir, [:X9]), dir, :X9)
        refused(() -> P.duplicate!(dir, [:S1]), dir, :S1)
        refused(() -> P.duplicate!(dir, [:F1]; systems = [:S9]), dir, :S9)
        refused(() -> P.duplicate!(dir, [:B1]; systems = [:S1, :S2]), dir, :B1)
    end
end

@testset "remove!" begin
    @testset "lines and their places in systems and groups" begin
        dir = bench()
        b = P.remove!(dir, [:G2, :B1])
        @test b isa Project
        @test !any(id -> has(b, id), [:G2, :G1, :L1, :M1, :M2, :B1])
        @test system(b, :S1).members == [:D1] && isempty(system(b, :S1).sources)
        @test system(b, :S2).members == [:F1, :D1]
        b = P.remove!(dir, [:D1])
        @test system(b, :S1).members == Symbol[] && system(b, :S2).members == [:F1]
        @test !occursin("D1", String(text(dir)))
        # a group with one of its members given too
        dir = bench()
        b = P.remove!(dir, [:G2, :M1])
        @test !any(id -> has(b, id), [:G2, :G1, :L1, :M1, :M2])
        @test system(b, :S1).members == [:D1]
        # an inner group without its group
        dir = bench()
        m = message(() -> P.remove!(dir, [:G1]))
        @test occursin("G1", m) && occursin("give the group `G2`", m)
        refused(() -> P.remove!(dir, [:G1]), dir, :G1)
    end

    @testset "errors name the id and write nothing" begin
        dir = bench()
        m = message(() -> P.remove!(dir, [:L1]))
        @test occursin("L1", m) && occursin("G2", m)
        refused(() -> P.remove!(dir, [:L1]), dir, :L1)
        refused(() -> P.remove!(dir, [:S1]), dir, :S1)
        refused(() -> P.remove!(dir, [:F1, :X9]), dir, :X9)
        @test claim!(dir; by = "anna@pc2", ids = [:F1])
        refused(() -> P.remove!(dir, [:F1]; by = "ben@pc3"), dir, :F1)
    end
end

@testset "a write with by tells the windows who wrote it" begin
    dir = bench()
    doing(name) = P.read_presences(dir)[name * "@agent"]["doing"]
    written(name) = P.read_presences(dir)[name * "@agent"]["written"]
    announce(dir; name = "claude", ttl = 600, selected_id = "L1")
    id = P.add!(dir, "RoundPlanoMirror(0.0254, 0.006)"; pos = (0.3, 0.0, 0.0), by = "claude")
    @test doing("claude") == "added $id" && written("claude") == project_stamp(dir)
    d = P.read_presences(dir)["claude@agent"]
    @test d["ttl"] == 600 && d["selected_id"] == String(id)
    P.set!(dir, id; pos = (0.31, 0.0, 0.0), by = "claude")
    @test doing("claude") == "changed $id" && written("claude") == project_stamp(dir)
    new = P.duplicate!(dir, [id]; offset = (0.0, 0.05, 0.0), by = "claude")
    @test doing("claude") == "copied $id as $(only(new))"
    move!(dir, new; offset = (0.0, 0.01, 0.0), by = "claude")
    @test doing("claude") == "moved $(only(new))" && written("claude") == project_stamp(dir)
    P.remove!(dir, new; by = "claude")
    @test doing("claude") == "removed $(only(new))" && written("claude") == project_stamp(dir)
    # without by nobody is announced
    P.add!(dir, "RoundPlanoMirror(0.0254, 0.006)"; pos = (0.4, 0.0, 0.0))
    @test sort(collect(keys(P.read_presences(dir)))) == ["claude@agent"]
end

end
