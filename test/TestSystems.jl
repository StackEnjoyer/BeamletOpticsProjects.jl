module TestSystems

using BeamletOptics, BeamletOpticsProjects
using Test

const P = BeamletOpticsProjects

const HEADER = "# BeamletOptics project \"Bench\" (format 1). Agents: see AGENTS.md.\n"

# Lines without a system; G1 holds L1 and M1
const LINES = HEADER * """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, ConstantRefractiveIndex(1.5)) pos = (0.0, 0.1, 0.0) uid = "u-l1"
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 45.0) uid = "u-m1"
@component D1 = Detector(0.02) pos = (0.0, 0.3, 0.0) uid = "u-d1"
@component D2 = Detector(0.02) pos = (-0.1, 0.2, 0.0) rot = (0.0, 0.0, 90.0) uid = "u-d2"
@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6) uid = "u-b1"
@source B2 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 0.532e-6) uid = "u-b2"
"""
const GROUPED = LINES * "@group G1 = [L1, M1] pos = (0.0, 0.15, 0.0) uid = \"u-g1\"\n"

function bench(system = LINES)
    dir = joinpath(mktempdir(), "Bench")
    mkpath(dir)
    write(joinpath(dir, "Bench.bmo"), "name = \"Bench\"\n")
    write(joinpath(dir, "system.jl"), system)
    return dir
end

text(dir) = read(joinpath(dir, "system.jl"))
system(p, id) = p.systems[findfirst(s -> s.name === id, p.systems)]

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

@testset "add_system!" begin
    @testset "from nothing to a traced system" begin
        dir = bench()
        @test add_system!(dir, [:L1, :D1]; sources = [:B1], by = "claude") === :S1
        p = load_project(dir)
        s = system(p, :S1)
        @test s.members == [:L1, :D1] && s.sources == [:B1]
        @test s.uid isa String && !isempty(s.uid)
        r = trace(p, :S1)
        @test r.detectors[:D1].hits > 0
        # the next one gets the next id; a source in ids goes to the sources and leaves S1
        @test add_system!(dir, [:M1, :D2, :B1]; label = "Fold") === :S2
        p = load_project(dir)
        @test system(p, :S2).members == [:M1, :D2] && system(p, :S2).sources == [:B1]
        @test system(p, :S2).label == "Fold"
        @test isempty(system(p, :S1).sources)
        # an empty system
        @test add_system!(dir) === :S3
        @test isempty(system(load_project(dir), :S3).members)
    end
    @testset "a given id" begin
        dir = bench()
        @test add_system!(dir, [:D1]; id = :Main) === :Main
        refused(() -> add_system!(dir, [:D1]; id = :Main), dir, :Main)
        refused(() -> add_system!(dir, [:D1]; id = :L1), dir, :L1)
        refused(() -> add_system!(dir, [:D1]; id = Symbol("not an id")), dir, "not an id")
    end
    @testset "refused: nothing is written" begin
        dir = bench(GROUPED)
        refused(() -> add_system!(dir, [:X9]), dir, :X9)
        refused(() -> add_system!(dir, [:D1]; sources = [:B9]), dir, :B9)
        # a member of a group without its group
        refused(() -> add_system!(dir, [:L1]), dir, :G1)
        @test add_system!(dir, [:G1, :D1]) === :S1
        @test system(load_project(dir), :S1).members == [:G1, :D1]
        # a system is no member
        refused(() -> add_system!(dir, [:S1]), dir, :S1)
        # a line claimed by another participant: the source that would leave its system
        @test join_system!(dir, :S1, [:B1]) isa Project
        @test claim!(dir; by = "anna@pc2", ids = [:S1])
        refused(() -> add_system!(dir, [:D2]; sources = [:B1], by = "ben@pc3"), dir, :S1)
    end
end

@testset "join_system! and leave_system!" begin
    dir = bench()
    add_system!(dir, [:L1, :D1]; sources = [:B1])
    add_system!(dir, [:M1, :D2]; sources = [:B2])
    p = join_system!(dir, :S1, [:M1, :B2, :D1]; by = "claude")
    @test p isa Project
    s1, s2 = system(p, :S1), system(p, :S2)
    # D1 was a member already; M1 is a member of both now; B2 left S2
    @test s1.members == [:L1, :D1, :M1] && s1.sources == [:B1, :B2]
    @test s2.members == [:M1, :D2] && isempty(s2.sources)
    p = leave_system!(dir, :S1, [:M1, :B1])
    @test system(p, :S1).members == [:L1, :D1] && system(p, :S1).sources == [:B2]
    # still lines of the project
    @test any(e -> e.name === :M1, p.entries) && any(e -> e.name === :B1, p.entries)
    @test system(p, :S2).members == [:M1, :D2]
    refused(() -> leave_system!(dir, :S1, [:M1]), dir, :M1)
    refused(() -> leave_system!(dir, :S9, [:L1]), dir, :S9)
    refused(() -> join_system!(dir, :S9, [:L1]), dir, :S9)
    refused(() -> join_system!(dir, :S1, [:X9]), dir, :X9)
    refused(() -> join_system!(dir, :S1, [:S2]), dir, :S2)
    @test claim!(dir; by = "anna@pc2", ids = [:S2])
    refused(() -> join_system!(dir, :S2, [:L1]; by = "ben@pc3"), dir, :S2)
    refused(() -> leave_system!(dir, :S2, [:M1]; by = "ben@pc3"), dir, :S2)
end

end
