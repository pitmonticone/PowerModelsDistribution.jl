# This file contains useful transformation functions for the engineering data model

"collect of components and their properties that define loss models when transforming to the MATHEMATICAL model"
const _loss_model_objects = Dict{String,Vector{String}}(
    "switch" => Vector{String}(["linecode", "rs", "xs"]),
    "voltage_source" => Vector{String}(["rs", "xs"]),
    "transformer" => Vector{String}(["rw", "xsc", "cmag", "noloadloss"])
)


"""
    make_lossless!(data_eng::Dict{String,<:Any})

Remove parameters from objects with loss models to make them lossless. This includes switches
voltage sources and transformers, which all have loss model parameters that can be omitted.
"""
function make_lossless!(data_eng::Dict{String,<:Any})
    @assert iseng(data_eng) "incorrect data model type"

    for (object_type, parameters) in _loss_model_objects
        if haskey(data_eng, object_type)
            for (id, eng_obj) in data_eng[object_type]
                for parameter in parameters
                    if haskey(eng_obj, parameter)
                        if parameter == "linecode"
                            delete!(eng_obj, parameter)
                        else
                            eng_obj[parameter] = 0 .* eng_obj[parameter]
                        end
                    end
                end
            end
        end
    end
end


"""
    apply_voltage_bounds!(data_eng::Dict{String,<:Any}; vm_lb::Union{Real,Missing}=0.9, vm_ub::Union{Real,Missing}=1.1)

add voltage bounds to all buses based on per-unit upper (`vm_ub`) and lower (`vm_lb`), scaled by the bus's voltage based
"""
function apply_voltage_bounds!(data_eng::Dict{String,<:Any}; vm_lb::Union{Real,Missing}=0.9, vm_ub::Union{Real,Missing}=1.1)
    @assert iseng(data_eng) "incorrect data model type"

    (bus_vbases, edge_vbases) = calc_voltage_bases(data_eng, data_eng["settings"]["vbases_default"])
    if haskey(data_eng, "bus")
        for (id,bus) in data_eng["bus"]
            vbase = bus_vbases[id]
            if !ismissing(vm_lb) && !haskey(bus, "vm_lb")
                bus["vm_lb"] = vbase .* fill(vm_lb, length(bus["terminals"]))
            end

            if !ismissing(vm_ub) && !haskey(bus, "vm_ub")
                bus["vm_ub"] = vbase .* fill(vm_ub, length(bus["terminals"]))
            end
        end
    end
end


"""
    remove_all_bounds!(data_eng; exclude::Vector{<:String}=String["energy_ub"])

Removes all fields ending in '_ub' or '_lb' that aren't required by the math model. Properties
can be excluded from this removal with `exclude::Vector{String}`

By default, `"energy_ub"` is excluded from this removal, since it is a required properly on storage.
"""
function remove_all_bounds!(data_eng; exclude::Vector{<:String}=String["energy_ub"])
    for (k,v) in data_eng
        if isa(v, Dict) && k!="settings" && !(k in exclude)
            for (id, comp) in v
                for field in keys(comp)
                    if endswith(field, "_lb") || endswith(field, "_ub")
                        delete!(comp, field)
                    end
                end
            end
        end
    end
end


