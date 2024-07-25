local flib_table = require('__flib__.table')
local prometheus = require("prometheus/prometheus")

local logging = require("logging")

local debug_log = logging.debug_log
local log_levels = logging.levels

function on_signals_init()
    -- global["signal-data"] is populated in migrations
end

local signal_metrics = {}
--[[ example
    signal_metrics = {
        [metric_name_1] = {
            properties = {}, -- reference to properties in global["signal-data"].metrics[metric_name_1], if present
            ["prometheus-metric"] = ..., -- Result of prometheus.gauge
            groups = {
                [group] = {
                    -- only combinators matching this metric and group, otherwise same as global["signal-data"].combinators
                    [unit_number_1] = {
                        entity = LuaEntity,
                        ["metric-name"] = "metric_name_1",
                        ["signal-filter"] = {
                            type = "virtual",
                            name = "signal-0",
                        },
                        group = "",
                    }
                }
            }
        }
    }
]]--


local shared_signal_metric_labels = { "group", "signal" }

local function load_metric(metric_name, metric_table)
    local previous_data = signal_metrics[metric_name]
    if previous_data ~= nil then
        if metric_table ~= nil then
            previous_data.properties = metric_table
        end
        debug_log("Loaded into existing metric \"" .. metric_name .. "\"", log_levels.verbose, "signals")
        return previous_data
    else
        if metric_table == nil then
            metric_table = {}
        end
        local new_data = {
            properties = metric_table,
            groups = {},
            ["prometheus-metric"] = prometheus.gauge("factorio_custom_" .. metric_name, "Custom signal metric", shared_signal_metric_labels)
        }
        signal_metrics[metric_name] = new_data
        debug_log("Loaded new metric \"" .. metric_name .. "\"", log_levels.verbose, "signals")
        return new_data
    end
end

local function get_metric_names()
    local stored_metrics = global["signal-data"]["metrics"]
    local result = {}
    for name, _ in pairs(stored_metrics) do
        table.insert(result, name)
    end
    return result
end

local function get_group_names(metric_name)
    local stored_combinators = global["signal-data"]["combinators"]
    local matched = {} -- list of group names from matching metrics
    local added_matched = {} -- map of group names to true if added to matched
    for _, combinator in pairs(stored_combinators) do
        local combinator_group = combinator.group
        if added_matched[combinator_group] == nil then
            local combinator_metric_name = combinator["metric-name"]
            if metric_name == nil or combinator_metric_name == metric_name then
                table.insert(matched, combinator_group)
                added_matched[combinator_group] = true
            end
        end
    end

    return matched
end

local function get_metric_data(metric_name)
    local stored = global["signal-data"]["metrics"][metric_name]
    if stored ~= nil then
        return flib_table.deep_copy(stored)
    else
        return nil
    end
end

local function set_metric_data(metric_name, data)
    if data == nil then
        global["signal-data"]["metrics"][metric_name] = nil
    else
        local copy = flib_table.deep_copy(data)
        global["signal-data"]["metrics"][metric_name] = copy
        load_metric(metric_name, copy)
    end
end

local function new_custom_metric(options)
    if type(options) == "string" then
        return new_custom_metric { name = options }
    end
    if options.name ~= nil and options.name ~= "" then
        local existing = get_metric_data(options.name)
        if existing == nil then
            set_metric_data(options.name, {})
        end
    end
end

local function unload_metric_if_empty(metric_name, remove_from_global)
    if remove_from_global == nil then
        remove_from_global = false
    end
    debug_log("Starting unload check for " .. metric_name, log_levels.verbose, "signals")
    local loaded_metric = signal_metrics[metric_name]
    if loaded_metric == nil then
        debug_log("Metric not found", log_levels.verbose, "signals")
    elseif next(loaded_metric.groups) ~= nil then
        debug_log("Group was not empty", log_levels.verbose, "signals")
    else
        debug_log("Metric exists and its groups are empty", log_levels.verbose, "signals")
        local prometheus_metric = loaded_metric["prometheus-metric"]
        if prometheus_metric ~= nil then
            debug_log("Prometheus metric found, unregistering", log_levels.verbose, "signals")
            prometheus.unregister(prometheus_metric)
            loaded_metric["prometheus-metric"] = nil
            if remove_from_global then
                set_metric_data(metric_name, nil)
            end
        end
        signal_metrics[metric_name] = nil
    end
