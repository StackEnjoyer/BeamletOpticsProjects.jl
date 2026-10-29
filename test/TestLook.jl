module TestLook

using BeamletOptics, BeamletOpticsProjects
using Test

const SYSTEM = """
@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, λ -> 1.5) pos = (0.0, 0.1, 0.0) label = "Collimator"
@component D1 = Detector(0.05) pos = (0.0, 0.14, 0.0)
@component G1 = ObjectGroup([RoundPlanoMirror(0.0254, 0.006)]) pos = (0.5, 0.0, 0.0) rot = (0.0, 0.0, 45.0)
@component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (-0.5, 0.0, 0.0) rot = (0.0, 0.0, 45.0)
@component F1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.3, 0.0, 0.0)
@source B1 = GaussianBeamlet([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6, 1.0e-3)
@source B2 = CollimatedSource([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 0.005, 1.0e-6)
@source B3 = Beam([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 1.064e-6)
@source B4 = Beam([0.0, 0.0, 0.0], [0.0, 0.0, 1.0], 1.064e-6)
@source B5 = Beam([0.0, 0.0, 0.0], [-1.0, 0.0, 0.0], 1.064e-6)
@system S1 = [L1, D1] sources = [B1]
@system S2 = [L1, D1] sources = [B2]
@system S3 = [G1, M1] sources = [B3, B4, B5]
@source B6 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6) label = "Pump"
@system S4 = [D1] sources = [B6]
"""

function bench(; compat = "")
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "name = \"Bench\"\n" * compat)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nend\n")
    write(joinpath(dir, "system.jl"), SYSTEM)
    return load_project(dir)
end

"""The lines of the section `name` of the text of `look`."""
section(text, name) = split(rstrip(match(Regex("\\n$name\\n(.*?)(\\n[A-Z]|\\z)", "s"), text).captures[1], '\n'), '\n')

@testset "look" begin
    v = pkgversion(BeamletOptics)
    p = bench(; compat = "\n[compat]\nBeamletOptics = \"= $v\"\n")
    io = IOBuffer()
    text = look(p; io)
    @test String(take!(io)) == text

    @testset "environment" begin
        env = section(text, "Environment")
        @test "  BeamletOptics $v (project: = $v) at $(pkgdir(BeamletOptics))" in env
        @test "  BeamletOpticsProjects $(pkgversion(BeamletOpticsProjects))" in env
        @test "  Julia $VERSION" in env
    end

    @testset "systems: chains of ids, distances, detectors" begin
        segs = trace(p, :S1).segments
        @test [s.object for s in segs] == [p[:L1], p[:L1], p[:D1]]
        mm(x) = round(1e3 * x; digits = 1)
        systems = section(text, "Systems")
        @test "  S1 = [L1 \"Collimator\", D1], sources [B1]" in systems
        # the distance to an object from where the beam left the previous one
        @test "    B1 → L1 ($(mm(segs[1].s_stop)) mm) → D1 ($(mm(segs[3].s_stop - segs[3].s_start)) mm)" in systems
        @test "    D1: hits 1 · 1.0 mW" in systems
        # branches with the same chain are one line
        @test any(l -> startswith(l, "    B2 → L1 (") && endswith(l, "   ×$(length(trace(p, :S2).segments) ÷ 3)"), systems)
        # an object inside a group has the id of the group; a ray that leaves the system
        @test any(l -> startswith(l, "    B3 → G1 ("), systems)
        @test "    B4 → out" in systems
        @test "  S3 = [G1, M1], sources [B3, B4, B5]" in systems
        # the label of a source; the hits of rays have no power
        @test "  S4 = [D1], sources [B6 \"Pump\"]" in systems
        @test "    D1: hits 1 · rays, no power" in systems
    end

    @testset "an object without an id" begin
        q = bench()
        push!(q[:S3].objects, RoundPlanoMirror(0.0254, 0.006))
        BeamletOptics.translate3d!(q[:S3].objects[end], [0.0, 0.0, 0.2])
        BeamletOptics.xrotate3d!(q[:S3].objects[end], deg2rad(90))
        @test any(l -> startswith(l, "    B4 → ? ("), section(look(q; io = devnull), "Systems"))
    end

    @testset "free objects" begin
        @test section(text, "Free objects") == ["  F1 component at (300.0, 0.0, 0.0) mm"]
    end

    @testset "participants" begin
        @test section(text, "Participants") == ["  none"]
        mkpath(joinpath(p.path, ".bmo"))
        write(joinpath(p.path, ".bmo", "presence-claude@agent.toml"), """
            name = "Claude"
            kind = "agent"
            beat = 3
            selected_id = "L1"
            doing = "aligning"
            """)
        write(joinpath(p.path, ".bmo", "presence-broken.toml"), "name = ")
        # without an integer beat the protocol ignores the file
        write(joinpath(p.path, ".bmo", "presence-nobeat.toml"), "name = \"Ghost\"
")
        write(joinpath(p.path, ".bmo", "session-claude@agent.md"), "not a presence")
        people = section(look(p; io = devnull), "Participants")
        @test length(people) == 1 && startswith(only(people), "  claude@agent: Claude (agent) at L1 · aligning · last beat ")
        # a file older than its ttl is likely gone; several selected ids are listed
        file = joinpath(p.path, ".bmo", "presence-claude@agent.toml")
        write(file, "name = \"Claude\"
kind = \"agent\"
beat = 4
ttl = 60
selected_id = \"L1\"
selected_ids = [\"L1\", \"D1\"]
")
        io = IOBuffer()
        BeamletOpticsProjects._look_participants(io, p; now = mtime(file) + 600)
        @test occursin("at L1, D1 · last beat 600 s ago (likely gone)", String(take!(io)))
    end

    @testset "around" begin
        near = look(p; around = :D1, io = devnull)
        @test section(near, "Around D1 \\(within 50.0 mm\\)") ==
              ["  D1 at 0.0 mm", "  L1 \"Collimator\" at 40.0 mm"]
        systems = section(near, "Systems")
        @test any(l -> startswith(l, "    B1 → L1"), systems)
        @test "    D1: hits 1 · 1.0 mW" in systems
        # far objects, their systems and the beams that do not pass the near ones are not shown
        @test !any(l -> occursin("S3", l) || occursin("G1", l), systems)
        @test section(near, "Free objects") == ["  none"]
        @test_throws KeyError look(p; around = :X9, io = devnull)
    end

    @testset "in the expression that loads the project" begin
        m = Module()
        Core.eval(m, :(using BeamletOptics, BeamletOpticsProjects))
        text = Core.eval(m, :(look(load_project($(p.path)); io = devnull)))
        @test "    D1: hits 1 · 1.0 mW" in section(text, "Systems")
    end

    @testset "a system whose trace fails" begin
        q = bench()
        write(joinpath(q.path, "system.jl"), """
            @component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, λ -> λ == 1.064e-6 ? error("no glass\\nsecond line") : 1.5) pos = (0.0, 0.1, 0.0)
            @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.064e-6)
            @system S1 = [L1] sources = [B1]
            @system S2 = [L1]
            """)
        systems = section(look(load_project(q.path); io = devnull), "Systems")
        @test systems == ["  S1 = [L1], sources [B1]", "    trace failed: no glass",
            "  S2 = [L1], no sources"]
    end
end

end
