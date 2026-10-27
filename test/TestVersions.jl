module TestVersions

using BeamletOptics, BeamletOpticsProjects
using Dates
using LibGit2
using Test

const P = BeamletOpticsProjects

lens(name, rest = "") = "@component $name = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5)$rest"
system_file(lines...) = join(["# BeamletOptics project \"X\" (format 1). Agents: see AGENTS.md.",
                              lines...], "\n") * "\n"

const SIG = LibGit2.Signature("Test", "test@localhost")

# The paths that the commit `id` changes, relative to the root of the repository
function changed_paths(repo, id)
    LibGit2.with(LibGit2.GitCommit(repo, LibGit2.GitHash(id))) do c
        new = LibGit2.GitTree(c)
        old = LibGit2.parentcount(c) == 0 ? nothing : LibGit2.GitTree(LibGit2.parent(c, 1))
        paths = String[]
        if isnothing(old)
            LibGit2.treewalk(new) do root, e
                LibGit2.entrytype(e) == LibGit2.GitBlob && push!(paths, root * LibGit2.filename(e))
                return Cint(0)
            end
        else
            diff = LibGit2.diff_tree(repo, old, new)
            for i in 1:LibGit2.count(diff)
                push!(paths, unsafe_string(diff[i].new_file.path))
            end
        end
        return paths
    end
end

@testset "new_project outside a repository" begin
    dir = joinpath(mktempdir(), "Bench")
    new_project(dir)
    @test isdir(joinpath(dir, ".git"))
    vs = versions(dir)
    @test length(vs) == 1 && vs[1].message == "New project"
    @test length(vs[1].id) == 40 && abs(vs[1].time - Dates.now(Dates.UTC)) < Dates.Minute(5)
    @test version_summary(dir) == ""
    @test save_version(dir) === nothing
    # Move one line
    file = joinpath(dir, "system.jl")
    write(file, system_file(lens(:L1, " pos = (0.0, 0.1, 0.0)"), lens(:L2)))
    @test version_summary(dir) == "added L1, L2"
    @test save_version(dir) isa String
    write(file, system_file(lens(:L1, " pos = (0.0, 0.2, 0.0)"), lens(:L2)))
    @test version_summary(dir) == "moved L1"
    id = save_version(dir)
    @test id isa String
    vs = versions(dir)
    @test length(vs) == 3 && vs[1].message == "moved L1" && vs[1].id == id
    # Deleted files are part of the version, ignored ones are not
    write(joinpath(dir, "Manifest.toml"), "ignored")
    mkpath(joinpath(dir, ".bmo"))
    write(joinpath(dir, ".bmo", "session.md"), "ignored")
    write(joinpath(dir, "src", "Extra.jl"), "module Extra end\n")
    @test version_summary(dir) == "own code changed"
    @test save_version(dir) isa String
    rm(joinpath(dir, "src", "Extra.jl"))
    @test version_summary(dir) == "own code changed"
    id = save_version(dir; message = "no extra")
    @test versions(dir)[1].message == "no extra"
    LibGit2.with(LibGit2.GitRepo(dir)) do repo
        paths = changed_paths(repo, id)
        @test paths == ["src/Extra.jl"]
        @test LibGit2.status(repo, "Manifest.toml") & LibGit2.Consts.STATUS_IGNORED != 0
    end
    @test save_version(dir) === nothing
end

@testset "versions of the same second in the order of the commits" begin
    dir = joinpath(mktempdir(), "Same")
    mkpath(dir)
    file = joinpath(dir, "system.jl")
    repo = LibGit2.init(dir)
    # The time of a commit has whole seconds: three commits of one second
    sig = LibGit2.Signature("Test", "test@localhost", 1_700_000_000, 0)
    for (i, msg) in enumerate(("first", "second", "third"))
        write(file, system_file(lens(:L1, " pos = (0.0, 0.$i, 0.0)")))
        LibGit2.add!(repo, "system.jl")
        LibGit2.commit(repo, msg; author = sig, committer = sig)
    end
    close(repo)
    @test [v.message for v in versions(dir)] == ["third", "second", "first"]
end

@testset ".bmo/ of an older project is never a part of a version" begin
    dir = joinpath(mktempdir(), "Old")
    mkpath(dir)
    write(joinpath(dir, "system.jl"), system_file(lens(:L1)))
    write(joinpath(dir, ".gitignore"), "Manifest.toml\n")
    mkpath(joinpath(dir, ".bmo"))
    write(joinpath(dir, ".bmo", "session.md"), "the window")
    id = save_version(dir; message = "first")
    LibGit2.with(LibGit2.GitRepo(dir)) do repo
        @test sort(changed_paths(repo, id)) == [".gitignore", "system.jl"]
    end
    write(joinpath(dir, ".bmo", "session.md"), "the window, later")
    @test save_version(dir) === nothing
