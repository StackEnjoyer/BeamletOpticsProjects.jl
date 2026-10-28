module TestTraceGroups

using BeamletOptics, BeamletOpticsProjects
using Test

const SYSTEM = """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.1, 0.0)
@component D1 = Detector(0.05) pos = (0.0, 0.15, 0.0)
@component D2 = Detector(0.05) pos = (0.0, 0.3, 0.0)
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.5, 0.0)
@source B1 = GaussianBeamlet([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6, 1.0e-3)
@group G1 = [L1, D1] pos = (0.0, 0.0, 0.0)
@group G2 = [G1, D2] pos = (0.0, 0.0, 0.0)
@system S1 = [G2, M1] sources = [B1]
"""

function bench(system = SYSTEM)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nend\n")
    write(joinpath(dir, "system.jl"), system)
    return load_project(dir)
end

@testset "detectors in groups" begin
    p = bench()
    r = trace(p, :S1)
    # a detector in a group (D2) and one in a nested group (D1)
    @test Set(keys(r.detectors)) == Set([:D1, :D2])
    @test r.detectors[:D1].hits > 0
    @test r.detectors[:D1].power ≈ BeamletOptics.optical_power(p[:B1]) atol = 1e-9

    io = IOBuffer()
    look(p; io)
    text = String(take!(io))
    @test occursin("D1: hits", text)
    @test occursin("D2: hits", text)
end

end
