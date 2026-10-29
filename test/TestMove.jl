module TestMove

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using Test

const P = BeamletOpticsProjects
const BMO = BeamletOptics

const HEADER = "# BeamletOptics project \"Bench\" (format 1). Agents: see AGENTS.md.\n"

# G2 holds the group G1 and M2; F1, D1 and the source B1 are in no group
const SYSTEM = HEADER * """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.1, 0.0) uid = "u-l1"
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 45.0) uid = "u-m1"
@component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.1, 0.2, 0.0) rot = (0.0, 0.0, -45.0) uid = "u-m2"
@component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0) uid = "u-d1"
@component F1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.2, 0.0, 0.0) rot = (10.0, 0.0, 20.0) uid = "u-f1"
@component K1 = RoundPlanoMirror(0.0254, 0.006) uid = "u-k1"
@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6) pos = (0.0, -0.05, 0.0) uid = "u-b1"
@group G1 = [L1, M1] pos = (0.0, 0.15, 0.0) rot = (0.0, 0.0, 10.0) uid = "u-g1"
@group G2 = [G1, M2] pos = (0.05, 0.2, 0.0) uid = "u-g2"
@system S1 = [G2, D1] sources = [B1] uid = "u-s1"
@system S2 = [F1, D1] uid = "u-s2"
"""

function bench(system = SYSTEM; src = nothing)
    dir = joinpath(mktempdir(), "Bench")
    mkpath(dir)
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), system)
    if !isnothing(src)
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "Bench.jl"), src)
    end
    return dir
end

entry(p, id) = p.entries[findfirst(e -> e.name === id, p.entries)]
group(p, id) = p.groups[findfirst(g -> g.name === id, p.groups)]
line_pos(x::Entry) = x.pos === nothing ? x.pose0[1] : collect(x.pos)
line_pos(x::GroupEntry) = collect(x.pos)

"""
Checks that every line `ids` of `b` is the line of `a` moved by `x ↦ c + R (x − c) + t`: positions
within 1e-12, rotations within 1e-13, and the built objects (positions, orientations, groups) too.
"""
function rigid(a, b, ids, c, R, t)
    for id in ids
        x, y = any(e -> e.name === id, a.entries) ? (entry(a, id), entry(b, id)) : (group(a, id), group(b, id))
        want = c + R * (line_pos(x) - c) + t
        @test maximum(abs, line_pos(y) - want) ≤ 1e-12
        @test maximum(abs, rotation_matrix(y.rot) - R * rotation_matrix(x.rot)) ≤ 1e-13
        @test maximum(abs, BMO.position(y.object) - want) ≤ 1e-12
        if y isa GroupEntry
            @test maximum(abs, BMO.orientation(y.object) - R * BMO.orientation(x.object)) ≤ 1e-12
        else
            @test maximum(abs, P.frame(y.object) - R * P.frame(x.object)) ≤ 1e-12
        end
    end
end

"""Checks that the lines `ids` of `b` are those of `a`."""
unchanged(a, b, ids) = for id in ids
    x, y = entry(a, id), entry(b, id)
    @test x.pos == y.pos && x.rot == y.rot
end

message(f) = try
    f()
    ""
catch err
    sprint(showerror, err)
end