end

@testset "new_project inside a repository" begin
    root = mktempdir()
    LibGit2.with(LibGit2.init(root)) do repo
        write(joinpath(root, "notes.txt"), "a")
        LibGit2.add!(repo, "notes.txt")
        LibGit2.commit(repo, "notes"; author = SIG, committer = SIG)
    end
    write(joinpath(root, "notes.txt"), "b")        # changed, not staged
    write(joinpath(root, "other.txt"), "untracked")
    dir = joinpath(root, "projects", "Bench")
    new_project(dir)
    @test !isdir(joinpath(dir, ".git"))
    vs = versions(dir)
    @test length(vs) == 1 && vs[1].message == "New project"
    LibGit2.with(LibGit2.GitRepo(root)) do repo
        @test all(p -> startswith(p, "projects/Bench/"), changed_paths(repo, vs[1].id))
        @test length(LibGit2.with(w -> LibGit2.map((o, _) -> o, w), LibGit2.GitRevWalker(repo))) == 2
    end
    # A commit outside the folder is no version of it
    LibGit2.with(LibGit2.GitRepo(root)) do repo
        LibGit2.add!(repo, "notes.txt")
        LibGit2.commit(repo, "notes b"; author = SIG, committer = SIG)
    end
    @test length(versions(dir)) == 1
    # Staged changes outside the folder: refused, nothing committed
    write(joinpath(dir, "system.jl"), system_file(lens(:L1)))
    LibGit2.with(LibGit2.GitRepo(root)) do repo
        LibGit2.add!(repo, "other.txt")
    end
    err = try
        save_version(dir)
    catch e
        e
    end
    @test err isa ArgumentError && occursin("other.txt", err.msg)
    @test length(versions(dir)) == 1
    LibGit2.with(LibGit2.GitRepo(root)) do repo
        LibGit2.remove!(repo, "other.txt")     # unstage (not in HEAD)
    end
    # No git binary is needed
    id = withenv("PATH" => "") do
        save_version(dir)
    end
    @test id isa String && versions(dir)[1].message == "added L1"
    LibGit2.with(LibGit2.GitRepo(root)) do repo
        @test changed_paths(repo, id) == ["projects/Bench/system.jl"]
    end
end

@testset "version_summary" begin
    dir = joinpath(mktempdir(), "Bench")
    @test version_summary(dir) == "first version"
    new_project(dir)
    file = joinpath(dir, "system.jl")
    u(i) = " uid = \"00000000-0000-0000-0000-00000000000$i\""
    write(file, system_file(lens(:L1, u(1)), lens(:L2, u(2)), lens(:L3, u(3)), lens(:L4, u(4)),
        lens(:L5, u(5)), "@system S1 = [L1, L2]" * u(6)))
    save_version(dir)
    write(file, system_file(
        lens(:L1, " pos = (0.0, 0.1, 0.0) rot = (0.0, 0.0, 90.0)" * u(1)),  # moved
        lens(:L7, u(2)),                                                  # renamed
        lens(:L3, " label = \"Kollimator\"" * u(3)),                     # changed: label
        "@component L4 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.6)" * u(4),  # changed: code
        lens(:L8, " pos = (0.0, 0.3, 0.0)"),                             # added
        "@system S1 = [L1, L7]" * u(6)))                                  # changed: members
    @test version_summary(dir) == "added L8; removed L5; renamed L2 to L7; moved L1; changed L3, L4, S1"
    # A line without uid is paired by its id
    save_version(dir)
    write(file, replace(read(file, String), "L8 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.3, 0.0)" =>
                                             "L8 = SphericalLens(0.05, -0.05, 0.005, 0.0254, 1.5) pos = (0.0, 0.4, 0.0)"))
    @test version_summary(dir) == "moved L8"
    # Further keywords, many ids, own code, lines that do not parse
    save_version(dir)
    text = read(file, String)
    write(file, replace(text, "label = \"Kollimator\"" => "label = \"Kollimator\" catalog = (\"x\",)"))
    @test version_summary(dir) == "changed L3"
    write(file, text * join([lens(Symbol("M", i)) for i in 1:9], "\n") * "\n")
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nf() = 1\nend\n")
    @test version_summary(dir) == "added 9 objects; own code changed"
    write(file, text * "@component M1 = SphericalLens(\n")
    @test version_summary(dir) == "system.jl changed; own code changed"
    write(file, text * "using LinearAlgebra\n")
    @test version_summary(dir) == "system.jl changed; own code changed"
