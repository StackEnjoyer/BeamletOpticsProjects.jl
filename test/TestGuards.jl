module TestGuards

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using Test

const BASE = """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, λ -> 1.5) pos = (0.0, 0.1, 0.0)
@component D1 = Detector(0.05) pos = (0.0, 0.15, 0.0)
@source B1 = GaussianBeamlet([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6, 1.0e-3)
@system S1 = [L1, D1] sources = [B1]
"""

function project(system)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nend\n")
    write(joinpath(dir, "system.jl"), system)
    return load_project(dir)
end

@testset "evaluate" begin
    base = project(BASE)

    @testset "an unchanged project deviates by exactly 0" begin
        r = evaluate(project(BASE); base)
        d = r.deviations[:S1]
        @test d.position === 0.0
        @test d.objects == 0
        @test d.segments.base == d.segments.project > 0
        @test d.detectors[:D1] == (hits = 0, power = 0.0)
        @test isempty(r.foreign_hits) && isempty(r.clearance)
    end

    @testset "a moved lens: position and power are measured, not judged" begin
        moved = replace(BASE, "pos = (0.0, 0.1, 0.0)" => "pos = (0.01, 0.1, 0.0)")
        d = evaluate(project(moved); base).deviations[:S1]
        @test d.position > 0
        @test keys(d.detectors) == Set([:D1])
        # the shift of a detector reading is the plain difference
        a, b = trace(base, :S1), trace(project(moved), :S1)
        @test d.detectors[:D1].power == b.detectors[:D1].power - a.detectors[:D1].power
        @test d.detectors[:D1].hits == b.detectors[:D1].hits - a.detectors[:D1].hits
    end

    @testset "other hit objects and other numbers of segments are reported" begin
        # without the lens the beam ends on the detector one segment earlier
        gone = replace(BASE, "@component L1" => "#", "[L1, D1]" => "[D1]")
        d = evaluate(project(gone); base).deviations[:S1]
        @test d.segments.base != d.segments.project
        @test d.objects > 0
    end

    @testset "an object inside a group has the id of the group" begin
        group = """
        @component G1 = ObjectGroup([RoundPlanoMirror(0.0254, 0.006)]) pos = (0.5, 0.0, 0.0) rot = (0.0, 0.0, 45.0)
        @source B1 = Beam([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 1.064e-6)
        @system S1 = [G1] sources = [B1]
        """
        gbase = project(group)
        extra = group * """
        @component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.5, 0.0)
        @source B2 = Beam([0.0, 0.001, 0.0], [1.0, 0.0, 0.0], 1.064e-6)
        @system S2 = [G1, M2] sources = [B2]
        """
        r = evaluate(project(extra); base = gbase)
        @test [(h.system, h.source, h.object) for h in r.foreign_hits] == [(:S2, :B2, :G1)]
        @test r.deviations[:S1].objects == 0
        # a beam that now ends on a child of another group is another object
        other = replace(group, "@component G1" => "@component G9", "[G1]" => "[G9]")
        @test evaluate(project(other); base = gbase).deviations[:S1].objects > 0
    end

    @testset "the power change is nothing for the hits of rays" begin
        rays = BASE * "@source B3 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6)\n" *
               "@system S3 = [D1] sources = [B3]\n"
        d = evaluate(project(rays); base = project(rays)).deviations[:S3]
        @test d.detectors[:D1] == (hits = 0, power = nothing)
        @test d.position === 0.0
    end

    @testset "a system that is gone is nothing" begin
        none = replace(BASE, "@system S1 = [L1, D1] sources = [B1]" => "")
        @test evaluate(project(none); base).deviations[:S1] === nothing
    end

    @testset "hits of new sources on old objects, clearance of new objects" begin
        extra = BASE * """
        @component M2 = RoundPlanoMirror(0.0254, 0.006) pos = (0.3, 0.5, 0.0)
        @source B2 = Beam([0.0, 0.3, 0.0], [0.0, -1.0, 0.0], 1.064e-6)
        @system S2 = [M2, D1] sources = [B2]
        """
        p = project(extra)
        r = evaluate(p; base)
        # the old system is not touched by the new object
        @test r.deviations[:S1].position === 0.0
        @test length(r.foreign_hits) == 1
        h = only(r.foreign_hits)
        @test (h.system, h.source, h.object) == (:S2, :B2, :D1)
        @test h.at ≈ [0.0, 0.15, 0.0] atol = 1e-3
        # M2 is the only new object with a sphere, the lens and detector are old; sources are left out
        @test length(r.clearance) == 1
        c = only(r.clearance)
        sm = BeamletOptics.bounding_sphere_of(p[:M2])
        gap(n) = (so = BeamletOptics.bounding_sphere_of(p[n]); norm(sm.pos - so.pos) - sm.radius - so.radius)
        # the minimum over the old objects, not the first one
        @test gap(:D1) < gap(:L1)
        @test c.object === :M2 && c.nearest === :D1
        @test c.distance ≈ min(gap(:L1), gap(:D1))

        # two new objects: sorted ascending
        two = extra * "@component M3 = RoundPlanoMirror(0.0254, 0.006) pos = (0.3, 0.2, 0.0)\n"
        cl = evaluate(project(two); base).clearance
        @test [c.object for c in cl] == [:M3, :M2]
        @test issorted(c.distance for c in cl)
    end
end

end