"""
apply_kron_reduction!(data_eng::Dict{String,<:Any}; kr_phases::Union{Vector{Int},Vector{String}}=[1,2,3], kr_neutral::Union{Int,String}=4)

Applies a Kron Reduction to the network, reducing out the `kr_neutral`, leaving only the `kr_phases`
"""
function apply_kron_reduction!(data_eng::Dict{String,<:Any}; kr_phases::Union{Vector{Int},Vector{String}}=[1,2,3], kr_neutral::Union{Int,String}=4)
    if haskey(data_eng, "bus")
        for (id,eng_obj) in data_eng["bus"]
            filter = eng_obj["terminals"] .!= kr_neutral
            terminals_kr = eng_obj["terminals"][filter]

            @assert all(t in kr_phases for t in terminals_kr) "bus $id has terminals $(eng_obj["terminals"]), outside of $kr_phases, cannot be kron reduced"

            _apply_filter!(eng_obj, ["vm", "va", "vm_lb", "vm_ub"], filter)
            eng_obj["terminals"] = terminals_kr

            gr_filter = eng_obj["grounded"] .!= kr_neutral
            _apply_filter!(eng_obj, ["grounded", "rg", "xg"], gr_filter)
        end
    end

    if haskey(data_eng, "line")
        for (_,eng_obj) in data_eng["line"]
            @assert all(eng_obj["f_connections"].==eng_obj["t_connections"]) "Kron reduction is only supported if f_connections == t_connections"

            _apply_linecode!(eng_obj, data_eng)

            filter = _kron_reduce_branch!(eng_obj, ["rs", "xs"], ["g_fr", "b_fr", "g_to", "b_to"], eng_obj["f_connections"], kr_neutral)
            _apply_filter!(eng_obj, ["vad_lb", "vad_ub", "cm_ub", "cm_ub_b", "cm_ub_c", "sm_ub", "sm_ub_b", "sm_ub_c", "f_connections", "t_connections"], filter)
        end
    end

    if haskey(data_eng, "transformer")
        for (id, eng_obj) in data_eng["transformer"]
            _apply_xfmrcode!(eng_obj, data_eng)

            if haskey(eng_obj, "f_connections")
                @assert all(eng_obj["f_connections"].==eng_obj["t_connections"]) "Kron reduction is only supported if f_connections == t_connections"

                if eng_obj["configuration"] == WYE
                    filter = eng_obj["f_connections"] .!= kr_neutral
                    _apply_filter!(eng_obj, ["f_connections", "t_connections"], filter)
                end
            else
                for (w, connections) in enumerate(eng_obj["connections"])
                    if eng_obj["configuration"][w] == WYE
                        filter = connections .!= kr_neutral
                        _apply_filter!(eng_obj, ["connections"], w, filter)
                    end
                end
            end
        end
    end

    if haskey(data_eng, "switch")
        for (_,eng_obj) in data_eng["switch"]
            @assert all(eng_obj["f_connections"].==eng_obj["t_connections"]) "Kron reduction is only supported if f_connections == t_connections"

            _apply_linecode!(eng_obj, data_eng)

            filter = _kron_reduce_branch!(eng_obj, Vector{String}([k for k in ["rs", "xs"] if haskey(eng_obj, k)]), String[], eng_obj["f_connections"], kr_neutral)
            _apply_filter!(eng_obj, ["vad_lb", "vad_ub", "cm_ub", "cm_ub_b", "cm_ub_c", "sm_ub", "sm_ub_b", "sm_ub_c", "f_connections", "t_connections"], filter)
        end
    end

    if haskey(data_eng, "shunt")
        for (_,eng_obj) in data_eng["shunt"]
            filter = _kron_reduce_branch!(eng_obj, String[], ["gs", "bs"], eng_obj["connections"], kr_neutral)
            _apply_filter!(eng_obj, ["connections"], filter)
        end
    end

    if haskey(data_eng, "load")
        for (_,eng_obj) in data_eng["load"]
            if eng_obj["configuration"]==WYE
                @assert eng_obj["connections"][end] == kr_neutral "for wye-connected loads, to kron reduce the connections list should end with a neutral"

                filter = eng_obj["connections"] .!= kr_neutral
                _apply_filter!(eng_obj, ["connections"], filter)
            end
        end
    end

    if haskey(data_eng, "generator")
        for (_,eng_obj) in data_eng["generator"]
            if eng_obj["configuration"]==WYE
                @assert eng_obj["connections"][end] == kr_neutral "for wye-connected generators, to kron reduce the connections list should end with a neutral"

                filter = eng_obj["connections"] .!= kr_neutral
                _apply_filter!(eng_obj, ["connections"], filter)
            end
        end
    end

    if haskey(data_eng, "solar")
        for (_,eng_obj) in data_eng["solar"]
            if eng_obj["configuration"]==WYE
                @assert eng_obj["connections"][end] == kr_neutral "for wye-connected solar, to kron reduce the connections list should end with a neutral"

                filter = eng_obj["connections"] .!= kr_neutral
                _apply_filter!(eng_obj, ["connections"], filter)
            end
        end
    end

    if haskey(data_eng, "storage")
        for (_,eng_obj) in data_eng["storage"]
            filter = eng_obj["connections"] .!= kr_neutral
            _apply_filter!(eng_obj, ["connections"], filter)
        end
    end

    if haskey(data_eng, "voltage_source")
        for (_,eng_obj) in data_eng["voltage_source"]
            filter = eng_obj["connections"] .!= kr_neutral
            _apply_filter!(eng_obj, ["vm", "va", "vm_lb", "vm_ub", "rs", "xs", "connections"], filter)
        end
    end

    delete!(data_eng, "linecode")  # kron reduction moves linecode properties directly to lines
    delete!(data_eng, "xfmrcode")  # kron reduction moves xfmrcode properties directly to transformers

    data_eng["is_kron_reduced"] = true
end


