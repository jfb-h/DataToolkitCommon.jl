import REPL.TerminalMenus: request, RadioMenu

function download_progress(filename::AbstractString)
    start_time = time()
    min_seconds_before_eta = 3
    last_print = 0
    itercount = 0
    aprint(io::IO, val) = print(io, ' ', "\e[90m", val, "\e[m")
    partialbars = ["\e[90m╺", "╸\e[90m"]
    spinners = ['◐', '◓', '◑', '◒']
    println(stderr, " \e[90mDownloading $filename...\e[m")
    function (total::Integer, now::Integer)
        total_size, now_size = join.(humansize.((total, now)), ' ')
        if time() - start_time > 2 && time() - last_print > 0.1
            last_print = time()
            itercount += 1
            spinner = spinners[1 + itercount % length(spinners)]
            out = IOBuffer()
            print(out, "\e[G\e[2K")
            if 0 < now == total
                aprint(out, "✔ $filename downloaded ($total_size)")
            elseif total == 0
                aprint(out, "$spinner $now_size")
            else
                eta_segment = if time() - start_time >= min_seconds_before_eta
                    eta_seconds = round(Int, (total-now)/(now+1)*(time() - start_time))
                    eta_period = Dates.canonicalize(Dates.Period(Second(eta_seconds)))
                    eta_short = replace(string(eta_period), r" ([a-z])[a-z]+,?" => s"\1")
                    " ETA: $eta_short"
                else "" end
                complete = 30 * now/total
                aprint(out, string(
                    spinner, " \e[34m", '━'^floor(Int, complete),
                    partialbars[round(Int, 1+(length(partialbars)-1)*(complete%1))],
                    '━'^floor(Int, 30 - complete),
                    "  $now_size/$total_size ($(round(100*now/total, digits=1))%)",
                    eta_segment))
            end
            print(stderr, String(take!(out)))
            flush(stderr)
        end
    end
end

function download_to(storage::DataStorage{:web}, target::Union{IO, String}, retries::Int=2)
    @import Downloads
    url = @getparam(storage."url"::String)
    try
        Downloads.download(
            url, target;
            headers = @getparam(storage."headers"::SmallDict{String, Any}),
            timeout = @getparam(storage."timeout"::Real, Inf),
            progress = download_progress(storage.dataset.name))
        print(stderr, "\e[G\e[2K\e[A\e[2K")
        target isa IO && seekstart(target)
    catch err
        if err isa RequestError && retries > 0
            @warn "Download failed, retrying ($retries retries remaining)" url err
            target isa IO && seekstart(target)
            download_to(storage, target, retries - 1)
        else
            rethrow()
        end
    end
end

function getstorage(storage::DataStorage{:web}, ::Type{IO})
    try
        io = IOBuffer()
        download_to(storage, io)
        io
    catch err
        url = @getparam(storage."url"::String)
        @error "Download failed" url err
        Some(nothing)
    end
end

function getstorage(storage::DataStorage{:web}, ::Type{FilePath})
    tmpfile = tempname()
    download_to(storage, tmpfile)
    FilePath(tmpfile)
end

function Store.fileextension(storage::DataStorage{:web})
    something(match(r"\.\w+(?:\.[bgzx]z|\.[bg]?zip|\.zstd)?$",
                    @getparam(storage."url"::String)),
              (; match=".cache")).match[2:end]
end

getstorage(storage::DataStorage{:web}, ::Type{Vector{UInt8}}) =
    read(getstorage(storage, IO))

getstorage(storage::DataStorage{:web}, ::Type{String}) =
    read(getstorage(storage, IO), String)

supportedtypes(::Type{<:DataStorage{:web, <:Any}}) =
    QualifiedType.([IO, Vector{UInt8}, String, FilePath])

createpriority(::Type{<:DataStorage{:web}}) = 30

function create(::Type{<:DataStorage{:web}}, source::String)
    if !isnothing(match(r"^(?:https?|ftps?)://", source))
        ["url" => source]
    end
end

const WEB_DOC = md"""
Fetch data from the internet

This pairs well with the `store` plugin.

# Required packages

- `Downloads` (part of Julia's stdlib)

# Parameters

- `url` :: Path to the online data.
- `headers` :: HTTP headers that should be set.
- `timeout` :: Maximum number of seconds to try to download for before abandoning.

# Usage examples

Downloading the data on-demand each time it is accessed.

```toml
[[iris.storage]]
driver = "web"
url = "https://raw.githubusercontent.com/mwaskom/seaborn-data/master/iris.csv"
```
"""
