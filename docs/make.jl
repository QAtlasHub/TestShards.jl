using TestShards
using Documenter
using DocumenterCitations

bib = CitationBibliography(joinpath(@__DIR__, "references.bib"); style=:numeric)

makedocs(;
    plugins=[bib],
    sitename="TestShards.jl",
    format=Documenter.HTML(;
        canonical="https://codes.sota-shimozono.com/TestShards.jl/stable/",
        prettyurls=get(ENV, "CI", "false") == "true",
    ),
    modules=[TestShards],
    pages=["Home" => "index.md", "API" => "api.md", "References" => "references.md"],
)

deploydocs(; repo="github.com/QAtlasHub/TestShards.jl", devbranch="main", push_preview=true)