end

local function load_combinator(combinator_unit_number, combinator_table)
    local combinator_metric_name = combinator_table["metric-name"]
    if combinator_metric_name ~= nil and combinator_metric_name ~= "" then
        local loaded_metric = load_metric(combinator_metric_name)
        local group = enable_signal_groups and combinator_table.group or ""
        local matching_group = loaded_metric.groups[group]
        if matching_group == nil then
            debug_log("No matching group, creating new", log_levels.verbose, "signals")
            matching_group = {}
            loaded_metric.groups[group] = matching_group
        end
        matching_group[combinator_unit_number] = combinator_table
        debug_log("Added combinator " .. tostring(combinator_unit_number) .. " to group \"" .. group .. "\"", log_levels.verbose, "signals")
    end
    debug_log("Loaded combinator " .. tostring(combinator_unit_number) .. " from global", log_levels.verbose, "signals")
end

local function get_signal_combinator_data(unit_number)
    local stored = global["signal-data"]["combinators"][unit_number]
    if stored == nil then
        return nil
    end
    return flib_table.deep_copy(stored)
end

local function set_signal_combinator_entity(entity)
    local previous_global_data = global["signal-data"]["combinators"][entity.unit_number]
    if previous_global_data == nil then
        local new_data = {
            entity = entity,
            ["metric-name"] = nil,
            ["signal-filter"] = nil,
            group = "",
        }
        global["signal-data"]["combinators"][entity.unit_number] = new_data
        load_combinator(entity.unit_number, new_data)
    else
        previous_global_data.entity = entity
        load_combinator(entity.unit_number, previous_global_data)
    end
end

-- cascade specifies how an empty group should propagate to the metric.
-- cascade = 0: dont check if metric is empty
-- cascade = 1 (default): check if metric is empty, unload if it is (dont influence global)
-- cascade = 2: check if metric is empty, unload and remove it from global if it is
local function unload_group_if_empty(metric_name, group_name, cascade)
    if cascade == nil then
        cascade = 1
    end
    debug_log("Starting unload check for " .. metric_name .. "/" .. group_name, log_levels.verbose, "signals")
    local loaded_metric = signal_metrics[metric_name]
    if loaded_metric ~= nil then
        local group = loaded_metric.groups[group_name]
        if group ~= nil then
            if next(group) == nil then
                debug_log("Group empty: " .. metric_name .. "/" .. group_name .. ", unloading", log_levels.verbose, "signals")
                loaded_metric.groups[group_name] = nil
                if cascade > 0 then
                    unload_metric_if_empty(metric_name, cascade > 1)
                end
            end
        end
    end
end

local function remove_runtime_combinator_path(metric_name, group_name, unit_number)
    debug_log("Remove runtime combinator from path: \"" .. metric_name .. "\"/\"" .. group_name .. "\"/" .. tostring(unit_number), log_levels.verbose, "signals")
    if metric_name == nil then
        debug_log("Remove failed due to nil metric_name", log_levels.verbose, "signals")
        return
    end
    if group_name == nil then
        debug_log("Remove failed due to nil group_name", log_levels.verbose, "signals")
        return
    end
    if unit_number == nil then
        debug_log("Remove failed due to nil unit_number", log_levels.verbose, "signals")
        return
    end
    local signal_metric_data = signal_metrics[metric_name]
    if signal_metric_data ~= nil then
        local old_signal_group_data = signal_metric_data.groups
        if old_signal_group_data[group_name] ~= nil then
            debug_log("Group found", log_levels.verbose, "signals")
            old_signal_group_data[group_name][unit_number] = nil
            unload_group_if_empty(metric_name, group_name, 2)
        else
            debug_log("Group not found", log_levels.verbose, "signals")
        end
    else
        debug_log("Metric not found in signal_metrics", log_levels.verbose, "signals")
    end
end

