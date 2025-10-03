

module Server

using ..Common: make_response, report_error, ParamData, read_json,
    parse_params, write_json, ArgLoc, CustomRequestError,
    JSONFIELD, QUERY, JSON, ALLHEADERS, HEADER, ErrorResponse

import OrderedCollections: OrderedDict
import MacroTools
import HTTP
import Sockets: IPAddr, @ip_str

@kwdef struct ServerConfig
    ip::IPAddr
    port::Int
    path::String
    router::HTTP.Router = HTTP.Router()
    error_codes::Vector{Pair{DataType, Int}} = Pair{DataType, Int}[]
end

get_query_params(req::HTTP.Request) = req.target |> HTTP.URI |> HTTP.queryparams

function find_err_code(code_map, e::Exception)
    for (type, code) in code_map
        if e isa type
            return code
        end
    end
    return nothing
end

function error_response(cfg, e::Exception)
    code = find_err_code(cfg.error_codes, e)
    isnothing(code) &&
        return make_response(500, write_json(ErrorResponse(e)))
    if e isa CustomRequestError
        return make_response(code, write_json(e))
    end
    return make_response(code, write_json(ErrorResponse(e)))
end

function parsing_error_response(e::Exception, type::Type)
    return make_response(
        422,
        write_json(ErrorResponse("Error parsing type $type: $e")),
    )
end

function no_param_provided_response(param_name::String)
    return make_response(
        422,
        write_json(
            ErrorResponse("Required parameter \"$param_name\" not provided"),
        ),
    )
end

function construct_body_type(
    fieldinfo::OrderedDict{Symbol, ParamData},
    route_name::Symbol,
)
    fields = []
    for (name, arg) in fieldinfo
        @assert arg.loc == JSONFIELD
        if !isnothing(arg.default)
            type = :(Union{$(arg.type), Nothing})
        else
            type = arg.type
        end
        symname = Symbol(name)
        push!(fields, :($symname::$type))
    end

    structname = gensym(Symbol("Body_For_" * string(route_name)))
    return structname, esc(:(struct $structname
        $(fields...)
    end))
end

function construct_handler(
    params,
    body_type,
    rettype,
    route_function::Symbol,
    cfg,
)
    exprs = []
    resp_code = rettype == :Nothing ? 204 : 200
    if !isnothing(body_type)
        parsing = :(parsedbody = try
            $read_json(req.body, $body_type)
        catch e
            $report_error(e)
            return $parsing_error_response(e, $body_type)
        end)
    else
        parsing = :(parsedbody = nothing)
    end

    for (argname, param) in params
        parname = string(argname)
        if param.loc == JSONFIELD
            push!(exprs, :($argname = if !isnothing(parsedbody.$(argname))
                parsedbody.$(argname)
            else
                $(param.default)
            end))
            continue
        end
        if param.loc == JSON
            push!(exprs, :($argname = parsedbody))
            continue
        end
        if isnothing(param.default)
            push!(
                exprs,
                :(
                    !$haskey(queryparams, $parname) &&
                    return $no_param_provided_response($parname)
                ),
            )
        end
        if param.type == :String
            push!(
                exprs,
                :($argname = $get(queryparams, $parname, $(param.default))),
            )
            continue
        end
        push!(
            exprs,
            :(
                $argname = if $haskey(queryparams, $parname)
                    try
                        $parse($(param.type), queryparams[$parname])
                    catch e
                        $report_error(e)
                        return $parsing_error_response(e, $(param.type))
                    end
                else
                    $(param.default)
                end
            ),
        )
    end
    handler_name = gensym(Symbol(string(route_function) * "_handler_"))
    argnames = keys(params)
    return handler_name,
    esc(
        quote
            function $handler_name(req::HTTP.Request)
                queryparams = $merge(
                    $get_query_params(req),
                    something($HTTP.getparams(req), Dict{String, String}()),
                )
                $parsing
                $(exprs...)
                res = try
                    $route_function($(argnames...))
                catch e
                    $report_error(e)
                    return $error_response($cfg, e)
                end
                return $make_response($resp_code, $write_json(res))
            end
        end,
    )
end

function create_route_bodies(path, func, cfg)
    #! format: off
    MacroTools.@capture(func, function route_name_(args__)::rettype_
        functionbody_
    end) || error("Invalid route signature. Maybe you forgot return type?")
    #! format: on
    func_args = Any[]
    params = parse_params(args, path, route_name)

    for arg in split(path, '/')
        m = match(r"\{(\w+)\}", arg)
        isnothing(m) && continue
        argname = only(m.captures)
        haskey(params, Symbol(argname)) || error(
            "\"$argname\" provided in path but has no corresponding parameter in signature",
        )
    end

    body_params = filter(((_, par),) -> par.loc == JSONFIELD, params)
    body_type_param = filter(((_, par),) -> par.loc == JSON, params)

    if !isempty(body_params) && !isempty(body_type_param)
        error("Cannot have Json and JsonField in one signature")
    elseif !isempty(body_params)
        body_type, body_def = construct_body_type(body_params, route_name)
    elseif !isempty(body_type_param)
        length(body_type_param) == 1 ||
            error("Cannot have multiple bodies in signature")
        body_type = last(only(body_type_param)).type
        body_def = nothing
    else
        body_def = nothing
        body_type = nothing
    end

    func_args = Iterators.map(params) do (argname, par)
        return :($(argname)::$(par.type))
    end |> collect
    #! format: off
    handler_func = esc(:(function $route_name($(func_args...))
        $functionbody
    end))
    #! format: on
    handler_name, handler =
        construct_handler(params, body_type, rettype, route_name, cfg)
    return handler_name, body_def, handler_func, handler
end

function create_route(cfg, path::String, method::String, handler::Expr)
    handler_name, body_def, handler_func, handler =
        create_route_bodies(path, handler, cfg)
    return quote
        $body_def
        $handler_func
        $handler
        $HTTP.register!(
            $(esc(cfg)).router,
            $method,
            $(esc(cfg)).path * $path,
            $(esc(handler_name)),
        )
    end
end

function serve(cfg::ServerConfig)
    HTTP.serve(cfg.router, cfg.port)
end


function serve!(cfg::ServerConfig)
    HTTP.serve!(cfg.router, cfg.port)
end

@doc raw"""
```julia
API.@get(
    cfg,
    "/local/hello/{name}",
    function hello(name::String)::String
        return "Hello, $name"
    end
)
```
"""
macro get(cfg, path, handler)
    return create_route(cfg, path, "GET", handler)
end

macro post(cfg, path, handler)
    return create_route(cfg, path, "POST", handler)
end

macro delete(cfg, path, handler)
    return create_route(cfg, path, "DELETE", handler)
end

macro put(cfg, path, handler)
    return create_route(cfg, path, "PUT", handler)
end

end