"""
    apply_phase_projection!(data_eng::Dict{String,<:Any})

pad matrices and vectors to max number of conductors
"""
function apply_phase_projection!(data_eng::Dict{String,<:Any})
    @assert get(data_eng, "is_kron_reduced", false)

    all_conductors = _get_complete_conductor_set(data_eng)

    if haskey(data_eng, "bus")
        for (_,eng_obj) in data_eng["bus"]
            if !haskey(eng_obj, "vm_lb")
                eng_obj["vm_lb"] = fill(0.0, length(eng_obj["terminals"]))
            end

            if !haskey(eng_obj, "vm_ub")
                eng_obj["vm_ub"] = fill(Inf, length(eng_obj["terminals"]))
            end

            _pad_properties!(eng_obj, ["vm", "va", "vm_lb", "vm_ub"], eng_obj["terminals"], all_conductors)

            _pad_connections!(eng_obj, "terminals", all_conductors)
        end
    end

    if haskey(data_eng, "line")
        for (_,eng_obj) in data_eng["line"]
            _apply_linecode!(eng_obj, data_eng)

            _pad_properties!(eng_obj, ["rs", "xs", "g_fr", "g_to", "b_fr", "b_to"], eng_obj["f_connections"], all_conductors)
            _pad_properties!(eng_obj, ["vad_lb"], eng_obj["f_connections"], all_conductors; pad_value=-10.0)
            _pad_properties!(eng_obj, ["vad_ub"], eng_obj["f_connections"], all_conductors; pad_value=10.0)
            for key in ["cm_ub", "cm_ub_b", "cm_ub_c", "sm_ub", "sm_ub_b", "sm_ub_c"]
                if haskey(eng_obj, key)
                    _pad_properties!(eng_obj, [key], eng_obj["f_connections"], all_conductors)
                end
            end

            _pad_connections!(eng_obj, "f_connections", all_conductors)
            _pad_connections!(eng_obj, "t_connections", all_conductors)
        end
    end

    if haskey(data_eng, "transformer")
        for (_,eng_obj) in data_eng["transformer"]
            _apply_xfmrcode!(eng_obj, data_eng)

            if haskey(eng_obj, "f_connections")
                _pad_properties!(eng_obj, ["tm_lb", "tm_ub", "tm_set"], eng_obj["f_connections"], all_conductors; pad_value=1.0)
                _pad_properties!(eng_obj, ["tm_fix"], eng_obj["f_connections"], all_conductors; pad_value=true)

                _pad_connections!(eng_obj, "f_connections", all_conductors)
                _pad_connections!(eng_obj, "t_connections", all_conductors)
            else
                for (w, connections) in enumerate(eng_obj["connections"])
                    _pad_properties!(eng_obj, ["tm_lb", "tm_ub", "tm_set"], w, connections, all_conductors; pad_value=1.0)
                    _pad_properties!(eng_obj, ["tm_fix"], w, connections, all_conductors; pad_value=true)

                    _pad_connections!(eng_obj, "connections", w, all_conductors)
                end
            end
        end
    end

    if haskey(data_eng, "switch")
        for (_,eng_obj) in data_eng["switch"]
            _apply_linecode!(eng_obj, data_eng)

            _pad_properties!(eng_obj, ["rs", "xs"], eng_obj["f_connections"], all_conductors)
            _pad_properties!(eng_obj, ["vad_lb"], eng_obj["f_connections"], all_conductors; pad_value=-10.0)
            _pad_properties!(eng_obj, ["vad_ub"], eng_obj["f_connections"], all_conductors; pad_value=10.0)
            for key in ["cm_ub", "cm_ub_b", "cm_ub_c", "sm_ub", "sm_ub_b", "sm_ub_c"]
                if haskey(eng_obj, key)
                    _pad_properties!(eng_obj, [key], eng_obj["f_connections"], all_conductors)
                end
            end

            _pad_connections!(eng_obj, "f_connections", all_conductors)
            _pad_connections!(eng_obj, "t_connections", all_conductors)
        end
    end

    if haskey(data_eng, "shunt")
        for (_,eng_obj) in data_eng["shunt"]
            _pad_properties!(eng_obj, ["gs", "bs"], eng_obj["connections"], all_conductors)

            _pad_connections!(eng_obj, "connections", all_conductors)
        end
    end

    if haskey(data_eng, "load")
        for (_,eng_obj) in data_eng["load"]
            if eng_obj["configuration"] == WYE
                _pad_properties!(eng_obj, ["pd_nom", "qd_nom"], eng_obj["connections"], all_conductors)
            else
                _pad_properties_delta!(eng_obj, ["pd_nom", "qd_nom"], eng_obj["connections"], all_conductors)
            end

            _pad_connections!(eng_obj, "connections", all_conductors)
        end
    end

    if haskey(data_eng, "generator")
        for (_,eng_obj) in data_eng["generator"]
            if eng_obj["configuration"]==WYE
                _pad_properties!(eng_obj, ["pg", "qg", "vg", "pg_lb", "pg_ub", "qg_lb", "qg_ub"], eng_obj["connections"], all_conductors)
            else
                _pad_properties_delta!(eng_obj, ["pg", "qg", "vg", "pg_lb", "pg_ub", "qg_lb", "qg_ub"], eng_obj["connections"], all_conductors)
            end

            _pad_connections!(eng_obj, "connections", all_conductors)
        end
    end

    if haskey(data_eng, "solar")
        for (_,eng_obj) in data_eng["solar"]
            if eng_obj["configuration"]==WYE
                _pad_properties!(eng_obj, ["pg", "qg", "vg", "pg_lb", "pg_ub", "qg_lb", "qg_ub"], eng_obj["connections"], all_conductors)
            else
                _pad_properties_delta!(eng_obj, ["pg", "qg", "vg", "pg_lb", "pg_ub", "qg_lb", "qg_ub"], eng_obj["connections"], all_conductors)
            end

            _pad_connections!(eng_obj, "connections", all_conductors)
        end
    end

    if haskey(data_eng, "storage")
        for (_,eng_obj) in data_eng["storage"]
            _pad_properties!(eng_obj, ["cm_ub", "qs_lb", "qs_ub", "rs", "xs", "ps", "qs"], eng_obj["connections"], all_conductors)

            _pad_connections!(eng_obj, "connections", all_conductors)
        end
    end

    if haskey(data_eng, "voltage_source")
        for (_,eng_obj) in data_eng["voltage_source"]
            _pad_properties!(eng_obj, ["pg", "qg", "pg_lb", "pg_ub", "qg_lb", "qg_ub", "vm", "va"], eng_obj["connections"], all_conductors)

            _pad_connections!(eng_obj, "connections", all_conductors)
        end
    end

    data_eng["is_projected"] = true
