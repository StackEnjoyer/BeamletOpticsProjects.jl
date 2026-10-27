module TestIds

using BeamletOptics, BeamletOpticsProjects
using Test

const P = BeamletOpticsProjects

function project_dir(system)
    dir = mktempdir()
    new_project(dir; name = "Bench")
    write(joinpath(dir, "system.jl"), system)
    return dir
end

message(f) = try
    f()
    ""
catch err
    sprint(showerror, err)
end

@testset "id_prefix and next_id" begin
    @test id_prefix(SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)) == "L"
    @test id_prefix(RoundPlanoMirror(0.0254, 0.006)) == "M"
    @test id_prefix(Detector(0.02)) == "D"
    @test id_prefix(RoundThinBeamsplitter(0.0254)) == "BS"
    @test id_prefix(RightAnglePrism(0.01, 0.01, 1.5)) == "P"
    @test id_prefix(Beam([0.0, 0, 0], [0.0, 1, 0], 1e-6)) == "B"
    @test id_prefix(System()) == "S"
    @test id_prefix(1.0) == "X"
    p = load_project(project_dir("""
        @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
        @component L3 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
        @component BS2 = RoundThinBeamsplitter(0.0254)
        """))
    @test next_id(p, "L") === :L4 && next_id(p, "BS") === :BS3 && next_id(p, "B") === :B1
    @test next_id(p, "M") === :M1
end

@testset "label and uid" begin
    text = """
        @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.1, 0.0) label = "Kollimator" uid = "u-1"
        @component M1 = RoundPlanoMirror(0.0254, 0.006)
        @system S1 = [L1, M1] label = "Arm" uid = "u-2"
        """
    dir = project_dir(text)
    p = load_project(dir)
    @test p.entries[1].label == "Kollimator" && p.entries[1].uid == "u-1"
    @test isnothing(p.entries[2].label) && isnothing(p.entries[2].uid)
    @test p.systems[1].label == "Arm" && p.systems[1].uid == "u-2"
    @test isempty(p.entries[1].meta)
    lines = split(system_code(p), "\n")
    @test endswith(lines[2], "pos = (0.0, 0.1, 0.0) label = \"Kollimator\" uid = \"u-1\"")
    @test endswith(lines[4], "@system S1 = [L1, M1] label = \"Arm\" uid = \"u-2\"")
    # Saving gives the missing uids, which stay from then on
    save_project(p)
    q = load_project(dir)
    @test q.entries[1].uid == "u-1" && !isnothing(q.entries[2].uid)
    @test length(q.entries[2].uid) == 36
    save_project(q)
    @test load_project(dir).entries[2].uid == q.entries[2].uid
    # A copied line with its uid: an error naming the line
    m = message(() -> load_project(project_dir("""
        @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) uid = "u-1"
        @component L2 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) uid = "u-1"
        """)))
    @test occursin("uid \"u-1\" is used twice", m) && occursin("system.jl:2", m)
end

end
