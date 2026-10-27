using Test

@testset "BeamletOpticsProjects" begin
    include(joinpath(@__DIR__, "TestPose.jl"))
    include(joinpath(@__DIR__, "TestLoad.jl"))
    include(joinpath(@__DIR__, "TestWrite.jl"))
    include(joinpath(@__DIR__, "TestNew.jl"))
    include(joinpath(@__DIR__, "TestStamp.jl"))
end
