module TestAqua

using Aqua, BeamletOpticsProjects
using Test

@testset "Aqua" begin
    Aqua.test_all(BeamletOpticsProjects)
end

end
