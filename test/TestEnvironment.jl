module TestEnvironment

using BeamletOptics, BeamletOpticsProjects
using LibGit2, TOML, UUIDs
using Test

const P = BeamletOpticsProjects
const Pkg = P.Pkg

"""A package `name` in a new local git repository; returns its url, uuid and branch."""
function git_package(root, name)
    dir = joinpath(root, name)
    mkpath(joinpath(dir, "src"))
    uuid = string(uuid4())
    write(joinpath(dir, "Project.toml"), "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n")
    write(joinpath(dir, "src", "$name.jl"), "module $name\nhello() = 42\nend\n")
    sig = LibGit2.Signature("a", "a@b", round(Int, time()), 0)
    repo = LibGit2.init(dir)
    LibGit2.add!(repo, ".")
    LibGit2.commit(repo, "init"; author = sig, committer = sig)
    return (; url = "file:///" * replace(dir, '\\' => '/'), uuid, branch = LibGit2.headname(repo))
end

"""A project `Bench` that needs the unregistered package `tiny` (by its `[sources]`) and a stdlib."""
function bench(root, tiny)
    dir = joinpath(root, "Bench")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Project.toml"), """
        name = "Bench"
        uuid = "$(uuid4())"
        version = "0.1.0"

        [deps]
        Tiny = "$(tiny.uuid)"

        [compat]
        julia = "$(VERSION.major).$(VERSION.minor)"

        [sources]
        Tiny = {url = "$(tiny.url)", rev = "$(tiny.branch)"}
        """)
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nusing Tiny\nend\n")
    return dir
end

# Pkg offline, in a depot of its own first (the depots of the user only for reading registries)
function with_depot(f)
    depot = mktempdir()
    pushfirst!(DEPOT_PATH, depot)
    offline = Pkg.OFFLINE_MODE[]
    Pkg.offline(true)
    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            redirect_stdout(devnull) do
                f()
            end
        end
    finally
        Pkg.offline(offline)
        popfirst!(DEPOT_PATH)
    end
end

loads(env, code) = success(pipeline(addenv(`$(Base.julia_cmd()) --startup-file=no --project=$env -e $code`,
    "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ";" : ":"), "JULIA_PKG_OFFLINE" => "true");
    stdout = devnull, stderr = devnull))

@testset "personal_environment!" begin
    root = mktempdir()
    tiny = git_package(root, "Tiny")
    dir = bench(root, tiny)
    active = Base.active_project()
    with_depot() do
        env = P.personal_environment!(dir; name = "hugo@PC12")
        @test env == joinpath(dir, ".envs", "hugo@PC12")
        @test Base.active_project() == active
        toml = TOML.parsefile(joinpath(env, "Project.toml"))
        project = TOML.parsefile(joinpath(dir, "Project.toml"))
        # the project by path, its packages directly, with their sources
        @test toml["deps"]["Bench"] == project["uuid"] && toml["deps"]["Tiny"] == tiny.uuid
        @test toml["sources"]["Bench"] == Dict("path" => "../..")
        @test toml["sources"]["Tiny"] == project["sources"]["Tiny"]
        @test toml["compat"]["julia"] == project["compat"]["julia"]
        @test isfile(joinpath(env, "Manifest.toml"))
        # what the project needs loads directly in the environment, and the own code too
        @test loads(env, "using Tiny, Bench; Tiny.hello() == 42 || exit(1)")
        # a second call changes nothing
        before = read(joinpath(env, "Project.toml"), String)
        P.personal_environment!(dir; name = "hugo@PC12")
        @test read(joinpath(env, "Project.toml"), String) == before

        # what the person added stays; a dependency added to the project comes
        own = TOML.parsefile(joinpath(env, "Project.toml"))
        own["deps"]["UUIDs"] = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
        open(io -> TOML.print(io, own; sorted = true), joinpath(env, "Project.toml"), "w")
        project["deps"]["Dates"] = "ade2ca70-3891-5945-98fb-dc099432e06a"
        open(io -> TOML.print(io, project; sorted = true), joinpath(dir, "Project.toml"), "w")
        P.personal_environment!(dir; name = "hugo@PC12")
        toml = TOML.parsefile(joinpath(env, "Project.toml"))
        @test haskey(toml["deps"], "UUIDs") && haskey(toml["deps"], "Dates")
        @test occursin("Dates", read(joinpath(env, "Manifest.toml"), String))

        # a package this person develops by path stays theirs
        toml["sources"]["Tiny"] = Dict("path" => replace(joinpath(root, "Tiny"), '\\' => '/'))
        open(io -> TOML.print(io, toml; sorted = true), joinpath(env, "Project.toml"), "w")
        P.personal_environment!(dir; name = "hugo@PC12")
        @test haskey(TOML.parsefile(joinpath(env, "Project.toml"))["sources"]["Tiny"], "path")

        # another machine of the same person: a folder of its own, the first one untouched
        mine = read(joinpath(env, "Manifest.toml"), String)
        other = P.personal_environment!(dir; name = "hugo@WS 1")
        @test other == joinpath(dir, ".envs", "hugo@WS_1")
        @test read(joinpath(env, "Manifest.toml"), String) == mine
        # nothing written into the folder of the project itself
        @test !isfile(joinpath(dir, "Manifest.toml"))
    end
end

@testset "personal_environment!: relative sources of the project" begin
    @test P._from_envs(Dict("path" => "../Tiny")) == Dict("path" => "../../../Tiny")
    @test P._from_envs(Dict("url" => "https://x", "rev" => "main")) == Dict("url" => "https://x", "rev" => "main")
    abs = Sys.iswindows() ? "C:/x/Tiny" : "/x/Tiny"
    @test P._from_envs(Dict("path" => abs)) == Dict("path" => abs)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"), "version = \"0.1.0\"\n")
    @test_throws ArgumentError P.personal_environment!(dir; name = "x")
end

end
