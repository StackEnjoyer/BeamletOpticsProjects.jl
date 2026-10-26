module TestPose

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using Test

@testset "Pose" begin
    @test rotation_matrix(nothing) == I
    @test rotation_matrix((0.0, 0.0, 90.0)) == [0.0 -1.0 0.0; 1.0 0.0 0.0; 0.0 0.0 1.0]
    R = rotation_matrix((10.0, 20.0, 30.0))
    @test R * R' ≈ I atol = 1e-15
    lens = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
    apply_pose!(lens, (0.1, 0.2, 0.3), (0.0, 0.0, 90.0))
    @test BeamletOptics.position(lens) == [0.1, 0.2, 0.3]
    beam = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1e-6)
    apply_pose!(beam, (0.0, -0.05, 0.0), (0.0, 0.0, 90.0))
    @test BeamletOptics.position(beam) == [0.0, -0.05, 0.0]
    @test BeamletOptics.direction(beam) ≈ [-1.0, 0.0, 0.0] atol = 1e-15
end

end
