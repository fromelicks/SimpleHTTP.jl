
module Client

using ..Common: make_response, report_error, ParamData, read_json,
    parse_params, write_json, ArgLoc, NotFoundError, ErrorResponse,
    CustomRequestError,
    JSONFIELD, QUERY, URL, JSONFIELD, JSON, ALLHEADERS, HEADER

import OrderedCollections: OrderedDict
import MacroTools
import HTTP

struct UnexpectedResponseError <: Exception
    code::Int
    msg::String
end

@kwdef struct ClientConfig
    url::String
end

function construct_body_type(
    fieldinfo::OrderedDict{Symbol, ParamData},
    route_name::Symbol,
)
    fields = []
    for (name, arg) in fieldinfo
        @assert arg.loc == JSONFIELD
        type = arg.type
        symname = Symbol(name)
        push!(fields, :($symname::$type))
    end

    structname = gensym(Symbol("Body_For_" * string(route_name)))
    return structname, :(struct $structname
        $(fields...)
    end)
end

function get_path_parts(path)
    last = length(path)
    new_path = Any[]
    for (i, part) in enumerate(path)
        if i == last
            push!(new_path, part)
            break
        end
        if part isa AbstractString
            push!(new_path, "$part/")
            continue
        end
        if part isa Symbol
            push!(new_path, part)
            push!(new_path, "/")
            continue
        end
        error("Unknown type $(typeof(part))")
    end
    return new_path
end

function get_error(resp)
    try
        read_json(resp.body, ErrorResponse).error
    catch e
        return String(resp.body)
    end
end

function get_exception(resp, err_map)
    if !haskey(err_map, resp.status)
        throw(UnexpectedResponseError(
            resp.status,
            get_error(resp)
        ))
    end
    type = err_map[resp.status]
    if type <: CustomRequestError
        return read_json(resp.body, type)
    end
    return type(read_json(resp.body, ErrorResponse).error)
end

function construct_expressions(cfg, path, method, sig, err_map)
    MacroTools.@capture(sig, route_name_(args__)::rettype_) ||
        error("Invalid endpoint signature. Maybe you forgot return type?")
    params = parse_params(args, path, route_name)

    path_parts = Any[]
    for arg in split(path, '/')
        m = match(r"\{(\w+)\}", arg)
        if isnothing(m)
            push!(path_parts, arg)
            continue
        end
        argname = only(m.captures)
        argsym = Symbol(argname)
        haskey(params, argsym) || error(
            "\"$argname\" provided in path but has no corresponding parameter in signature",
        )
        push!(path_parts, argsym)
    end

    body_params = filter(((_, par),) -> par.loc == JSONFIELD, params)
    full_body_param = filter(((_, par),) -> par.loc == JSON, params)
    query_params = filter(((_, par),) -> par.loc == QUERY, params)
    url_params = filter(((_, par),) -> par.loc == URL, params)
    if !isempty(body_params) && !isempty(full_body_param)
        error("Cannot have Json and JsonField in one signature")
    elseif !isempty(body_params)
        body_type, body_def = construct_body_type(body_params, route_name)
        create_body_expr = quote
            req_body = $write_json($body_type(
                $(keys(body_params)...)
            ))
        end
    elseif !isempty(full_body_param)
        length(full_body_param) == 1 ||
            error("Cannot have multiple bodies in signature")
        body_type = last(only(full_body_param)).type
        body_def = nothing
        create_body_expr = quote
            req_body = $write_json($body_type(
                $(only(keys(full_body_param)))
            ))
        end
    else
        body_def = nothing
        body_type = nothing
        create_body_expr = nothing
    end


    func_args = Iterators.map(params) do (argname, par)
        if isnothing(par.default)
            return :($(argname)::$(par.type))
        else
            return :($(argname)::$(par.type) = $(par.default))
        end
    end |> collect
    #! format: off
    query_args = ( :($(string(name))=>$name) for name in keys(query_params))
    url_patterm = if !isempty(url_params)
        Expr(:string, get_path_parts(path_parts)...)
    else
        path
    end
    if rettype == :Nothing
        ret_stmt = :(return nothing)
    else
        ret_stmt = :(return $read_json(resp.body, $rettype))
    end

    err_map_sym = gensym("errors_for_$route_name")
    handle_errors = quote
        if resp.status >= 300
            throw($get_exception(resp, $err_map_sym))
        end
    end
    if isnothing(create_body_expr)
        res = esc(quote
            const $err_map_sym = $err_map

            function $route_name($(func_args...))::$rettype
                resp = $HTTP.request($method, $cfg.url * $url_patterm; query = [$(query_args...)], status_exception = false)
                $handle_errors
                $ret_stmt
            end
        end)
    else
        res = esc(quote
            const $err_map_sym = $err_map
            $body_def

            function $route_name($(func_args...))::$rettype
                $create_body_expr
                resp = $HTTP.request($method, $cfg.url * $url_patterm; query = [$(query_args...)],  body=req_body, status_exception = false)
                $handle_errors
                $ret_stmt
            end
        end)
    end
    return res
end

@doc raw"""
```julia
API.@get(
    cfg,
    "/local/hello/{name}",
    hello(name::String)::String
)
```
"""
macro get(cfg, path, sig, err_map)
    return construct_expressions(cfg, path, "GET", sig, err_map)
end

macro post(cfg, path, sig, err_map)
    return construct_expressions(cfg, path, "POST", sig, err_map)
end

macro delete(cfg, path, sig, err_map)
    return construct_expressions(cfg, path, "DELETE", sig, err_map)
end

macro put(cfg, path, sig, err_map)
    return construct_expressions(cfg, path, "PUT", sig, err_map)
end

end
