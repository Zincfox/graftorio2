local flib_table = require('__flib__.table')
local prometheus = require("prometheus/prometheus")

function on_signals_init()
    -- global["signal-data"] is populated in migrations
end

local logs = {}

local function debug_print(text)
    if game then
        while #logs > 0 do
            game.print(table.remove(logs, 1), { skip = defines.print_skip.never })
        end
        game.print(text, { skip = defines.print_skip.never })
    else
        table.insert(logs, text)
    end
end

local function dump_logs()
    while #logs > 0 do
        game.print(table.remove(logs, 1), { skip = defines.print_skip.never })
    end
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
        debug_print("Loaded into existing metric \"" .. metric_name .. "\"")
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
        debug_print("Loaded new metric \"" .. metric_name .. "\"")
        return new_data
    end
end

local function load_combinator(combinator_unit_number, combinator_table)
    local combinator_metric_name = combinator_table["metric-name"]
    if combinator_metric_name ~= nil and combinator_metric_name ~= "" then
        local loaded_metric = load_metric(combinator_metric_name)
        local group = enable_signal_groups and combinator_table.group or ""
        local matching_group = loaded_metric.groups[group]
        if matching_group == nil then
            debug_print("No matching group, creating new")
            matching_group = {}
            loaded_metric.groups[group] = matching_group
        end
        matching_group[combinator_unit_number] = combinator_table
        debug_print("Added combinator " .. tostring(combinator_unit_number) .. " to group \"" .. group .. "\"")
    end
    debug_print("Loaded combinator " .. tostring(combinator_unit_number) .. " from global")
end

local function remove_combinator(combinator_unit_number)
    debug_print("Removing "..tostring(combinator_unit_number))
    set_signal_combinator_data(combinator_unit_number, nil)
    debug_print("Removed "..tostring(combinator_unit_number))
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
    if global["signal-data"] == nil then
        error("Could not find signal-data in global")
    end
    for metric_name, metric_table in pairs(global["signal-data"].metrics) do
        load_metric(metric_name, metric_table)
    end
    for combinator_unit_number, combinator_table in pairs(global["signal-data"].combinators) do
        load_combinator(combinator_unit_number, combinator_table)
    end
end

function on_signals_tick(event)
    if not event.tick then
        return
    end
    dump_logs()

    local pending_removals = {}

    game.print("Starting signal processing", { skip = defines.print_skip.never })
    for metric_name, metric_table in pairs(signal_metrics) do
        local prometheus_metric = metric_table["prometheus-metric"]
        prometheus_metric:reset()
        game.print("Starting metric processing: \"" .. metric_name .. "\"", { skip = defines.print_skip.never })
        for group, group_table in pairs(metric_table.groups) do
            game.print("Starting group processing: \"" .. group .. "\"", { skip = defines.print_skip.never })
            for combinator_unit_number, combinator_table in pairs(group_table) do
                game.print("Starting combinator processing: " .. tostring(combinator_unit_number))
                local combinator_entity = combinator_table.entity
                if combinator_entity ~= nil then
                    game.print("Entity present", { skip = defines.print_skip.never })
                    local signal_filter = combinator_table["signal-filter"]
                    if not combinator_entity.valid then
                        game.print("Entity not valid", { skip = defines.print_skip.never })
                        table.insert(pending_removals, combinator_unit_number)
                    else
                        if signal_filter ~= nil then
                            game.print("Single filter", { skip = defines.print_skip.never })
                            local value = combinator_entity.get_merged_signal(signal_filter)
                            game.print("Inc[\"" .. group .. "\", " .. signal_filter.type .. ":" .. signal_filter.name .. "] by " .. tostring(value), { skip = defines.print_skip.never })
                            prometheus_metric:inc(value, { group, signal_filter.type .. ":" .. signal_filter.name })
                        else
                            game.print("No filter", { skip = defines.print_skip.never })
                            local values = combinator_entity.get_merged_signals()
                            if values ~= nil then
                                for _, entry in ipairs(values) do
                                    local signal = entry.signal
                                    local value = entry.count
                                    game.print("Inc[\"" .. group .. "\"" .. signal.type .. ":" .. signal.name .. "] by " .. tostring(value), { skip = defines.print_skip.never })
                                    prometheus_metric:inc(value, { group, signal.type .. ":" .. signal.name })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    while #pending_removals > 0 do
        local next_removal = table.remove(pending_removals, 1)
        remove_combinator(next_removal)
    end
    game.print("Done", { skip = defines.print_skip.never })