end


"""
    apply_phase_projection_delta!(data_eng::Dict{String,<:Any})

phase projection for components where unprojected states are not yet supported (delta configurations).

See [`apply_phase_projection!`](@ref apply_phase_projection!)
"""
function apply_phase_projection_delta!(data_eng::Dict{String,<:Any})
    @assert get(data_eng, "is_kron_reduced", false)

    bus_terminals = Dict{String,Vector{Int}}()

    all_conductors = _get_complete_conductor_set(data_eng)

    if haskey(data_eng, "transformer")
        for (_,eng_obj) in data_eng["transformer"]
            _apply_xfmrcode!(eng_obj, data_eng)

            if haskey(eng_obj, "f_connections")
                _pad_properties!(eng_obj, ["tm_lb", "tm_ub", "tm_set"], eng_obj["f_connections"], all_conductors; pad_value=1.0)
                _pad_properties!(eng_obj, ["tm_fix"], eng_obj["f_connections"], all_conductors; pad_value=true)

                _pad_connections!(eng_obj, "f_connections", all_conductors)
                _pad_connections!(eng_obj, "t_connections", all_conductors)

                bus_terminals[eng_obj["f_bus"]] = haskey(bus_terminals, eng_obj["f_bus"]) ? _pad_connections!(bus_terminals, eng_obj["f_bus"], eng_obj["f_connections"]) : eng_obj["f_connections"]
                bus_terminals[eng_obj["t_bus"]] = haskey(bus_terminals, eng_obj["t_bus"]) ? _pad_connections!(bus_terminals, eng_obj["t_bus"], eng_obj["t_connections"]) : eng_obj["t_connections"]
            else
                for (w, connections) in enumerate(eng_obj["connections"])
                    if eng_obj["configuration"][w] == DELTA && length(eng_obj["tm_set"][w]) == 1
                        _pad_properties_delta!(eng_obj, ["tm_lb", "tm_ub", "tm_set"], connections, w, all_conductors)
                        _pad_properties_delta!(eng_obj, ["tm_fix"], connections, w, all_conductors)
                        for i in 1:length(eng_obj["tm_set"][w])
                            eng_obj["tm_set"][w][i] = eng_obj["tm_set"][w][i] == 0 ? 1 : eng_obj["tm_set"][w][i]
                            eng_obj["tm_fix"][w][i] = eng_obj["tm_fix"][w][i] == 0 ? true : eng_obj["tm_fix"][w][i]
                        end
                    else
                        _pad_properties!(eng_obj, ["tm_lb", "tm_ub", "tm_set"], w, connections, all_conductors; pad_value=1.0)
                        _pad_properties!(eng_obj, ["tm_fix"], w, connections, all_conductors; pad_value=true)
                    end
                    _pad_connections!(eng_obj, "connections", w, all_conductors)
                    bus_terminals[eng_obj["bus"][w]] = haskey(bus_terminals, eng_obj["bus"][w]) ? _pad_connections!(bus_terminals, eng_obj["bus"][w], eng_obj["connections"][w]) : eng_obj["connections"][w]
                end
            end
        end
    end

    if haskey(data_eng, "load")
        for (_,eng_obj) in data_eng["load"]
            if eng_obj["configuration"] == DELTA
                _pad_properties_delta!(eng_obj, ["pd_nom", "qd_nom"], eng_obj["connections"], all_conductors)
                _pad_connections!(eng_obj, "connections", all_conductors)
                bus_terminals[eng_obj["bus"]] = haskey(bus_terminals, eng_obj["bus"]) ? _pad_connections!(bus_terminals, eng_obj["bus"], eng_obj["connections"]) : eng_obj["connections"]
            end
        end
    end

    if haskey(data_eng, "generator")
        for (_,eng_obj) in data_eng["generator"]
            if eng_obj["configuration"]==DELTA
                _pad_properties_delta!(eng_obj, ["pg", "qg", "vg", "pg_lb", "pg_ub", "qg_lb", "qg_ub"], eng_obj["connections"], all_conductors)
                _pad_connections!(eng_obj, "connections", all_conductors)
                bus_terminals[eng_obj["bus"]] = haskey(bus_terminals, eng_obj["bus"]) ? _pad_connections!(bus_terminals, eng_obj["bus"], eng_obj["connections"]) : eng_obj["connections"]
            end
        end
    end

    if haskey(data_eng, "solar")
        for (_,eng_obj) in data_eng["solar"]
            if eng_obj["configuration"]==DELTA
                _pad_properties_delta!(eng_obj, ["pg", "qg", "vg", "pg_lb", "pg_ub", "qg_lb", "qg_ub"], eng_obj["connections"], all_conductors)
                _pad_connections!(eng_obj, "connections", all_conductors)
                bus_terminals[eng_obj["bus"]] = haskey(bus_terminals, eng_obj["bus"]) ? _pad_connections!(bus_terminals, eng_obj["bus"], eng_obj["connections"]) : eng_obj["connections"]
            end
        end
    end

    _update_bus_terminal_projections!(data_eng, bus_terminals)

    data_eng["is_projected"] = true