end

@testset "scaffold" begin
    dir = joinpath(mktempdir(), "Bench")
    new_project(dir)
    @test occursin(".bmo/", read(joinpath(dir, ".gitignore"), String))
    settings = read(joinpath(dir, ".claude", "settings.json"), String)
    @test occursin("\"UserPromptSubmit\"", settings)
    cmd = match(r"\"command\": \"((?:[^\"\\]|\\.)*)\"", settings).captures[1]
    cmd = replace(cmd, "\\\"" => "\"")
    @test cmd == P._SESSION_HOOK
    agents = read(joinpath(dir, "AGENTS.md"), String)
    @test occursin("## The open windows", agents) && occursin(".bmo/session-<person>.md", agents) &&
occursin(".bmo/session*.md", agents)
    bash = Sys.which("bash")
    if isnothing(bash)
        @info "No bash: the hook is not run"
    else
        run_hook() = read(addenv(`$bash -c $cmd`, "CLAUDE_PROJECT_DIR" => replace(dir, '\\' => '/')),
            String)
        @test run_hook() == ""
        mkpath(joinpath(dir, ".bmo"))
        write(joinpath(dir, ".bmo", "session-a@pc.md"), "# Window\nSelected: L1\n")
        @test run_hook() == "# Window\nSelected: L1\n"
        write(joinpath(dir, ".bmo", "session-b@pc.md"), "# Window 2\n")
        @test run_hook() == "# Window\nSelected: L1\n# Window 2\n"
        # Files that are no sessions are not shown
        write(joinpath(dir, ".bmo", "presence-a@pc.toml"), "beat = 1\n")
        @test run_hook() == "# Window\nSelected: L1\n# Window 2\n"
    end
    # save_project of an existing project writes no scaffold files (D3b)
    old = joinpath(mktempdir(), "Old")
    new_project(old)
    rm(joinpath(old, ".claude"); recursive = true)
    rm(joinpath(old, ".git"); recursive = true)
    write(joinpath(old, ".gitignore"), "Manifest.toml\n*.tmp\n")
    before = sort(readdir(old))
    p = load_project(old)
    save_project(p)
    @test sort(readdir(old)) == before
    @test !occursin(".bmo", read(joinpath(old, ".gitignore"), String))
    # save_version on a project without a repository creates one (D2a)
    @test isempty(versions(old))
    @test save_version(old) isa String
    @test isdir(joinpath(old, ".git")) && length(versions(old)) == 1
    # Save as into a new folder: the scaffold with its first version
    other = joinpath(mktempdir(), "Copy")
    save_project(p, other)
    @test isfile(joinpath(other, ".claude", "settings.json"))
    @test [v.message for v in versions(other)] == ["New project"]
    # The hook only runs if Claude Code was started in the project folder
    @test occursin("If Claude Code was started in this folder", replace(agents, r"\s+" => " "))
end

@testset "a locked repository" begin
    dir = joinpath(mktempdir(), "Locked")
    new_project(dir)
    write(joinpath(dir, "src", "Extra.jl"), "f() = 1\n")
    lock = joinpath(dir, ".git", "index.lock")
    write(lock, "")
    # The lock is released meanwhile: the save succeeds
    t = @async (sleep(0.3); rm(lock))
    @test save_version(dir) isa String
    wait(t)
    # The lock stays: ArgumentError after the retries
    write(joinpath(dir, "src", "Extra.jl"), "f() = 2\n")
    write(lock, "")
    err = try
        save_version(dir)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError && occursin("locked by another save", err.msg)
    rm(lock)
    @test save_version(dir) isa String
    # The lock is seen before f runs: f is never called
    write(lock, "")
    calls = 0
    repo = LibGit2.GitRepo(dir)
    err = try
        BeamletOpticsProjects._retry_locked(() -> (calls += 1), repo; tries = 3, wait = 0.01)
        nothing
    catch e
        e
    finally
        close(repo)
    end
    rm(lock)
    @test calls == 0
    @test err isa ArgumentError
end