@testset "move!" begin
    @testset "a component and a source about their center" begin
        dir = bench()
        a = load_project(dir)
        b = move!(dir, [:F1, :B1]; offset = (0.01, -0.02, 0.03), rot = (0, 0, 30))
        @test b isa Project
        R = rotation_matrix((0, 0, 30))
        c = (line_pos(entry(a, :F1)) + line_pos(entry(a, :B1))) / 2   # the pivot :center
        rigid(a, b, [:F1, :B1], c, R, [0.01, -0.02, 0.03])
        # the beam points along the turned direction
        @test maximum(abs, BMO.direction(b[:B1]) - R * BMO.direction(a[:B1])) ≤ 1e-13
        unchanged(a, b, [:L1, :M1, :M2, :D1, :K1])
        @test [g.pos for g in b.groups] == [g.pos for g in a.groups]
    end

    @testset "an offset alone keeps the angles of the lines" begin
        dir = bench()
        b = move!(dir, [:F1, :K1]; offset = (0.0, 0.5, 0.0))
        @test entry(b, :F1).pos == (0.2, 0.5, 0.0) && entry(b, :F1).rot == (10.0, 0.0, 20.0)
        # a line without pos gets the moved position, still no rot
        @test entry(b, :K1).pos == (0.0, 0.5, 0.0) && entry(b, :K1).rot === nothing
        @test occursin("@component F1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.2, 0.5, 0.0) rot = (10.0, 0.0, 20.0) uid",
            read(joinpath(dir, "system.jl"), String))
    end

    @testset "a nested group with all its members" begin
        dir = bench()
        a = load_project(dir)
        b = move!(dir, [:G2]; rot = (20, -35, 70), offset = (0.1, 0.2, -0.3))
        R = rotation_matrix((20, -35, 70))
        # the pivot :center of one group is its pivot
        rigid(a, b, [:G2, :G1, :L1, :M1, :M2], collect(group(a, :G2).pos), R, [0.1, 0.2, -0.3])
        unchanged(a, b, [:D1, :F1, :B1, :K1])
        # the members keep their distances
        d(p, x, y) = norm(line_pos(entry(p, x)) - line_pos(entry(p, y)))
        @test abs(d(b, :L1, :M2) - d(a, :L1, :M2)) ≤ 1e-12
    end

    @testset "a group, a member's group given too, and the pivot as an id or a point" begin
        dir = bench()
        a = load_project(dir)
        R = rotation_matrix((0, 0, 90))
        b = move!(dir, [:G2, :L1, :D1]; rot = (0, 0, 90), pivot = :D1)
        rigid(a, b, [:G2, :G1, :L1, :M1, :M2, :D1], line_pos(entry(a, :D1)), R, zeros(3))
        # 90° about z through D1 = (0, 0.3, 0): L1 at (0, 0.1, 0) goes to (0.2, 0.3, 0)
        @test maximum(abs, collect(entry(b, :L1).pos) - [0.2, 0.3, 0.0]) ≤ 1e-15
        c = load_project(dir)
        e = move!(dir, [:F1]; rot = (0, 0, 90), pivot = (0.0, 0.0, 0.0))
        rigid(c, e, [:F1], zeros(3), R, zeros(3))
        @test maximum(abs, collect(entry(e, :F1).pos) - [0.0, 0.2, 0.0]) ≤ 1e-15
    end

    @testset "system ids stand for their members and sources" begin
        dir = bench()
        a = load_project(dir)
        # S1 = [G2, D1] sources = [B1]: they move about the mean of the positions of the three
        b = move!(dir, [:S1]; offset = (0.0, 0.01, 0.0), rot = (0, 0, 20))
        c = (collect(group(a, :G2).pos) + line_pos(entry(a, :D1)) + line_pos(entry(a, :B1))) / 3
        rigid(a, b, [:G2, :G1, :L1, :M1, :M2, :D1, :B1], c, rotation_matrix((0, 0, 20)), [0.0, 0.01, 0.0])
        unchanged(a, b, [:F1, :K1])

        # a system and one of its members together: the member moves once
        dir = bench()
        b = move!(dir, [:S2, :D1]; offset = (0.0, 0.0, 0.5))
        @test entry(b, :D1).pos == (0.0, 0.3, 0.5)
        @test entry(b, :F1).pos == (0.2, 0.0, 0.5)
        # S1 and S2 share D1, which also moves once
        dir = bench()
        b = move!(dir, [:S1, :S2]; offset = (0.0, 0.0, 0.5))
        @test entry(b, :D1).pos == (0.0, 0.3, 0.5)
        @test maximum(abs, collect(entry(b, :B1).pos) - [0.0, -0.05, 0.5]) ≤ 1e-15
        @test collect(group(b, :G2).pos) ≈ [0.05, 0.2, 0.5]
        # a member inside a group still needs its group, also next to a system
        dir = bench()
        @test occursin("G1", message(() -> move!(dir, [:S2, :L1])))
    end

    @testset "errors name the id" begin
        dir = bench()
        before = read(joinpath(dir, "system.jl"), String)
        @test_throws ArgumentError move!(dir, [:X9])
        @test occursin("X9", message(() -> move!(dir, [:F1, :X9])))
        @test occursin("Q7", message(() -> move!(dir, [:F1]; pivot = :Q7)))
        # a member without its group
        m = message(() -> move!(dir, [:L1]))
        @test occursin("L1", m) && occursin("G1", m) && occursin("move the group `G2`", m)
        @test occursin("G1", message(() -> move!(dir, [:G1, :F1])))
        @test_throws ArgumentError move!(dir, [:F1]; offset = (1, 2))
        @test read(joinpath(dir, "system.jl"), String) == before
    end

    @testset "claims and a change meanwhile" begin
        dir = bench()
        before = read(joinpath(dir, "system.jl"), String)
        @test claim!(dir; by = "anna@pc2", ids = [:M1])
        # M1 is inside G2: moving the group changes its line
        m = message(() -> move!(dir, [:G2]; offset = (0.0, 0.01, 0.0), by = "ben@pc3"))
        @test occursin("M1", m) && occursin("anna@pc2", m)
        @test read(joinpath(dir, "system.jl"), String) == before
        # the holder may; others may move what is not claimed
        b = move!(dir, [:G2]; offset = (0.0, 0.01, 0.0), by = "anna@pc2")
        @test maximum(abs, collect(entry(b, :M1).pos) - [0.0, 0.21, 0.0]) ≤ 1e-15
        b = move!(dir, [:F1]; offset = (0.0, 0.01, 0.0), by = "ben@pc3")
        @test entry(b, :F1).pos == (0.2, 0.01, 0.0)
        release!(dir; by = "anna@pc2")

        # the own code changes the files while the project loads: ProjectChanged, nothing written
        hook = """
        module Bench
        let f = joinpath(@__DIR__, "extra.jl")
            isfile(f) || write(f, "# written while loading\\n")
        end
        end
        """
        dir = bench(; src = hook)
        before = read(joinpath(dir, "system.jl"), String)
        @test_throws ProjectChanged move!(dir, [:F1]; offset = (0.0, 0.01, 0.0))
        @test read(joinpath(dir, "system.jl"), String) == before
        # the next load sees no change
        @test entry(move!(dir, [:F1]; offset = (0.0, 0.01, 0.0)), :F1).pos == (0.2, 0.01, 0.0)
    end
end

end