end


"helper function to update the terminals on projected buses"
function _update_bus_terminal_projections!(data_eng::Dict{String,<:Any}, bus_terminals::Dict{String,<:Vector{Int}})
    for (id,terminals) in bus_terminals
        eng_obj = data_eng["bus"][id]

        if !haskey(eng_obj, "vm_lb")
            eng_obj["vm_lb"] = fill(0.0, length(eng_obj["terminals"]))
        end

        if !haskey(eng_obj, "vm_ub")
            eng_obj["vm_ub"] = fill(Inf, length(eng_obj["terminals"]))
        end

        old_terms = deepcopy(eng_obj["terminals"])
        new_terms = _pad_connections!(eng_obj, "terminals", terminals)
        _pad_properties!(eng_obj, ["vm", "va", "vm_lb", "vm_ub"], old_terms, new_terms)
    end
end


"""
    apply_voltage_angle_difference_bounds!(eng::Dict{String,<:Any}, vad::Real=5.0)

Applies voltage angle difference bound given by `vad::Real` in degrees (_i.e._, the allowed drift of angle from one end
of a line to another) to all lines. By default, `vad=5.0`.
"""
function apply_voltage_angle_difference_bounds!(eng::Dict{String,<:Any}, vad::Real=5.0)
    if haskey(eng, "line")
        for (_,line) in eng["line"]
            line["vad_lb"] = fill(-vad, length(line["f_connections"]))
            line["vad_ub"] = fill( vad, length(line["f_connections"]))
        end
    end
end
"Reduces line models, by removing trailing lines and merging lines in series with the same linecode."
function reduce_lines!(data_eng::Dict{String,Any})
    delete_trailing_lines!(data_eng)
    join_lines!(data_eng)
end


"Returns a reduced data model, by removing trailing lines and merging lines in series with the same linecode."
reduce_lines(data_eng::Dict{String,Any}) = reduce_lines!(deepcopy(data_eng))


"Reverse the direction of a line."
function _line_reverse!(line::Dict{String,Any})
    prop_pairs = [("f_bus", "t_bus"), ("g_fr", "g_to"), ("b_fr","b_to")]

    for (x,y) in prop_pairs
        if haskey(line, x)
            tmp = line[x]
            line[x] = line[y]
            line[y] = tmp
        end
    end
end


"""
Returns a unique list of all buses specified in the data model.
The argument 'comp_types' specifies which component types are searched to build the list.
"""
function get_defined_buses(data_eng::Dict{String,Any}; comp_types=pmd_eng_asset_types)
    @assert data_eng["data_model"]==ENGINEERING

    buses_exclude = []
    for comp_type in intersect(comp_types, keys(data_eng))
        for (id,comp) in data_eng[comp_type]
            if haskey(comp, "f_bus")
                buses = [comp["f_bus"], comp["t_bus"]]
            elseif haskey(comp, "bus")
                # works for a vector of buses and a single bus as a string
                buses = isa(comp["bus"], String) ? [comp["bus"]] : comp["bus"]
            else
                buses = []
            end
            append!(buses_exclude, buses)
        end
    end
    
    return unique(buses_exclude)
end


