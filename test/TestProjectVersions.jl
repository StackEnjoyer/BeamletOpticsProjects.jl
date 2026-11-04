module TestProjectVersions

using BeamletOptics, BeamletOpticsProjects
using Dates, LibGit2, LinearAlgebra, TOML
using Test

const P = BeamletOpticsProjects

"""A project in a new folder `Bench` with the project file `marker` and the own code `code`."""
function bench(; marker = "name = \"Bench\"\n", code = "module Bench\nend\n")
    dir = joinpath(mktempdir(), "Bench")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Bench.bmo"), marker)
    write(joinpath(dir, "src", "Bench.jl"), code)
    write(joinpath(dir, "system.jl"), "")
    return dir
end

status(checks, name) = only(c for c in checks if c.package == name).status

@testset "project_versions" begin
    dir = bench(; marker = """
        format = 1
        name = "Bench"

        [versions]
        BeamletOptics = "0.14.0"
        BeamletOpticsGUI = "0.3.0"
        Wrong = 3

        [packages]
        Unitful = "1.21.0"
        """)
    v = project_versions(dir)
    @test v.versions == Dict("BeamletOptics" => "0.14.0", "BeamletOpticsGUI" => "0.3.0")
    @test v.packages == Dict("Unitful" => "1.21.0")
    @test project_versions(joinpath(dir, "Bench.bmo")) == v
    # A project file of the old form (only the format) and a folder without one
    old = bench(; marker = "# BeamletOptics project \"Bench\"\nformat = 1\n")
    @test project_versions(old) == (; versions = Dict{String, String}(), packages = Dict{String, String}())
    @test P.project_name(old) == "Bench"   # the name of the folder
    @test project_versions(mktempdir()).versions == Dict{String, String}()
    # The name of the project file names the module, not the folder
    named = bench(; marker = "name = \"Other\"\n", code = "module Other\nexport f\nf() = 1\nend\n")
    @test P.project_name(named) == "Other"
    @test load_project(named).name == "Other"
    # A project file that is not TOML
    @test_throws ArgumentError project_versions(bench(; marker = "name = "))
end

@testset "check_versions: each status" begin
    vb = pkgversion(BeamletOptics)
    vg, vd, vl, vt = pkgversion(LibGit2), pkgversion(Dates), pkgversion(LinearAlgebra), pkgversion(TOML)
    @test vd.major ≥ 1 && vd > VersionNumber(vd.major, 0, 0) && vl.major ≥ 1
    dir = bench(; marker = """
        name = "Bench"

        [versions]
        BeamletOptics = "$vb"
        LibGit2 = "$vg"
        Dates = "$(VersionNumber(vd.major, 0, 0))"
        LinearAlgebra = "$(VersionNumber(vl.major - 1, 0, 0))"
        TOML = "$(VersionNumber(vt.major + 1, 0, 0))"
        BeamletOpticsGUI = "0.3.0"

        [packages]
        LibGit2 = "$vg"
        NotInstalledXyz = "1.0.0"
        Unknown = ""
        """)
    checks = check_versions(dir; packages = [LibGit2, Dates, LinearAlgebra, TOML])
    @test all(c -> c isa VersionCheck, checks)
    # BeamletOptics, BeamletOpticsProjects and the modules passed, then the packages of src/
    @test [c.package for c in checks] == ["BeamletOptics", "BeamletOpticsProjects", "LibGit2",
        "Dates", "LinearAlgebra", "TOML", "LibGit2", "NotInstalledXyz", "Unknown"]
    @test checks[1] == VersionCheck("BeamletOptics", vb, vb, :same)
    # nothing recorded: nothing to compare
    @test checks[2] == VersionCheck("BeamletOpticsProjects", nothing, pkgversion(BeamletOpticsProjects), :same)
    @test checks[3].status === :same
    @test checks[4] == VersionCheck("Dates", VersionNumber(vd.major, 0, 0), vd, :newer)
    @test checks[5].status === :breaking
    @test checks[6] == VersionCheck("TOML", VersionNumber(vt.major + 1, 0, 0), vt, :older)
    @test checks[7] == VersionCheck("LibGit2", vg, vg, :same)
    @test checks[8] == VersionCheck("NotInstalledXyz", v"1.0.0", nothing, :missing)
    @test checks[9].status === :missing
    # The entries of [versions] of programs not passed are not checked
    @test !any(c -> c.package == "BeamletOpticsGUI", checks)
    # A loaded package: the version of its module
    @test P._installed_version("Test") == (true, pkgversion(Test))
    # A package that is installed but not loaded: its version from its files, nothing is loaded
    name = first(n for n in ("Profile", "Downloads", "Tar", "SparseArrays", "Serialization")
                 if !Base.root_module_exists(Base.identify_package(n)))
    found, v = P._installed_version(name)
    @test found && v isa VersionNumber
    @test !Base.root_module_exists(Base.identify_package(name))
    @test P._installed_version("NotInstalledXyz") == (false, nothing)
    # The rule: the same major version from 1.0 on, the same minor version for 0.x
    @test P._version_status(v"0.14.0", v"0.14.2") === :newer
    @test P._version_status(v"0.14.0", v"0.15.0") === :breaking
    @test P._version_status(v"1.2.0", v"1.5.1") === :newer
    @test P._version_status(v"1.2.0", v"2.0.0") === :breaking
    @test P._version_status(v"0.14.1", v"0.14.0") === :older
    @test P._version_status(v"0.14.1", v"0.14.1") === :same
    @test P._version_status(nothing, v"0.14.1") === :same