@testset "a project in a worktree or submodule" begin
    # The git directory lies apart from the working directory, as in a worktree or submodule
    root = mktempdir()
    work = joinpath(root, "work")
    gitdir = joinpath(root, "store", "work")
    mkpath(work)
    close(LibGit2.init(work))
    mkpath(dirname(gitdir))
    mv(joinpath(work, ".git"), gitdir)
    write(joinpath(work, ".git"), "gitdir: " * replace(gitdir, '\\' => '/') * "\n")
    LibGit2.with(LibGit2.GitRepo(gitdir)) do repo
        LibGit2.set!(LibGit2.GitConfig(repo), "core.worktree", replace(work, '\\' => '/'))
    end
    dir = joinpath(work, "Bench")
    new_project(dir)
    vs = versions(dir)
    @test length(vs) == 1 && vs[1].message == "New project"
    LibGit2.with(LibGit2.GitRepo(gitdir)) do repo
        @test all(p -> startswith(p, "Bench/"), changed_paths(repo, vs[1].id))
    end
    write(joinpath(dir, "system.jl"), system_file(lens(:L1)))
    @test version_summary(dir) == "added L1"
    @test save_version(dir) isa String && length(versions(dir)) == 2
end

@testset "glob characters in the path of the folder" begin
    root = mktempdir()
    LibGit2.with(LibGit2.init(root)) do repo
        write(joinpath(root, "notes.txt"), "a")
        LibGit2.add!(repo, "notes.txt")
        LibGit2.commit(repo, "notes"; author = SIG, committer = SIG)
    end
    dir = joinpath(root, "Setup [v2]")
    new_project(dir)
    vs = versions(dir)
    @test length(vs) == 1
    LibGit2.with(LibGit2.GitRepo(root)) do repo
        @test "Setup [v2]/system.jl" in changed_paths(repo, vs[1].id)
    end
    mkpath(joinpath(dir, ".bmo"))
    write(joinpath(dir, ".bmo", "session.md"), "the window")
    write(joinpath(dir, "system.jl"), system_file(lens(:L1)))
    id = save_version(dir)
    @test id isa String
    LibGit2.with(LibGit2.GitRepo(root)) do repo
        @test changed_paths(repo, id) == ["Setup [v2]/system.jl"]
    end
    @test save_version(dir) === nothing
end

@testset "a folder that the repository ignores" begin
    root = mktempdir()
    close(LibGit2.init(root))
    write(joinpath(root, ".gitignore"), "optics/\n")
    dir = joinpath(root, "optics", "Bench")
    @test_logs (:warn, r"not saved") match_mode = :any new_project(dir)
    err = try
        save_version(dir)
    catch e
        e
    end
    @test err isa ArgumentError && occursin("ignores the project folder", err.msg)
    @test_throws ArgumentError version_summary(dir)
    @test_throws ArgumentError versions(dir)
end

@testset "files in src/ that git ignores" begin
    dir = joinpath(mktempdir(), "Bench")
    new_project(dir)
    write(joinpath(dir, ".git", "info", "exclude"), "*.swp\n")
    write(joinpath(dir, "src", "Bench.jl.swp"), "swap")
    @test version_summary(dir) == ""
    @test save_version(dir) === nothing
    write(joinpath(dir, "src", "Bench.jl"), "module Bench\nf() = 1\nend\n")
    @test version_summary(dir) == "own code changed"
end

# Sets the search path of the git config of the `level` (1 program data, 2 system, 3 XDG, 4 global)
# to `path`; `nothing` restores the default
function set_search_path(level, path)
    LibGit2.ensure_initialized()
    p = isnothing(path) ? C_NULL : replace(path, '\\' => '/')
    @ccall LibGit2.libgit2.git_libgit2_opts(5::Cint; level::Cint, p::Cstring)::Cint
end

@testset "a configured name without email" begin
    empty = mktempdir()
    try
        foreach(l -> set_search_path(l, empty), 1:4)
        dir = joinpath(mktempdir(), "Bench")
        mkpath(dir)
        LibGit2.with(LibGit2.init(dir)) do repo
            LibGit2.set!(LibGit2.GitConfig(repo), "user.name", "Ada Lovelace")
        end
        write(joinpath(dir, "system.jl"), system_file())
        id = save_version(dir; message = "first")
        LibGit2.with(LibGit2.GitRepo(dir)) do repo
            LibGit2.with(LibGit2.GitCommit(repo, LibGit2.GitHash(id))) do c
                a = LibGit2.author(c)
                @test a.name == "Ada Lovelace" && a.email == "AdaLovelace@localhost"
            end
        end
    finally
        foreach(l -> set_search_path(l, nothing), 1:4)
    end
end

end
