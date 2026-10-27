using Test

@testset "BeamletOpticsProjects" begin
    include(joinpath(@__DIR__, "TestPose.jl"))
    include(joinpath(@__DIR__, "TestLoad.jl"))
    include(joinpath(@__DIR__, "TestWrite.jl"))
    include(joinpath(@__DIR__, "TestNew.jl"))
    include(joinpath(@__DIR__, "TestStamp.jl"))
    include(joinpath(@__DIR__, "TestIds.jl"))
    include(joinpath(@__DIR__, "TestDiff.jl"))
    include(joinpath(@__DIR__, "TestVersions.jl"))
    include(joinpath(@__DIR__, "TestMerge.jl"))
    include(joinpath(@__DIR__, "TestAgentSkill.jl"))
    include(joinpath(@__DIR__, "TestTrace.jl"))
    include(joinpath(@__DIR__, "TestLook.jl"))
    include(joinpath(@__DIR__, "TestParticipants.jl"))
    include(joinpath(@__DIR__, "TestTeams.jl"))
    include(joinpath(@__DIR__, "TestGuards.jl"))
end
