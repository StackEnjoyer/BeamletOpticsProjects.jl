module TestTrace

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using Test

const SYSTEM = """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, λ -> 1.5) pos = (0.0, 0.1, 0.0)
@component D1 = Detector(0.05) pos = (0.0, 0.15, 0.0)
@component D2 = Detector(0.01) pos = (0.2, 0.15, 0.0)
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.3, 0.0)
@source B1 = GaussianBeamlet([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6, 1.0e-3)
@source B2 = GaussianBeamlet([0.001, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6, 1.0e-3)
@source B3 = Beam([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 1.064e-6)
@system S1 = [L1, D1, D2] sources = [B1]
@system S2 = [L1, D1] sources = [B2, B3]
@source B4 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6)
@system S3 = [M1]
@system S4 = [D1] sources = [B4]
"""

function bench(system = SYSTEM)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nend\n")
    write(joinpath(dir, "system.jl"), system)
    return load_project(dir)
end

@testset "trace" begin
    p = bench()

    @testset "a beam through a lens onto a detector" begin
        r = trace(p, :S1)
        @test r.detectors[:D1].hits > 0
        # lossless: the detector receives the power of the source
        @test r.detectors[:D1].power ≈ BeamletOptics.optical_power(p[:B1]) atol = 1e-9
        # a detector without hits
        @test r.detectors[:D2] == (hits = 0, power = 0.0)
        @test Set(keys(r.detectors)) == Set([:D1, :D2])
        # the segments of the source, the last one ends on the detector
        @test r.segments == path_segments(p[:B1]; flen = 0.1)
        @test r.segments[1].start ≈ [0.0, 0.0, 0.0]
        @test r.segments[end].object === p[:D1]
        @test any(s -> s.object === p[:L1], r.segments)
    end

    @testset "tracing again gives the same numbers" begin
        r1 = trace(p, :S1)
        r2 = trace(p, :S1)
        @test r2.detectors == r1.detectors
        @test r2.segments == r1.segments
        # also after another system hit the shared detector
        trace(p, :S2)
        @test trace(p, :S1).detectors == r1.detectors
    end

    @testset "the sources of a system superpose; segments in their order" begin
        r = trace(p, :S2)
        @test r.detectors[:D1].hits == 1
        n = length(path_segments(p[:B2]; flen = 0.1))
        @test r.segments[1:n] == path_segments(p[:B2]; flen = 0.1)
        # B3 misses everything: a final segment of length flen
        last = r.segments[end]
        @test last.final && last.object === nothing
        @test norm(last.stop - last.start) ≈ 0.1
        @test norm(trace(p, :S2; flen = 0.5).segments[end].stop - last.start) ≈ 0.5
    end

    @testset "a system without sources or detectors" begin
        r = trace(p, :S3)
        @test isempty(r.segments) && isempty(r.detectors)
    end

    @testset "the hits of rays have no power" begin
        r = trace(p, :S4)
        @test r.detectors[:D1].hits == 1
        @test r.detectors[:D1].power === nothing
        # no hits: 0 W
        @test trace(p, :S1).detectors[:D2].power === 0.0
    end

    @testset "ids of the objects hit" begin
        r = trace(p, :S1)
        @test length(r.ids) == length(r.segments)
        @test r.ids isa Vector{Union{Nothing, Symbol}}
        @test r.ids == [seg.object === p[:L1] ? :L1 : seg.object === p[:D1] ? :D1 : nothing
                        for seg in r.segments]
        @test :L1 in r.ids && r.ids[end] === :D1
        # a final segment without a hit
        r = trace(p, :S2)
        @test r.ids[end] === nothing
        @test isempty(trace(p, :S3).ids)
    end

    @testset "an object inside a group is named by its outermost group" begin
        g = bench(replace(SYSTEM, "@system S2 = [L1, D1]" => "@system S2 = [G2, D1]", "@system S1 = [L1, D1, D2] sources = [B1]" =>
            "@group G1 = [L1, D2] pos = (0.0, 0.1, 0.0)\n@group G2 = [G1] pos = (0.0, 0.1, 0.0)\n@system S1 = [G2, D1] sources = [B1]"))
        r = trace(g, :S1)
        @test :G2 in r.ids
        @test !(:L1 in r.ids) && !(:G1 in r.ids)
        @test r.ids[end] === :D1
    end

    @testset "warnings of the solve" begin
        @test trace(p, :S1).warnings == String[]
        # the collector records warnings in order and swallows them
        l = BeamletOpticsProjects._WarningCollector()
        Base.CoreLogging.with_logger(l) do
            @info "not recorded"
            @warn "first"
            @error "second"
        end
        @test l.messages == ["first (Main.TestTrace)", "second (Main.TestTrace)"]
    end

    @test_throws KeyError trace(p, :S9)

    @testset "in the expression that loads the project" begin
        # the refractive index `λ -> 1.5` is defined while the expression runs
        m = Module()
        Core.eval(m, :(using BeamletOptics, BeamletOpticsProjects))
        r = Core.eval(m, :(trace(load_project($(p.path)), :S1)))
        @test r.detectors[:D1].hits == 1
    end
end

end