"""
Deletes trailing lines, 
i.e. lines connected to a bus with no other connected components and which is not grounded.
"""
function delete_trailing_lines!(data_eng::Dict{String,Any})
    @assert data_eng["data_model"]==ENGINEERING
    
    # exclude buses that appear in components other than lines
    comp_types_exclude = setdiff(pmd_eng_asset_types, ["lines"])
    buses_exclude = get_defined_buses(data_eng, comp_types=comp_types_exclude)

    # build auxiliary variables
    line_has_shunt = Dict()
    bus_lines = Dict(k=>[] for k in keys(data_eng["bus"]))
    for (id,line) in data_eng["line"]
        lc = data_eng["linecode"][line["linecode"]]
        zs, y_fr, y_to = _get_line_impedance_parameters(data_eng, line)
        line_has_shunt[id] = !iszero(y_fr) || !iszero(y_to)
        push!(bus_lines[line["f_bus"]], id)
        push!(bus_lines[line["t_bus"]], id)
    end

    # eligible buses connect to a single line, and that line should have zero addmittance to ground
    eligible_buses = [bus_id for (bus_id,line_ids) in bus_lines if length(line_ids)==1 && !line_has_shunt[line_ids[1]]]
    # exclude buses that connect to a component other than lines
    eligible_buses = setdiff(eligible_buses, buses_exclude)
    # exclude buses that are grounded
    grounded_buses = [bus_id for (bus_id,bus) in data_eng["bus"] if !isempty(bus["grounded"])]
    eligible_buses = setdiff(eligible_buses, grounded_buses)

    # remove trailing lines and buses
    while !isempty(eligible_buses)
        for bus_id in eligible_buses
            # this trailing bus has one associated line
            line_id = bus_lines[bus_id][1]
            line = data_eng["line"][line_id]

            delete!(data_eng["line"], line_id)
            delete!(data_eng["bus"],  bus_id)

            other_end_bus = line["f_bus"]==bus_id ? line["t_bus"] : line["f_bus"]
            bus_lines[other_end_bus] = setdiff(bus_lines[other_end_bus], [line_id])
            delete!(bus_lines,  bus_id)
        end

        eligible_buses = [bus_id for (bus_id, line_ids) in bus_lines if length(line_ids)==1 && !(bus_id in buses_exclude) && !line_has_shunt[line_ids[1]]]
    end

    return data_eng
end


"Join lines which are connected in series, and of which the intermediate bus is ungrounded and does not connect to any other components."
function join_lines!(data_eng::Dict{String,Any})
    @assert data_eng["data_model"]==ENGINEERING

    # a bus is eligible for reduction if it only appears in exactly two lines
    buses_all = collect(keys(data_eng["bus"]))

    # exclude buses that appear in components other than lines
    comp_types_exclude = setdiff(pmd_eng_asset_types, ["lines"])
    buses_exclude = get_defined_buses(data_eng, comp_types=comp_types_exclude)
    # exclude buses that are grounded
    grounded_buses = [bus_id for (bus_id,bus) in data_eng["bus"] if !isempty(bus["grounded"])]
    buses_exclude = union(buses_exclude, grounded_buses)

    # per bus, list all inbound or outbound lines
    bus_lines = Dict(bus=>[] for bus in buses_all)
    for (id,line) in data_eng["line"]
        push!(bus_lines[line["f_bus"]], id)
        push!(bus_lines[line["t_bus"]], id)
    end

    # exclude all buses that do not have exactly two lines connected to it
    buses_exclude = union(buses_exclude, [bus for (bus,lines) in bus_lines if length(lines)!=2])

    # now loop over remaining buses
    candidates = setdiff(buses_all, buses_exclude)
    for bus in candidates
        line1_id, line2_id = bus_lines[bus]
        line1 = data_eng["line"][line1_id]
        line2 = data_eng["line"][line2_id]

        # reverse lines if needed to get the order
        # (x)--fr-line1-to--(bus)--to-line2-fr--(x)
        if line1["f_bus"]==bus
            _line_reverse!(line1)
        end
        if line2["f_bus"]==bus
            _line_reverse!(line2)
        end

        reducable = true
        reducable = reducable && line1["linecode"]==line2["linecode"]
        reducable = reducable && all(line1["t_connections"].==line2["t_connections"])
        if reducable

            line1["length"] += line2["length"]
            line1["t_bus"] = line2["f_bus"]
            line1["t_connections"] = line2["f_connections"]

            delete!(data_eng["line"], line2_id)
            delete!(data_eng["bus"], bus)
            for x in candidates
                if line2_id in bus_lines[x]
                    bus_lines[x] = [setdiff(bus_lines[x], [line2_id])..., line1_id]
                end
            end
        end
    end

    return data_eng
end


