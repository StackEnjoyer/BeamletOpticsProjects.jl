module TestQuery

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using Test

const P = BeamletOpticsProjects
const BMO = BeamletOptics


const SYSTEM = """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, λ -> 1.5) pos = (0.0, 0.1, 0.0) rot = (0.0, 0.0, 30.0)
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.3, 0.0)
@component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.1, 0.3, 0.0)
@component D1 = Detector(0.05) pos = (0.0, 0.15, 0.0)
@component K1 = RoundPlanoMirror(0.0254, 0.006)
@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6)
@group G1 = [M1, M2] pos = (0.05, 0.3, 0.0) rot = (0.0, 0.0, 10.0)
@system S1 = [L1, D1, G1] sources = [B1]
@system S2 = [K1]
"""

function bench(system = SYSTEM)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nend\n")
    write(joinpath(dir, "system.jl"), system)
    return dir
end

entry(p, id) = p.entries[findfirst(e -> e.name === id, p.entries)]

message(f) = try
    f()
    ""
catch err
    sprint(showerror, err)
end

@testset "Query" begin
    dir = bench()
    p = load_project(dir)

    @testset "members and sources" begin
        @test P.members(p, :S1) == [:L1, :D1, :G1]
        @test P.sources(p, :S1) == [:B1]
        @test P.members(p, :S2) == [:K1]
        @test P.sources(p, :S2) == Symbol[]
        # a copy: changing it does not change the project
        push!(P.members(p, :S2), :X)
        @test P.members(p, :S2) == [:K1]
        @test occursin("S9", message(() -> P.members(p, :S9)))
        @test_throws ArgumentError P.sources(p, :S9)
    end

    @testset "pose" begin
        a = P.pose(p, :L1)
        @test a.pos == (0.0, 0.1, 0.0)
        @test a.rot == rotation_matrix((0.0, 0.0, 30.0))
        g = P.pose(p, :G1)
        @test g.pos == (0.05, 0.3, 0.0)
        @test g.rot == rotation_matrix((0.0, 0.0, 10.0))
        # a line without pos and rot: the position of its object, no rotation (as the line says)
        k = P.pose(p, :K1)
        @test collect(k.pos) == BMO.position(p[:K1])
        @test k.rot == Matrix{Float64}(I, 3, 3)
        # a source: its position, no rotation since construction
        b = P.pose(p, :B1)
        @test b.pos == (0.0, 0.0, 0.0)
        @test b.rot == Matrix{Float64}(I, 3, 3)
        @test_throws ArgumentError P.pose(p, :S1)
        @test occursin("X9", message(() -> P.pose(p, :X9)))
    end

    @testset "moved: a copy in memory, nothing written" begin
        before = read(joinpath(dir, "system.jl"), String)
        r1 = trace(p, :S1)
        q = P.moved(p, [:S1]; offset = (0.01, 0.0, 0.0))
        @test q !== p
        @test read(joinpath(dir, "system.jl"), String) == before
        # p is unchanged: lines and objects
        @test entry(p, :L1).pos == (0.0, 0.1, 0.0)
        @test BMO.position(p[:L1]) == [0.0, 0.1, 0.0]
        @test P.pose(p, :G1).pos == (0.05, 0.3, 0.0)
        # the copy: lines and objects moved
        @test maximum(abs, collect(entry(q, :L1).pos) - [0.01, 0.1, 0.0]) ≤ 1e-15
        @test maximum(abs, BMO.position(q[:L1]) - [0.01, 0.1, 0.0]) ≤ 1e-15
        @test maximum(abs, BMO.position(q[:M2]) - [0.11, 0.3, 0.0]) ≤ 1e-15
        @test maximum(abs, BMO.position(q[:B1]) - [0.01, 0.0, 0.0]) ≤ 1e-15
        @test maximum(abs, collect(P.pose(q, :G1).pos) - [0.06, 0.3, 0.0]) ≤ 1e-15
        # traceable: the segments are those of p shifted by the offset
        r2 = trace(q, :S1)
        @test length(r2.segments) == length(r1.segments)
        @test r2.segments[1].start ≈ r1.segments[1].start + [0.01, 0.0, 0.0] atol = 1e-12
        @test r2.detectors[:D1].hits > 0
        # and p still traces as before
        @test trace(p, :S1).segments == r1.segments
    end

    @testset "moved: a turn matches move!" begin
        dir2 = bench()
        p2 = load_project(dir2)
        q = P.moved(p2, [:L1, :G1, :B1]; rot = (0, 0, 25), offset = (0.0, 0.02, 0.0), pivot = :D1)
        w = move!(dir2, [:L1, :G1, :B1]; rot = (0, 0, 25), offset = (0.0, 0.02, 0.0), pivot = :D1)
        for id in (:L1, :M1, :M2, :B1, :K1, :D1)
            @test maximum(abs, BMO.position(q[id]) - BMO.position(w[id])) ≤ 1e-12
            @test maximum(abs, P.frame(q[id]) - P.frame(w[id])) ≤ 1e-12
        end
        @test maximum(abs, BMO.orientation(q[:G1]) - BMO.orientation(w[:G1])) ≤ 1e-12
        @test maximum(abs, BMO.position(q[:G1]) - BMO.position(w[:G1])) ≤ 1e-12
        # unknown ids and members of a group alone throw, as for move!
        @test_throws ArgumentError P.moved(p2, [:X9])
        @test_throws ArgumentError P.moved(p2, [:M1])
    end
end

end
