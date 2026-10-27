module TestWrite

using BeamletOptics, BeamletOpticsProjects
using LinearAlgebra
using TOML
using Test

const P = BeamletOpticsProjects

lens() = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)
entry(name, rot; pos = (0.0, 0.0, 0.0)) =
    Entry(:component, name, :(SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)), lens(); pos, rot,
        pose0 = P.pose_of(lens()))
line(e) = split(system_code(Project(mktempdir(), "X"; entries = [e])), "\n")[2]

@testset "_write_atomic retries the move" begin
    file = joinpath(mktempdir(), "system.jl")
    calls = Ref(0)
    flaky(n) = (tmp, f; force) -> (calls[] += 1; calls[] <= n ? throw(SystemError("rename", 32)) :
                                   mv(tmp, f; force))
    P._write_atomic(file, "a"; move = flaky(3), wait = 0.0)
    @test read(file, String) == "a" && calls[] == 4
    calls[] = 0
    @test_throws SystemError P._write_atomic(file, "b"; move = flaky(100), wait = 0.0)
    @test calls[] == 10 && read(file, String) == "a"
    # Other errors are not retried
    calls[] = 0
    @test_throws ErrorException P._write_atomic(file, "c"; wait = 0.0,
        move = (a, b; force) -> (calls[] += 1; error("x")))
    @test calls[] == 1
end

@testset "rotations" begin
    noisy = rotation_matrix((0.0, 0.0, 90.0)) + 1e-16 * [1 0 0; 0 -1 0; 0 0 1]
    @test endswith(line(entry(:A, noisy)), "rot = (0.0, 0.0, 90.0)")
    @test !occursin("rot", line(entry(:A, Matrix(1.0I, 3, 3) .+ 1e-17)))
    l = line(entry(:A, rotation_matrix((12.5, -45.5, 170.25))))
    @test endswith(l, "rot = (12.5, -45.5, 170.25)")
    # Decimals are cut as long as the rotation stays within 1e-13
    l = line(entry(:A, rotation_matrix((12.345678901234, -45.5, 170.25))))
    @test endswith(l, "rot = (12.34567890123, -45.5, 170.25)")
    # Arbitrary angles of a mouse rotation are kept to the precision that is needed
    R = rotation_matrix((0.1, 0.2, 0.3)) * rotation_matrix((33.0, 0.0, 0.0))
    got = eval(Meta.parse(match(r"rot = (\(.*\))$", line(entry(:A, R))).captures[1]))
    @test maximum(abs, rotation_matrix(got) - R) ≤ 1e-13
    # Gimbal lock: the matrix
    l = line(entry(:A, rotation_matrix((10.0, 90.0, 0.0))))
    @test occursin("rot = [", l)
    @test P.euler_angles(rotation_matrix((10.0, 90.0, 0.0))) === nothing
end

@testset "code and meta" begin
    e = Entry(:component, :L1, "SphericalLens(0.05, -0.05, 0.005, 0.0254, λ -> 1.5)", lens();
        pos = (0.0, -0.0, 1e-6), pose0 = P.pose_of(lens()),
        meta = [:catalog => ("Spherical lens", ["50", "-50"])])
    @test line(e) == "@component L1 = SphericalLens(0.05, -0.05, 0.005, 0.0254, (λ->1.5)) " *
                     "pos = (0.0, 0.0, 1.0e-6) catalog = (\"Spherical lens\", [\"50\", \"-50\"])"
    s = SystemEntry(:S1, [:L1], [:B1]; static = true)
    @test split(system_code(Project(mktempdir(), "X"; systems = [s])), "\n")[2] ==
          "@system S1 = [L1] sources = [B1] static = true"
end

@testset "save_project" begin
    dir = joinpath(mktempdir(), "My bench")
    p = Project(dir, "MyBench"; entries = [entry(:L1, nothing; pos = (0.0, 0.1, 0.0))],
        systems = [SystemEntry(:S1, [:L1])])
    file = save_project(p)
    @test file == joinpath(dir, "system.jl")
    @test isfile(joinpath(dir, "Project.toml")) && isfile(joinpath(dir, "src", "MyBench.jl"))
    q = load_project(dir)
    @test q.name == "MyBench" && system_code(q) == read(file, String)
    @test !isfile(file * ".tmp")
    # Save as: another folder
    other = mktempdir()
    @test save_project(q, other) == joinpath(other, "system.jl")
    @test q.path == other && read(joinpath(other, "system.jl"), String) == read(file, String)
end

end
