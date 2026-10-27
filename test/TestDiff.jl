module TestDiff

using BeamletOptics, BeamletOpticsProjects
using Test

function load(text; mod = "")
    dir = mktempdir()
    new_project(dir; name = "Bench")
    isempty(mod) || write(joinpath(dir, "src", "Bench.jl"), mod)
    write(joinpath(dir, "system.jl"), text)
    return load_project(dir)
end

kinds(d) = [(c.kind, something(c.new, c.old).name) for c in d.entries]
skinds(d) = [(c.kind, something(c.new, c.old).name) for c in d.systems]

const LENS = "SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)"
const BASE = """
    @component L1 = $LENS pos = (0.0, 0.1, 0.0) uid = "a"
    @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.2, 0.0) uid = "b"
    @component D1 = Detector(0.02) uid = "c"
    @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6) uid = "d"
    @system S1 = [L1, M1, D1] sources = [B1] uid = "s"
    """

@testset "diff_projects" begin
    base = load(BASE)
    @test isempty(diff_projects(base, load(BASE)).entries)
    @test isempty(diff_projects(base, load(BASE)).systems)
    # The order of the lines does not matter
    lines = split(BASE, "\n"; keepempty = false)
    @test isempty(diff_projects(base, load(join(lines[[3, 1, 2, 4, 5]], "\n") * "\n")).entries)

    new = load("""
        @component Lx = $LENS pos = (0.0, 0.1, 0.0) label = "Kollimator" uid = "a"
        @component M1 = RoundPlanoMirror(0.0254, 0.006) pos = (0.0, 0.25, 0.0) rot = (0.0, 0.0, 45.0) uid = "b"
        @component T1 = $LENS
        @source B1 = Beam([0.0, 0.0, 0.0], [0.0, 1.0, 0.0], 1.0e-6) note = 1 uid = "d"
        @system S1 = [Lx, M1, T1] sources = [B1] uid = "s"
        @system S2 = [T1]
        """)
    d = diff_projects(base, new)
    @test kinds(d) == [(:removed, :D1), (:renamed, :Lx), (:moved, :M1), (:relabeled, :Lx),
        (:meta, :B1), (:added, :T1)]
    # The members are compared by uid: the renamed L1 is still a member
    @test skinds(d) == [(:members, :S1), (:added, :S2)]
    c = d.entries[2]
    @test c.uid == "a" && c.old.name === :L1 && c.new.name === :Lx

    # Other code, and the code that calls own code
    d = diff_projects(base, load(replace(BASE, "Detector(0.02)" => "Detector(0.03)")))
    @test kinds(d) == [(:rebuilt, :D1)]
    d = diff_projects(base, load(BASE); rebuild = [:M1])
    @test kinds(d) == [(:rebuilt, :M1)]
    # A move by a tiny rotation is a move; noise below 1e-13 is none
    d = diff_projects(base, load(replace(BASE, "pos = (0.0, 0.2, 0.0)" => "pos = (0.0, 0.2, 0.0) rot = (0.0, 0.0, 1.0e-6)")))
    @test kinds(d) == [(:moved, :M1)]
    # A file of an agent before the first save: no uids, paired by the readable id
    plain = replace(BASE, r" uid = \"[a-z]\"" => "")
    b2 = load(plain)
    @test isempty(diff_projects(b2, load(plain)).entries)
    @test kinds(diff_projects(b2, load(replace(plain, "Detector(0.02)" => "Detector(0.03)")))) ==
          [(:rebuilt, :D1)]
    # Static and sources of a system
    d = diff_projects(base, load(replace(BASE, "sources = [B1] uid" => "uid")))
    @test skinds(d) == [(:members, :S1)]
end

@testset "copy_code" begin
    from, to = mktempdir(), mktempdir()
    mkpath(joinpath(from, "src", "sub"))
    write(joinpath(from, "src", "A.jl"), "a")
    write(joinpath(from, "src", "sub", "B.jl"), "b")
    write(joinpath(from, "system.jl"), "x")
    mkpath(joinpath(to, "src"))
    write(joinpath(to, "src", "A.jl"), "kept")
    copy_code(from, to)
    @test read(joinpath(to, "src", "A.jl"), String) == "kept"
    @test read(joinpath(to, "src", "sub", "B.jl"), String) == "b"
    @test !isfile(joinpath(to, "system.jl"))
    @test isnothing(copy_code(mktempdir(), to))
end

end