local function set_signal_combinator_data(unit_number, data)
    local previous_global_data = global["signal-data"]["combinators"][unit_number]
    local copy
    if data == nil then
        global["signal-data"]["combinators"][unit_number] = nil
    else
        copy = flib_table.deep_copy(data)
        global["signal-data"]["combinators"][unit_number] = copy
    end
    if previous_global_data == nil then
        debug_log("No previous combinator data", log_levels.verbose, "signals")
    else
        local previous_metric_name = previous_global_data["metric-name"]
        local previous_group = enable_signal_groups and previous_global_data.group or ""
        local next_group = enable_signal_groups and data ~= nil and data.group or ""
        if previous_metric_name == nil or previous_metric_name == "" then
            debug_log("No previous metric name", log_levels.verbose, "signals")
        else
            debug_log("Previous metric name: \"" .. previous_metric_name .. "\"", log_levels.verbose, "signals")
            if (data == nil or previous_metric_name ~= data["metric-name"]) or (previous_group ~= next_group) then
                debug_log("Previous path is different, remove from old group: \"" .. previous_metric_name .. "\"/\"" .. previous_group .. "\"", log_levels.verbose, "signals")
                remove_runtime_combinator_path(previous_metric_name, previous_group, unit_number)
            else
                debug_log("Metric name same and group same / was nil", log_levels.verbose, "signals")
            end
        end
    end
    if copy ~= nil then
        load_combinator(unit_number, copy)
    end
end

local function new_prometheus_combinator(entity)
    local stored_data = get_signal_combinator_data(entity.unit_number)
    if stored_data == nil then
        set_signal_combinator_data(entity.unit_number, {
            entity = entity,
            ["metric-name"] = nil,
            ["signal-filter"] = nil,
            group = "",
        })
    elseif stored_data.entity == nil then
        set_signal_combinator_entity(entity)
    end
end

local function remove_combinator(combinator_unit_number)
    debug_log("Removing " .. tostring(combinator_unit_number), log_levels.verbose, "signals")
    set_signal_combinator_data(combinator_unit_number, nil)
    debug_log("Removed " .. tostring(combinator_unit_number), log_levels.verbose, "signals")
end

local function clean_invalid_prometheus_combinators()
    local pending_removal_numbers = {}
    for combinator_unit_number, combinator_table in pairs(global["signal-data"].combinators) do
        if combinator_table.entity ~= nil and not combinator_table.entity.valid then
            table.insert(pending_removal_numbers, combinator_unit_number)
        end
    end
    for _, pending_removal_number in ipairs(pending_removal_numbers) do
        remove_combinator(pending_removal_number)
    end
end

function on_signals_load()
    --[[ global signal data example:
    global["signal-data"] = {
        metrics = {
            [metric_name_1] = {
                -- future metric data
            },
        },
        combinators = {
            [unit_number_1] = {
                entity = LuaEntity,
                ["metric-name"] = "metric_name_1"
                ["signal-filter"] = {
                    type = "virtual",
                    name = "signal-0",
                },
                group = "",
            },
            [unit_number_2] = {
                entity = LuaEntity,
                ["metric-name"] = "metric_name_1",
                ["signal-filter"] = nil, -- may be nil, may be missing
                group = "main base",
            }
            [unit_number_3] = {
                entity = LuaEntity,
                ["metric-name"] = nil, -- not configured yet, may be nil, may be missing
                ["signal-filter"] = nil, -- may be nil, may be missing
                group = "main base",
            }
        }
    }
    --]]
    debug_log("Pre load global", log_levels.verbose, "signals")
    debug_log(serpent.block(global["signal-data"]), log_levels.verbose, "signals")
    debug_log("Pre load metrics", log_levels.verbose, "signals")
    debug_log(serpent.block(signal_metrics), log_levels.verbose, "signals")
    debug_log("Beginning load", log_levels.verbose, "signals")
    if global["signal-data"] == nil then
        error("Could not find signal-data in global")
    end
    for metric_name, metric_table in pairs(global["signal-data"].metrics) do
        load_metric(metric_name, metric_table)
    end
    for combinator_unit_number, combinator_table in pairs(global["signal-data"].combinators) do
        load_combinator(combinator_unit_number, combinator_table)
    end
    debug_log("Post load global", log_levels.verbose, "signals")
    debug_log(serpent.block(global["signal-data"]), log_levels.verbose, "signals")
    debug_log("Post load metrics", log_levels.verbose, "signals")
    debug_log(serpent.block(signal_metrics), log_levels.verbose, "signals")
    debug_log("Finished loading", log_levels.verbose, "signals")
end

