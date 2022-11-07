# Example:
#---
# [data.loader]
# driver = "chain"
# type = ["DataFrames.DataFrame"] # final supported data
# loaders = [
#   { driver = "gzip", type = "IO" },
#   { driver = "csv", type = "DataFrames.DataFrame"}
# ]
# # alternative
# loaders = [ "gzip", "csv" ]

function load(loader::DataLoader{:chain}, from::Any, ::Type{T}) where {T}
    subloaders = map(spec -> DataLoader(loader.dataset, spec),
                  get(loader, "loaders", Dict{String, Any}[]))
    types = loadtypepath(subloaders, typeof(from), T)
    if !isnothing(types)
        reduce((value, (subloader, as)) -> load(subloader, value, as),
            zip(subloaders, types), init=from)::T
    end
end

supportedtypes(::Type{DataLoader{:chain}}, spec::Dict{String, Any}) =
    let lastloader = last(get(spec, "loaders", [nothing]))
        if lastloader isa Dict # { driver="X", ... } form
            explicit_type = get(lastloader, "type", nothing)
            if explicit_type isa String
                [parse(QualifiedType, explicit_type)]
            elseif explicit_type isa Vector
                parse.(QualifiedType, explicit_type)
            else
                supportedtypes(DataLoader{Symbol(lastloader["driver"])}, lastloader)
            end
        elseif lastloader isa String # "X" shorthand form
            supportedtypes(DataLoader{Symbol(lastloader)})
        else
            QualifiedType[]
        end
    end

"""
    loadtypepath(subloaders::Vector{DataLoader}, targettype::Type)
Return the sequence of types that the `subloaders` must be asked for to finally
produce `targettype` from an initial `fromtype`. If this is not possible,
`nothing` is returned instead.
"""
function loadtypepath(subloaders::Vector{DataLoader}, fromtype::Type, targettype::Type)
    toploader = last(subloaders)
    loadertypes = filter(!isnothing, convert.(Type, toploader.type))
    if length(subloaders) > 1
        midtypes = if toploader isa DataLoader{:julia}
            # Julia loaders are a bit special, as they have parameter
            # (`input`) which if set indicates the type expected in the
            # argument to the Julia function. If not set, then this is
            # a keyword-argument only Julia loader, and so it expects
            # Nothing. Really though, only the input variety of loaders
            # makes sense in a chain loader. We may as well be
            # exhaustive though.
            if isempty(get(toploader, "input", ""))
                [Nothing]
            else
                iqtype = QualifiedType(get(toploader, "input"))
                itype = try
                    @something convert(Type, iqtype) begin
                        # It may be the case that the loader requires a lazy loaded
                        # package, in this case it may be a good idea to just /try/
                        # requiring it and seeing what happens.
                        DataToolkitBase.get_package(
                            toploader.dataset.collection.mod,
                            iqtype.parentmodule)
                        # If neither a `PkgRequiredRerunNeeded` or `ArgumentError`
                        # are raised, then then the package is already loaded
                        # and the unresolvable type will still be unresolvable,
                        # so return nothing.
                        Some(nothing)
                    end
                catch e
                    if e isa DataToolkitBase.PkgRequiredRerunNeeded
                        convert(Type, iqtype)
                    elseif !(e isa ArgumentError) # ArgumentError => pkg not registered
                        rethrow(e)
                    end
                end
                if !isnothing(itype); [itype] else Type[] end
            end
        else
            potentialmethods =
                [methods(load, Tuple{typeof(toploader), Any, Type{suptype}}).ms
                for suptype in loadertypes
                    if suptype <: targettype] |> Iterators.flatten |> unique
            [m.sig.types[3] for m in potentialmethods]
        end
        subpaths = filter(!isnothing,
                          [loadtypepath(subloaders[1:end-1], fromtype, midtype)
                           for midtype in midtypes])
        if !isempty(subpaths)
            vcat(first(subpaths), targettype)
        end
    else
        ms = methods(load, Tuple{typeof(toploader), fromtype, Type{targettype}})
        if !isempty(ms)
            targettype
        end
    end
end