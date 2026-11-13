module TestCode

using BeamletOptics, BeamletOpticsProjects
using Test

const P = BeamletOpticsProjects

# An own type of a project with two shape parameters, which tells its constructor
const MODULE = """
module Bench
using BeamletOptics
import ..BeamletOpticsProjects
export Block

struct Block{T} <: BeamletOptics.AbstractObject{T}
    shape::BeamletOptics.PlanoSurfaceSDF{T}
    width::T
    thickness::T
end

Block(width, thickness) = Block(BeamletOptics.PlanoSurfaceSDF(thickness, width), width, thickness)

# Absorbs the rays that hit it
BeamletOptics.interact3d(::BeamletOptics.AbstractSystem, ::Block, ::Beam, ::Ray) = nothing

BeamletOpticsProjects.constructor_code(b::Block) = "Block(\$(b.width), \$(b.thickness))"
end
"""

const SYSTEM = """
@component K1 = Block(0.02, 0.005) pos = (0.0, 0.1, 0.0) rot = (0.0, 0.0, 10.0)
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.3, 0.0)
@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6)
@system S1 = [K1, M1] sources = [B1]
"""

function bench(; gui = nothing)
    dir = mktempdir()
    write(joinpath(dir, "Bench.bmo"), "name = \"Bench\"\n")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "Bench.jl"), MODULE)
    isnothing(gui) || write(joinpath(dir, "src", "gui.jl"), gui)
    write(joinpath(dir, "system.jl"), SYSTEM)
    return dir
end

@testset "constructor_code: nothing without a method" begin
    for x in (RoundPlanoMirror(0.0254, 0.006), Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6),
              Detector(0.02), 1, "x", nothing, [1, 2])
        @test constructor_code(x) === nothing
    end
end

@testset "constructor_code: the method of an own type of a project" begin
    dir = bench()
    p = load_project(dir)
    k = p[:K1]
    # The method was defined by load_project, in a newer world
    code = Base.invokelatest(constructor_code, k)
    @test code == "Block(0.02, 0.005)"
    # The objects of BeamletOptics in the same project have none
    @test Base.invokelatest(constructor_code, p[:M1]) === nothing
    # The code builds the object as it is, in the module of the project
    b = Base.invokelatest(Core.eval, p.mod, Meta.parse(code))
    @test typeof(b) == typeof(k) && b.width == k.width && b.thickness == k.thickness
    # A change of the shape goes to the line; the pose stays
    set!(dir, :K1; code = "Block(0.03, 0.004)")
    q = load_project(dir)
    @test Base.invokelatest(constructor_code, q[:K1]) == "Block(0.03, 0.004)"
    @test pose(q, :K1).pos == pose(p, :K1).pos
    @test pose(q, :K1).rot ≈ pose(p, :K1).rot
    # The project traces with its own type
    r = trace(q, :S1)
    @test :K1 in r.ids
end

@testset "src/gui.jl: the window's part" begin
    gui = """
        using BeamletOpticsGUI
        using NotInstalledXyz
        BeamletOpticsGUI.card_rows(b::Bench.Block) = ()
        """
    dir = bench(; gui)
    # load_project never includes it: a package that is not installed does not matter
    p = load_project(dir)
    @test Base.invokelatest(constructor_code, p[:K1]) == "Block(0.02, 0.005)"
    @test !Base.invokelatest(isdefined, p.mod, :NotInstalledXyz)
    # Its packages are not the project's
    @test isempty(P._used_packages(dir, ("Bench",)))
    save_project(p)
    @test isempty(project_versions(dir).packages)
    # A file gui.jl elsewhere in src/ is own code like any other
    mkpath(joinpath(dir, "src", "parts"))
    write(joinpath(dir, "src", "parts", "gui.jl"), "using TOML\n")
    @test P._used_packages(dir, ("Bench",)) == Set(["TOML"])
    rm(joinpath(dir, "src", "parts"); recursive = true)
    # A change of it is a change of the project
    s = project_stamp(dir)
    write(joinpath(dir, "src", "gui.jl"), gui * "# changed\n")
    @test project_stamp(dir) != s
end

end
