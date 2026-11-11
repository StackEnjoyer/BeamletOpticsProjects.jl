using BeamletOptics
using BeamletOpticsProjects
using Documenter

DocMeta.setdocmeta!(
    BeamletOpticsProjects,
    :DocTestSetup,
    :(using BeamletOptics, BeamletOpticsProjects);
    recursive=true
)

makedocs(;
    modules=[BeamletOpticsProjects],
    authors="Hugo Uittenbosch <hugo.uittenbosch@dlr.de> and contributors",
    sitename="BeamletOpticsProjects.jl",
    format=Documenter.HTML(;
        repolink="https://github.com/StackEnjoyer/BeamletOpticsProjects.jl",
        canonical="https://stackenjoyer.github.io/BeamletOpticsProjects.jl",
        edit_link="main",
    ),
    pagesonly=true,
    checkdocs=:exports,
    # The docstrings link to names of BeamletOptics (e.g. `solve_system!`), which are documented on
    # the BeamletOptics site and are not resolvable here
    warnonly=[:cross_references],
    pages=[
        "Home" => "index.md",
        "API" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/StackEnjoyer/BeamletOpticsProjects.jl.git",
    devbranch="main",
    push_preview=false,
)