end

function get_signal_combinator_data(unit_number)
    local stored = global["signal-data"]["combinators"][unit_number]
    if stored == nil then
        return nil
    end
    return flib_table.deep_copy(stored)
end

function set_signal_combinator_entity(entity)
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

local function unload_metric_if_empty(metric_name)
    debug_print("Starting unload check for \"" .. metric_name .. "\"")
    local loaded_metric = signal_metrics[metric_name]
    if (loaded_metric ~= nil) and next(loaded_metric.groups) == nil then
        debug_print("Metric exists and its groups are empty")
        debug_print("Groups:")
        for k,v in pairs(loaded_metric.groups) do
            debug_print(tostring(k)..":"..tostring(v))
        end
        debug_print("Printed groups")
        local prometheus_metric = loaded_metric["prometheus-metric"]
        if prometheus_metric ~= nil then
            debug_print("Prometheus metric found, unregistering")
            prometheus.unregister(prometheus_metric)
            loaded_metric["prometheus-metric"] = nil
        end
        signal_metrics[metric_name] = nil
    else
        debug_print("Metric not found or group was not empty")
    end
end

function set_signal_combinator_data(unit_number, data)
    local previous_global_data = global["signal-data"]["combinators"][unit_number]
    local copy
    if data == nil then
        global["signal-data"]["combinators"][unit_number] = nil
    else
        copy = flib_table.deep_copy(data)
        global["signal-data"]["combinators"][unit_number] = copy
    end
    if previous_global_data == nil then
        debug_print("No previous combinator data")
    else
        local previous_metric_name = previous_global_data["metric-name"]
        local previous_group = enable_signal_groups and previous_global_data.group or ""
        local next_group = enable_signal_groups and data ~= nil and data.group or ""
        if previous_metric_name == nil or previous_metric_name == "" then
            debug_print("No previous metric name")
        else
            debug_print("Previous metric name: \"" .. previous_metric_name .. "\"")
            if (data == nil or previous_metric_name ~= data["metric-name"]) or (previous_group ~= next_group and previous_group ~= nil and previous_group ~= "") then
                debug_print("Previous stuff is different, remove from old group: \"" .. previous_metric_name .. "\"/\"" .. previous_group .. "\"")
                local old_signal_metric_data = signal_metrics[previous_metric_name]
                if old_signal_metric_data ~= nil then
                    local old_signal_group_data = old_signal_metric_data.groups
                    if old_signal_group_data[previous_group] ~= nil then
                        debug_print("Group found")
                        old_signal_group_data[previous_group][unit_number] = nil
                        unload_metric_if_empty(previous_metric_name)
                    else
                        debug_print("Group not found")
                    end
                else
                    debug_print("Metric not found in signal_metrics")
                end
            else
                debug_print("Metric name same and group same / was nil")
            end
        end
    end
    if copy ~= nil then
        load_combinator(unit_number, copy)
    end
end

function get_metric_data(metric_name)
    local stored = global["signal-data"]["metrics"][metric_name]
    if stored ~= nil then
        return flib_table.deep_copy(stored)
    else
        return nil
    end
end

function set_metric_data(metric_name, data)
    local copy = flib_table.deep_copy(data)
    global["signal-data"]["metrics"][metric_name] = copy
    load_metric(metric_name, copy)
end

function new_custom_metric(options)
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

function new_prometheus_combinator(entity)
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