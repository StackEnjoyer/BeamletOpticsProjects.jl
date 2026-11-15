module TestChanges

using BeamletOptics, BeamletOpticsProjects
using Dates
using LibGit2
using Test

const SIG = LibGit2.Signature("Test", "test@localhost")

function commit_at(dir, msg, t)
    repo = LibGit2.GitRepo(dir)
    try
        LibGit2.add!(repo, "system.jl")
        sig = LibGit2.Signature("Test", "test@localhost", Dates.datetime2unix(t) |> Int, 0)
        LibGit2.commit(repo, msg; author = sig, committer = sig)
    finally
        close(repo)
    end
end

const BOB = """
person = "bob@PC3"
name = "Bob"
started = 2020-11-15T09:58:00Z

[[change]]
time = 2020-11-15T10:01:02.120Z
kind = "moved"
id = "M1"
text = "moved M1 from (0.1, 0.2, 0.0) to (0.12, 0.2, 0.0)"
old_pos = [0.1, 0.2, 0.0]
new_pos = [0.12, 0.2, 0.0]

[[change]]
time = 2020-11-15T10:05:00Z
kind = "moved"
id = "M1"
text = "rotated M1"
old_rot = [0.0, 0.0, 10.0]
new_rot = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
"""

const ADA = """
person = "ada@PC1"
name = "Ada"
started = 2020-11-15T09:00:00Z

[[change]]
time = 2020-11-15T10:03:00Z
kind = "added"
id = "L1"
text = "added L1"
"""

@testset "changes" begin
    @test changes_file("d", "bob@PC3") == joinpath("d", ".bmo", "changes-bob@PC3.toml")
    dir = joinpath(mktempdir(), "P")
    new_project(dir)
    @test isempty(changes(dir))
    mkpath(joinpath(dir, ".bmo"))
    write(changes_file(dir, "bob@PC3"), BOB)
    write(changes_file(dir, "ada@PC1"), ADA)

    all = changes(dir)
    @test [c.by for c in all] == ["bob@PC3", "ada@PC1", "bob@PC3"]
    @test [c.time for c in all] == sort([c.time for c in all]; rev = true)
    @test all[3].time == DateTime(2020, 11, 15, 10, 1, 2, 120)
    @test all[3].kind === :moved && all[3].id === :M1
    @test all[3].old_pos == (0.1, 0.2, 0.0) && all[3].new_pos == (0.12, 0.2, 0.0)
    @test all[3].old_rot === nothing
    @test all[1].old_rot == (0.0, 0.0, 10.0)
    @test all[1].new_rot == [1.0 0.0 0.0; 0.0 1.0 0.0; 0.0 0.0 1.0]
    @test all[1].old_pos === nothing
    @test all[2].kind === :added

    @test length(changes(dir; by = "ada@PC1")) == 1
    @test isempty(changes(dir; by = "nobody"))
    @test length(changes(dir; since = DateTime(2020, 11, 15, 10, 2))) == 2
    @test length(changes(dir; since = DateTime(2020, 11, 15, 10, 1, 2, 120))) == 3

    # a broken file: no changes of that person, a warning
    write(changes_file(dir, "bad@PC"), "person = [")
    got = @test_logs (:warn, r"can not be read") changes(dir)
    @test length(got) == 3
end

@testset "versions of the changes" begin
    dir = joinpath(mktempdir(), "P")
    new_project(dir)
    mkpath(joinpath(dir, ".bmo"))
    write(changes_file(dir, "bob@PC3"), BOB)
    write(changes_file(dir, "ada@PC1"), ADA)
    # Versions at 10:02:00 and 10:04:00 (new_project made the first at the current time, in the past of
    # none of these: only the two below count)
    write(joinpath(dir, "system.jl"), read(joinpath(dir, "system.jl"), String) * "# a\n")
    commit_at(dir, "one", DateTime(2020, 11, 15, 10, 2))
    write(joinpath(dir, "system.jl"), read(joinpath(dir, "system.jl"), String) * "# b\n")
    commit_at(dir, "two", DateTime(2020, 11, 15, 10, 4))
    vs = versions(dir)
    v1 = first(v for v in vs if v.message == "one").id
    v2 = first(v for v in vs if v.message == "two").id
    all = changes(dir; since = DateTime(2020, 11, 15))
    byid(t) = first(c for c in all if c.time == t).version
    @test byid(DateTime(2020, 11, 15, 10, 1, 2, 120)) == v1   # before "one": the first at or after
    @test byid(DateTime(2020, 11, 15, 10, 3)) == v2           # between
    @test byid(DateTime(2020, 11, 15, 10, 5)) == first(v for v in vs if v.message == "New project").id  # the oldest at or after
end

@testset "folder outside a repository" begin
    dir = mktempdir()
    mkpath(joinpath(dir, ".bmo"))
    write(changes_file(dir, "ada@PC1"), ADA)
    c = changes(dir)
    @test length(c) == 1 && c[1].version === nothing
end

end
