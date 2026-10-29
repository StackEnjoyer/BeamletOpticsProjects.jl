module TestLoad

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using Test

const P = BeamletOpticsProjects

const SYSTEM = """
# BeamletOptics project "Bench" (format 1). Agents: see AGENTS.md.
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, (λ->1.5)) pos = (0.0, 0.1, 0.0) catalog = ("Spherical lens", ["50", "-50", "5", "25.4", "1.5"])
@component M1 = RightAnglePrismMirror(0.025, 0.025) pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 90.0)
@component L2 = bench_lens(0.1) pos = (0.03, 0.2, 0.0) rot = (12.5, -3.25, 37.0)
@component D1 = Detector(0.02) pos = (0.1, 0.2, 0.0)
@component F1 = RoundPlanoMirror(0.0254, 0.006)
@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6) pos = (0.0, -0.05, 0.0)
@source B2 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 6.33e-7) rot = (0.0, 0.0, -90.0)
@system S1 = [L1, M1, L2, D1] sources = [B1]
@system S2 = [L1, D1]
"""

const MODULE = """
module Bench
using BeamletOptics
export bench_lens
bench_lens(f) = SphericalLens(f, -f, 0.004, 0.0254, 1.5)
end
"""

function project_dir(system = SYSTEM; mod = MODULE)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "Bench.jl"), mod)
    write(joinpath(dir, "system.jl"), system)
    return dir
end

"""The message of the error that `f` throws, with the causes of a `LoadError`."""
function message(f)
    try
        f()
    catch err
        return sprint(showerror, err)
    end
    return ""
end

@testset "load_project" begin
    p = load_project(project_dir())
    @test p.name == "Bench"
    @test [e.name for e in p.entries] == [:L1, :M1, :L2, :D1, :F1, :B1, :B2]
    @test [e.kind for e in p.entries] == [:component, :component, :component, :component,
        :component, :source, :source]
    @test p[:L1] isa Lens && p["B1"] isa Beam
    @test p.entries[1].meta == [:catalog => ("Spherical lens", ["50", "-50", "5", "25.4", "1.5"])]
    @test p.entries[3].code == :(bench_lens(0.1))

    @testset "poses" begin
        for e in p.entries
            e.pos === nothing || @test BeamletOptics.position(e.object) == collect(e.pos)
            R = P.frame(e.object)
            @test maximum(abs, R - rotation_matrix(e.rot) * e.pose0[2]) < 1e-14
        end
        # Without pos the position is the constructed one, rotated about itself
        @test BeamletOptics.position(p[:F1]) == p.entries[5].pose0[1]
        @test BeamletOptics.direction(p[:B2]) ≈ [1.0, 0.0, 0.0] atol = 1e-15
    end

    @testset "systems" begin
        s1, s2 = p.systems
        @test s1.name === :S1 && s1.members == [:L1, :M1, :L2, :D1] && s1.sources == [:B1]
        @test s2.sources == Symbol[] && !s2.static
        @test p[:S1] isa System && p[:S1] === s1.object
        @test p[:L1] in p[:S1].objects && p[:L1] in p[:S2].objects
        @test !(p[:F1] in p[:S1].objects)
    end

    @testset "text round trip" begin
        code = system_code(p)
        @test code == SYSTEM
        dir = project_dir(code)
        @test system_code(load_project(dir)) == code
    end
end

@testset "errors" begin
    function load_with(lines...)
        text = join(["# header", lines...], "\n") * "\n"
        return message(() -> load_project(project_dir(text)))
    end
    lens = "@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
    beam = "@source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)"
    m = load_with(lens, lens)
    @test occursin("`L1` is used twice", m) && occursin("system.jl:3", m)
    m = load_with(lens, "@system S1 = [L1, X9]")
    @test occursin("unknown component `X9`", m) && occursin("system.jl:3", m)
    m = load_with(lens, beam, "@system S1 = [L1] sources = [B1]", "@system S2 = [L1] sources = [B1]")
    @test occursin("`B1` is already in the system `S1`", m) && occursin("system.jl:5", m)
    m = load_with(lens, beam, "@system S1 = [L1, B1]")
    @test occursin("`B1` is a source", m)
    m = load_with(lens, "@component L2 = SphericalLens(0.05, -0.05,")
    @test occursin("system.jl:3", m)
    m = load_with("@component L1 SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)")
    @test occursin("system.jl:2", m) && occursin("name = ...", m)
    @test_throws ArgumentError load_project(mktempdir())
end

@testset "a file half written by another participant is loaded again" begin
    whole = "# header\n@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)\n"
    dir = project_dir(whole[1:end-30])
    file = joinpath(dir, "system.jl")
    # the writer finishes while the first load fails
    writer = @async (sleep(0.1); write(file, whole))
    p = load_project(dir)
    wait(writer)
    @test only(p.entries).name === :L1
    # a file that stays broken throws, after one wait
    write(file, whole[1:end-30])
    t = @elapsed(@test_throws Exception load_project(dir))
    @test t < 2.0
end

@testset "a system before its members" begin
    p = load_project(project_dir("""
        @system S1 = [L1, T1] sources = [B1]
        @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
        @component T1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
        @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6)
        """))
    @test p[:T1] in p[:S1].objects && p[:L1] in p[:S1].objects
end

@testset "include without a project" begin
    # A plain include builds and poses the objects and binds them to their names
    mod = Module()
    Core.eval(mod, :(using BeamletOptics, BeamletOpticsProjects))
    Core.eval(mod, :(bench_lens(f) = SphericalLens(f, -f, 0.004, 0.0254, 1.5)))
    Base.include_string(mod, SYSTEM, "system.jl")
    @test BeamletOptics.position(mod.L1) == [0.0, 0.1, 0.0]
    @test mod.S1 isa System && mod.L2 in mod.S1.objects
end

end