end

@testset "[packages] from using and import of src/" begin
    dir = bench(; code = """
        module Bench
        using BeamletOptics
        using LinearAlgebra: norm
        import TOML as T
        import Base: show
        using Core
        module Inner
        using Dates
        end
        using .Inner
        q = quote
            using NotReally
        end
        end
        """)
    mkpath(joinpath(dir, "src", "parts"))
    write(joinpath(dir, "src", "parts", "helpers.jl"), "import LibGit2.GitRepo\nusing Bench\n")
    write(joinpath(dir, "src", "._Bench.jl"), "using Hidden\n")
    write(joinpath(dir, "src", "notes.txt"), "using NotCode\n")
    write(joinpath(dir, "src", "broken.jl"), "f(x = \n")
    @test P._used_packages(dir, ("Bench",)) == Set(["LinearAlgebra", "TOML", "Dates", "LibGit2"])
    p = load_project(dir)
    save_project(p)
    packages = project_versions(dir).packages
    @test packages == Dict("LinearAlgebra" => string(pkgversion(LinearAlgebra)),
        "TOML" => string(pkgversion(TOML)), "Dates" => string(pkgversion(Dates)),
        "LibGit2" => string(pkgversion(LibGit2)))
end

@testset "save_project raises the versions, never lowers them" begin
    vb, vp = pkgversion(BeamletOptics), pkgversion(BeamletOpticsProjects)
    dir = bench(; marker = """
        # mine
        format = 1
        name = "Bench"
        extra = "kept"

        [versions]
        BeamletOptics = "99.0.0"
        BeamletOpticsProjects = "0.0.1"
        BeamletOpticsGUI = "0.3.0"

        [packages]
        TOML = "99.0.0"
        Gone = "1.0.0"
        """, code = "module Bench\nusing TOML, Dates\nend\n")
    p = load_project(dir)
    save_project(p; packages = [LibGit2])
    data = TOML.parsefile(joinpath(dir, "Bench.bmo"))
    @test data["format"] == 1 && data["name"] == "Bench" && data["extra"] == "kept"
    @test data["versions"] == Dict("BeamletOptics" => "99.0.0", "BeamletOpticsProjects" => string(vp),
        "BeamletOpticsGUI" => "0.3.0", "LibGit2" => string(pkgversion(LibGit2)))
    # the packages that src/ uses now, the higher of recorded and installed
    @test data["packages"] == Dict("TOML" => "99.0.0", "Dates" => string(pkgversion(Dates)))
    text = read(joinpath(dir, "Bench.bmo"), String)
    @test startswith(text, "# BeamletOptics project \"Bench\": open this file with BeamletOptics.\n")
    # A save that changes no version does not write the project file
    write(joinpath(dir, "Bench.bmo"), text * "# a comment that a write would drop\n")
    save_project(p; packages = [LibGit2])
    @test endswith(read(joinpath(dir, "Bench.bmo"), String), "# a comment that a write would drop\n")
    # Without a project file: a save writes one with the name of the project
    rm(joinpath(dir, "Bench.bmo"))
    save_project(p)
    data = TOML.parsefile(joinpath(dir, "Bench.bmo"))
    @test data["name"] == "Bench" && data["format"] == 1
    @test data["versions"] == Dict("BeamletOptics" => string(vb), "BeamletOpticsProjects" => string(vp))
    # The project file is not part of the stamp: a raise is no change of the files
    stamp = project_stamp(dir)
    write(joinpath(dir, "Bench.bmo"), "name = \"Bench\"\n")
    @test project_stamp(dir) == stamp
    @test save_project(p) == joinpath(dir, "system.jl")
end

@testset "load_project names a package of src/ that is not installed" begin
    dir = bench(; code = "module Bench\nusing NotInstalledXyz\nend\n")
    err = try
        load_project(dir)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test err.msg == "the project's code uses NotInstalledXyz, which is not installed in this environment: `] add NotInstalledXyz`"
    # Other errors of the own code stay as they are
    dir = bench(; code = "module Bench\nerror(\"own\")\nend\n")
    @test_throws LoadError load_project(dir)
end

@testset "the presence carries the versions" begin
    dir = mktempdir()
    id = announce(dir; name = "claude", versions = Dict("BeamletOpticsGUI" => "0.3.0",
        "BeamletOptics" => "0.0.1"))
    v = P.read_presences(dir)[id]["versions"]
    # this session wins for BeamletOptics and BeamletOpticsProjects
    @test v == Dict("BeamletOptics" => string(pkgversion(BeamletOptics)),
        "BeamletOpticsProjects" => string(pkgversion(BeamletOpticsProjects)),
        "BeamletOpticsGUI" => "0.3.0")
    # A write of `by` keeps them
    P._announce_wrote(dir, "claude", "added M1")
    @test P.read_presences(dir)[id]["versions"] == v
    # A presence without versions, or with entries that are not strings
    P.write_presence(dir, "ada@pc", Dict("name" => "Ada"))
    @test P.read_presences(dir)["ada@pc"]["versions"] == Dict{String, String}()
    P.write_presence(dir, "bob@pc", Dict("versions" => Dict("A" => "1.0.0", "B" => 2)))
    @test P.read_presences(dir)["bob@pc"]["versions"] == Dict("A" => "1.0.0")
end

end