function on_signals_tick(event)
    if not event.tick then
        return
    end

    local invalid_unit_numbers = {}
    local mismatching_combinator_paths = {} -- {{ ["metric-name"]="metric_name_1", ["group"] = "", ["unit-number"] = 9001 }}

    debug_log("Before tick, global:", log_levels.trace, "signals")
    debug_log(serpent.block(global["signal-data"]), log_levels.trace, "signals")
    debug_log("Before tick, metrics:", log_levels.trace, "signals")
    debug_log(serpent.block(signal_metrics), log_levels.trace, "signals")
    debug_log("Starting signal processing", log_levels.trace, "signals")
    for metric_name, metric_table in pairs(signal_metrics) do
        local prometheus_metric = metric_table["prometheus-metric"]
        prometheus_metric:reset()
        debug_log("Starting metric processing: \"" .. metric_name .. "\"", log_levels.trace, "signals")
        for group, group_table in pairs(metric_table.groups) do
            debug_log("Starting group processing: \"" .. group .. "\"", log_levels.trace, "signals")
            for combinator_unit_number, combinator_table in pairs(group_table) do
                debug_log("Starting combinator processing: " .. tostring(combinator_unit_number), log_levels.trace, "signals")
                local combinator_entity = combinator_table.entity
                if combinator_entity ~= nil then
                    debug_log("Entity present", log_levels.trace, "signals")
                    local signal_filter = combinator_table["signal-filter"]
                    if not combinator_entity.valid then
                        debug_log("Entity not valid", log_levels.trace, "signals")
                        table.insert(invalid_unit_numbers, combinator_unit_number)
                        table.insert(mismatching_combinator_paths, { ["metric-name"] = metric_name, ["group"] = group, ["unit-number"] = combinator_unit_number })
                    elseif metric_name ~= combinator_table["metric-name"] or (group ~= combinator_table["group"] and (enable_signal_groups or group ~= "")) or combinator_unit_number ~= combinator_entity.unit_number then
                        local actual_path = "\""..tostring(metric_name).."\"/\""..tostring(group).."\"/"..tostring(combinator_unit_number)
                        local stored_path = "\""..tostring(combinator_table["metric-name"]).."\"/\""..tostring(combinator_table["group"]).."\"/"..tostring(combinator_entity.unit_number)
                        debug_log("Mismatching paths: "..actual_path.." (cached) ~= "..stored_path.." (global)", log_levels.trace, "signals")
                        table.insert(mismatching_combinator_paths, { ["metric-name"] = metric_name, ["group"] = group, ["unit-number"] = combinator_unit_number })
                    else
                        if signal_filter ~= nil then
                            debug_log("Single filter", log_levels.trace, "signals")
                            local value = combinator_entity.get_merged_signal(signal_filter)
                            debug_log("Inc[\"" .. group .. "\", " .. signal_filter.type .. ":" .. signal_filter.name .. "] by " .. tostring(value), log_levels.trace, "signals")
                            prometheus_metric:inc(value, { group, signal_filter.type .. ":" .. signal_filter.name })
                        else
                            debug_log("No filter", log_levels.trace, "signals")
                            local values = combinator_entity.get_merged_signals()
                            if values ~= nil then
                                for _, entry in ipairs(values) do
                                    local signal = entry.signal
                                    local value = entry.count
                                    debug_log("Inc[\"" .. group .. "\", " .. signal.type .. ":" .. signal.name .. "] by " .. tostring(value), log_levels.trace, "signals")
                                    prometheus_metric:inc(value, { group, signal.type .. ":" .. signal.name })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    while #invalid_unit_numbers > 0 do
        local next_removal = table.remove(invalid_unit_numbers, 1)
        remove_combinator(next_removal)
    end
    while #mismatching_combinator_paths > 0 do
        local next_removal = table.remove(mismatching_combinator_paths, 1)
        remove_runtime_combinator_path(next_removal["metric-name"], next_removal["group"], next_removal["unit-number"])
    end
    clean_invalid_prometheus_combinators()
    debug_log("After tick, global:", log_levels.trace, "signals")
    debug_log(serpent.block(global["signal-data"]), log_levels.trace, "signals")
    debug_log("After tick, metrics:", log_levels.trace, "signals")
    debug_log(serpent.block(signal_metrics), log_levels.trace, "signals")
    debug_log("Done", log_levels.trace, "signals")
end