"Calculate no-load starting values for all bus-terminals pairs."
function calc_start_voltage(data_math::Dict{String,Any}; max_iter=Inf, verbose=false, epsilon::Number=1E-3)
    @assert data_math["data_model"]==MATHEMATICAL

    node_links = Dict(vcat([[((bus["index"],t), []) for t in bus["terminals"]] for (_, bus) in data_math["bus"]]...))
    for (id, comp) in [data_math["branch"]..., data_math["switch"]...]
        f_bus   = comp["f_bus"]
        f_conns = comp["f_connections"]
        t_bus   = comp["t_bus"]
        t_conns = comp["t_connections"]

        arcs = []
        append!(arcs, [((f_bus,f_conns[k]), (t_bus,t_conns[k]), 1.0) for k in 1:length(f_conns)])
        append!(arcs, [((t_bus,t_conns[k]), (f_bus,f_conns[k]), 1.0) for k in 1:length(f_conns)])
        for (fr, to, scale) in arcs
            push!(node_links[fr], (to, scale))
        end
    end

    # initialize v_start for all bts to missing
    v_start = Dict((bus["index"],t)=>missing for (_, bus) in data_math["bus"] for t in bus["terminals"])

    for (_, bus) in data_math["bus"]
        # set fixed nodes
        if haskey(bus, "vm") && haskey(bus, "va")
            for (i,t) in enumerate(bus["terminals"])
                v_start[(bus["index"],t)] = bus["vm"][i]*exp(im*bus["va"][i])
            end

        end
        # set grounded nodes to zero
        for t in bus["terminals"][bus["grounded"]]
            v_start[(bus["index"],t)] = 0.0+im*0.0
        end
    end

    if verbose
        progress = round(sum(ismissing.(values(v_start)))/length(v_start)*100, digits=2)
        println("it. 0:\t$(100-progress)% specified at start")
    end

    # propogate within zones and then between them across transformers as long as progress is made
    # a 'zone' in this context is a collection of buses which are galvanically connected
    # zones are connected through transformers
    count = 0
    stack = collect(keys(filter(kv->!ismissing(kv[2]), v_start)))
    while !isempty(stack) && count<max_iter
        count += 1

        # propogate all nodes in stack through switches/branches
        while !isempty(stack)
            node = pop!(stack)
            for (to, scale) in node_links[node]
                if ismissing(v_start[to])
                    v_start[to] = v_start[node]*scale
                    push!(stack, to)
                end
            end
        end

        # cross zones through transformers
        for (_, tr) in data_math["transformer"]
            f_bus = tr["f_bus"]; f_conns = tr["f_connections"]
            t_bus = tr["t_bus"]; t_conns = tr["t_connections"]
            tm_scale = calculate_tm_scale(tr, data_math["bus"]["$f_bus"], data_math["bus"]["$t_bus"])
            scale = (tm_scale*tr["polarity"]).*tr["tm_set"]
            if tr["configuration"]==WYE || (tr["configuration"]==DELTA && length(tr["tm_set"])==1)
                v_fr = Array{Union{Complex,Missing}}([v_start[(f_bus, t)] for t in f_conns])
                v_to = Array{Union{Complex,Missing}}([v_start[(t_bus, t)] for t in t_conns])
                # forward propagation
                if all((!).(ismissing.(v_fr))) && any(ismissing.(v_to))
                    N = length(v_fr)-1
                    Mpn = [diagm(0=>ones(N)) fill(-1.0, N, 1)]
                    v_fr_pn = Mpn*v_fr
                    if all(ismissing.(v_to))
                        anchor_ind = length(v_to)
                        anchor_val = 0.0*im
                    else
                        (anchor_ind, anchor_val) = [(i, v) for (i, v) in enumerate(v_to) if !ismissing(v)][1]
                    end
                    v_to_prop = inv([Mpn; [i==anchor_ind ? 1 : 0 for i in 1:N+1]'])*[v_fr_pn./scale..., 0]

                    for (i,t) in enumerate(t_conns)
                        if ismissing(v_start[(t_bus,t)])
                            v_start[(t_bus,t)] = v_to_prop[i]
                            push!(stack, (t_bus,t))
                        end
                    end
                end
                # backward propagation
                if all((!).(ismissing.(v_to))) && any(ismissing.(v_fr))
                    N = length(v_fr)-1
                    Mpn = [diagm(0=>ones(N)) fill(-1.0, N, 1)]
                    v_to_pn = Mpn*v_to
                    if all(ismissing.(v_fr))
                        anchor_ind = length(v_fr)
                        anchor_val = 0.0*im
                    else
                        (anchor_ind, anchor_val) = [(i, v) for (i, v) in enumerate(v_fr) if !ismissing(v)][1]
                    end
                    v_fr_prop = inv([Mpn; [i==anchor_ind ? 1 : 0 for i in 1:N+1]'])*[scale.*v_to_pn..., 0]

                    for (i,t) in enumerate(f_conns)
                        if ismissing(v_start[(f_bus,t)])
                            v_start[(f_bus,t)] = v_fr_prop[i]
                            push!(stack, (f_bus,t))
                        end
                    end
                end
            elseif tr["configuration"]==DELTA
                v_fr = Array{Union{Complex,Missing}}([v_start[(f_bus, t)] for t in f_conns])
                v_to = Array{Union{Complex,Missing}}([v_start[(t_bus, t)] for t in t_conns])
                # forward propagation
                if all((!).(ismissing.(v_fr))) && any(ismissing.(v_to))
                    if ismissing(v_to[end])
                        v_to[end] = 0.0*im
                    end
                    v_to_n = v_to[end]
                    M = _get_delta_transformation_matrix(length(v_fr))
                    v_to = [(M*v_fr)./scale.+v_to_n..., v_to_n]
                    for (i,t) in enumerate(t_conns)
                        if ismissing(v_start[(t_bus,t)])
                            v_start[(t_bus,t)] = v_to[i]
                            push!(stack, (t_bus,t))
                        end
                    end
                end
                # backward propagation
                if all((!).(ismissing.(v_to))) && any(ismissing.(v_fr))
                    v_to_p = v_to[1:end-1]; v_to_n = v_to[end]
                    M = _get_delta_transformation_matrix(length(v_fr))
                    Mp = [M[1:end-1,:]; fill(1.0, 1, length(v_fr))]
                    v_to_pn_scaled = (v_to_p.-v_to_n).*scale
                    v_fr = inv(Mp)*[v_to_pn_scaled[1:end-1]..., 0.0]
                    for (i,t) in enumerate(f_conns)
                        if ismissing(v_start[(f_bus,t)])
                            v_start[(f_bus,t)] = v_fr[i]
                            push!(stack, (f_bus,t))
                        end
                    end
                end
            end
        end
        if verbose
            progress = round(sum(ismissing.(values(v_start)))/length(v_start)*100, digits=2)
            println("it. $count:\t$progress% left to initialize at end")
        end
    end

    # increment non-grounded zero values with epsilon
    for (k,v) in v_start
        (b,t) = k
        data_bus = data_math["bus"][string(b)]
        grounded_t = Dict(data_bus["terminals"].=>data_bus["grounded"])
        if !ismissing(v) && iszero(v) && !grounded_t[t]
            v_start[k] = convert(Complex, epsilon)
        end
    end

    return v_start
end


"""
Adds start values for the voltage to the buses.
For a multinetwork data model, you can calculate the start voltages for a representative network through 'calc_start_voltage',
and pass the result as 'uniform_v_start' to use the same values for all networks and avoid recalculating it for each network. 
The argument 'epsilon' controls the offset added to ungrounded terminals which would otherwise be set to zero.
"""
function add_start_voltage!(data_math::Dict{String,Any}; coordinates=:rectangular, uniform_v_start=missing, vr_default=0.0, vi_default=0.0, vm_default=0.0, va_default=0.0, verbose=false, epsilon::Number=1E-3)
    @assert data_math["data_model"]==MATHEMATICAL
    @assert coordinates in [:polar, :rectangular] "Legal values for the 'coordinates' argument are [:polar,:rectangular], not :$coordinates."
    
    is_mn = haskey(data_math, "multinetwork")

    if ismissing(v_start)
        v_start = calc_start_voltage(is_mn ? first(data_math["nw"])[2] : data_math, verbose=verbose, epsilon=epsilon)
    end

    for (nw,dm) in (is_mn ? data_math["nw"] : [("", data_math)])
        if ismissing(v_start)
            v_start = calc_start_voltage(dm, verbose=verbose, epsilon=epsilon)
        else
            v_start = uniform_v_start
        end
        for (_, bus) in dm["bus"]
            index = bus["index"]
            if coordinates==:rectangular
                bus["vr_start"] = [ismissing(v_start[(index, t)]) ? vr_default : real(v_start[(index, t)]) for t in bus["terminals"]]
                bus["vi_start"] = [ismissing(v_start[(index, t)]) ? vi_default : imag(v_start[(index, t)]) for t in bus["terminals"]]
            elseif coordinates==:polar
                bus["vm_start"] = [ismissing(v_start[(index, t)]) ? vm_default : abs(v_start[(index, t)]) for t in bus["terminals"]]
                bus["va_start"] = [ismissing(v_start[(index, t)]) ? va_default : angle(v_start[(index, t)]) for t in bus["terminals"]]

        end
    end

    return v_start
end


"Short-hand for add_start_voltage! with rectangular coordinates."
add_start_vrvi!(data_math::Dict{String,Any}; kwargs...) = add_start_voltage!(data_math, coordinates=:rectangular, kwargs...)


"Short-hand for add_start_voltage! with polar coordinates."
add_start_vmva!(data_math::Dict{String,Any}; kwargs...) = add_start_voltage!(data_math, coordinates=:polar, kwargs...)