function on_signals_setup_blueprint(event)
    local player = game.players[event.player_index]
    local blueprint = player.blueprint_to_setup
    if blueprint == nil then
        logging.debug_log("Initial blueprint nil", logging.levels.verbose, "signals")
        blueprint = player.cursor_stack
    elseif not blueprint.valid_for_read then
        logging.debug_log("Initial blueprint not valid for read", logging.levels.verbose, "signals")
        blueprint = player.cursor_stack
    end
    if blueprint == nil then
        logging.debug_log("Second blueprint nil", logging.levels.verbose, "signals")
        return
    elseif not blueprint.valid_for_read then
        logging.debug_log("Second blueprint not valid for read", logging.levels.verbose, "signals")
        return
    end
    local entities = blueprint.get_blueprint_entities()
    if not entities then
        logging.debug_log("Entities in blueprint nil", logging.levels.verbose, "signals")
        return
    end
    if not event.mapping.valid then
        logging.debug_log("Entity mapping invalid", logging.levels.verbose, "signals")
        return
    end
    local map = event.mapping.get()
    for _, blueprint_entity in pairs(entities) do
        if blueprint_entity.name == "prometheus-combinator" then
            local local_id = blueprint_entity.entity_number
            local source_entity = map[local_id]
            if source_entity ~= nil then
                local stored_global = get_signal_combinator_data(source_entity.unit_number)
                if stored_global == nil then
                    logging.debug_log("No data stored for " .. source_entity.unit_number .. " (mapped from " .. local_id .. ")", logging.levels.verbose, "signals")
                else
                    logging.debug_log("Raw data", logging.levels.verbose, "signals")
                    logging.debug_log(serpent.line(stored_global), logging.levels.verbose, "signals")
                    local to_store = {
                        ["metric-name"] = stored_global["metric-name"],
                        ["signal-filter"] = nil,
                        group = stored_global.group,
                    }
                    if stored_global["signal-filter"] ~= nil then
                        to_store["signal-filter"] = {
                            type = stored_global["signal-filter"].type,
                            name = stored_global["signal-filter"].name,
                        }
                    end
                    logging.debug_log("Saving data to blueprint_entity " .. local_id .. " (from " .. source_entity.unit_number .. "): ", logging.levels.verbose, "signals")
                    logging.debug_log(serpent.line(to_store), logging.levels.verbose, "signals")
                    blueprint.set_blueprint_entity_tag(local_id, "graftorio2-metric-template", to_store)
                end
            else
                logging.debug_log("No mapped entity for " .. local_id .. ":" .. blueprint_entity.name, logging.levels.verbose, "signals")
            end
        end
    end
end

function on_signals_entity_build(event)
    local entity = event.created_entity
    if entity and entity.name == "prometheus-combinator" then
        logging.debug_log("Built prometheus combinator", logging.levels.verbose, "signals")
        local tags = event.tags
        if not tags then
            logging.debug_log("No tags present", logging.levels.verbose, "signals")
            return
        end
        local metric_template = tags["graftorio2-metric-template"]
        if metric_template == nil then
            logging.debug_log("No metric template present", logging.levels.verbose, "signals")
            return
        end
        local applied_template = flib_table.deep_copy(metric_template)
        applied_template.entity = entity
        logging.debug_log("Applying template:", logging.levels.verbose, "signals")
        logging.debug_log(serpent.line(applied_template), logging.levels.verbose, "signals")
        set_signal_combinator_data(entity.unit_number, applied_template)
        logging.debug_log("Applied template to " .. entity.unit_number, logging.levels.verbose, "signals")
    end
end

function on_signals_entity_destroyed(event)
    local entity = event.entity
    if entity and entity.name == "prometheus-combinator" then
        logging.debug_log("Destroyed prometheus combinator: "..tostring(entity.unit_number), logging.levels.verbose, "signals")
        remove_combinator(entity.unit_number)
    end
end

return {
    signal_metrics = signal_metrics,
    clean_invalid_prometheus_combinators = clean_invalid_prometheus_combinators,
    get_signal_combinator_data = get_signal_combinator_data,
    set_signal_combinator_entity = set_signal_combinator_entity,
    set_signal_combinator_data = set_signal_combinator_data,
    get_metric_data = get_metric_data,
    get_metric_names = get_metric_names,
    get_group_names = get_group_names,
    set_metric_data = set_metric_data,
    new_custom_metric = new_custom_metric,
    new_prometheus_combinator = new_prometheus_combinator,
}
