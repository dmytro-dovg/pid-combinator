local pid_gui = require "gui.pid-combinator-gui"
local List = require "utils.list"
local PidSettings = require "model.pid-settings"
local SettingsTarget = require "gui.settings-target"

local function debugp(msg)
    localised_print("[PID CONTROLLER]: " .. msg)
end

local connector_id = {
    input = {
        red = defines.wire_connector_id.combinator_input_red,
        green = defines.wire_connector_id.combinator_input_green,
    },
    output = {
        red = defines.wire_connector_id.combinator_output_red,
        green = defines.wire_connector_id.combinator_output_green,
    },
}

local function write_output(state, value)
    local cb = state.output_entity.get_or_create_control_behavior()
    local section = cb.get_section(1)
    if not section then
        section = cb.add_section("output")
        section.active = true
    end

    local pending_changes = state.pending_connection_changes or {}
    for _, change in pairs(pending_changes) do
        local origin = defines.wire_origin.script
        local wire_type = change.wire_type
        local pid_combinator_connector = state.entity.get_wire_connector(connector_id.output[wire_type], false)
        local output_combinator_connector = state.output_entity.get_wire_connector(connector_id.input[wire_type], false)

        if change.value then
            pid_combinator_connector.connect_to(output_combinator_connector, false, origin)
        else
            pid_combinator_connector.disconnect_from(output_combinator_connector, origin)
        end
    end

    -- Empty list since changes were applied
    state.pending_connection_changes = {}

    if state.signals.output then
        section.set_slot(1, {
            value = {
                type = state.signals.output.type,
                name = state.signals.output.name,
                comparator = "=",
                quality = "normal",
            },
            -- Clamp value as the game crashes when it goes out of bounds of int32
            min = math.min(2147483647, math.max(-2147483648, math.floor(value))),
        })
    else
        section.clear_slot(1)
    end
end

local function create_output_for(entity)
    local surface = entity.surface
    local hidden = surface.create_entity{
        name = "pid-combinator-output",
        position = entity.position,
        force = entity.force,
        create_build_effect_smoke = false,
    }
    hidden.destructible = false
    for _, wire_type in ipairs({"red", "green"}) do
        local pid_combinator_connector = entity.get_wire_connector(connector_id.output[wire_type], true)
        local output_combinator_connector = hidden.get_wire_connector(connector_id.input[wire_type], true)
        pid_combinator_connector.connect_to(output_combinator_connector, false, defines.wire_origin.script)
    end

    return hidden
end

local function setup_combinator(entity, settings)
    if storage.pid and storage.pid[entity.unit_number] then return end
    local output_entity = create_output_for(entity)
    debugp("Created main " .. serpent.dump(entity))
    debugp("Created hidden " .. serpent.dump(output_entity))
    storage.pid = storage.pid or {}
    storage.pid[entity.unit_number] = {
        entity = entity,
        output_entity = output_entity,
        pending_connection_changes = { },
        -- PID state
        integral = 0,
        prev_error = 0,
        prev_tick = nil,
        graph_data = List.new(),
    }
    local new_settings = storage.pid[entity.unit_number]
    if settings then
        PidSettings.copy(settings, new_settings)
    else
        PidSettings.copy(PidSettings.defaults(), new_settings)
    end
end

local function on_built(event)
    debugp("on_built")
    local entity = event.entity
    if not entity or entity.name ~= "pid-combinator" then return end
    local carryover_settings = event.tags and event.tags.pid_settings
    setup_combinator(entity, carryover_settings)
    pid_gui.migrate_ghost_viewers(entity)
end

local function on_removed(event)
    local entity = event.entity
    if not entity or entity.name ~= "pid-combinator" then return end

    local viewers = storage.pid_guis and storage.pid_guis[entity.unit_number]
    if viewers then
        local player_indices = {}
        for player_index, _ in pairs(viewers) do
            player_indices[#player_indices + 1] = player_index
        end
        for _, player_index in ipairs(player_indices) do
            pid_gui.destroy(player_index, entity.unit_number)
        end
    end

    local state = storage.pid and storage.pid[entity.unit_number]
    if state and state.output_entity and state.output_entity.valid then
        debugp("Destroyed hidden " .. serpent.dump(state.output_entity))
        state.output_entity.destroy()
    end

    if event.name == defines.events.on_entity_died then return end
    if storage.pid then
        storage.pid[entity.unit_number] = nil
    end

end

script.on_event(defines.events.on_entity_settings_pasted, function(event)
    local src_number = event.source.unit_number
    local dst_number = event.destination.unit_number
    if not src_number or not dst_number then return end

    local src_state = storage.pid[src_number]
    local dst_state = storage.pid[dst_number]

    if not src_state or not dst_state then return end

    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end

    if player.force ~= event.destination.force or
       player.force ~= event.source.force then return end

    PidSettings.copy(src_state, dst_state)
end)

local function on_gui_open(event)
    local entity = event.entity
    if not entity then return end

    local player = game.get_player(event.player_index)
    if not player then return end

    local target
    if entity.name == "pid-combinator" then
        local state = storage.pid and storage.pid[entity.unit_number]
        if not state then return end
        target = SettingsTarget.live(entity.unit_number)
    elseif entity.type == "entity-ghost" and entity.ghost_name == "pid-combinator" then
        target = SettingsTarget.ghost(entity)
    else
        return
    end

    player.opened = nil

    debugp("Opening " .. entity.name)
    pid_gui.destroy(event.player_index, entity.unit_number)
    pid_gui.display(player, target)
end

local on_built_events = {
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
    defines.events.script_raised_built,
    defines.events.script_raised_revive,
}

local on_removed_events = {
    defines.events.on_entity_died,
    defines.events.on_pre_player_mined_item,
    defines.events.on_robot_pre_mined,
    defines.events.script_raised_destroy
}

for _, event in pairs(on_built_events) do
    script.on_event(event, on_built, {{filter="name", name="pid-combinator"}})
end

for _, event in pairs(on_removed_events) do
    script.on_event(event, on_removed, {{filter="name", name="pid-combinator"}})
end

script.on_event(defines.events.on_gui_opened, on_gui_open)

script.on_event(defines.events.on_player_removed, function(event)
    local player = game.get_player(event.player_index)
    if not player then return end

    pid_gui.cleanup(player)
end)

script.on_event(defines.events.on_post_entity_died, function(event)
    local unit_number = event.unit_number
    local ghost = event.ghost
    if not unit_number or event.prototype and event.prototype.name ~= "pid-combinator"  then return end

    -- Copy setting to carry over to new entity via a ghost
    if ghost then
        local source = storage.pid[unit_number]

        local pid_settings = {}
        PidSettings.copy(source, pid_settings)

        event.ghost.tags = { pid_settings = pid_settings }
    end

    -- Cleaning up the state of dead enity
    if storage.pid then
        storage.pid[unit_number] = nil
    end
end, {{filter="type", type="arithmetic-combinator"}})

script.on_event(defines.events.on_entity_cloned, function(event)
    local carryover_settings = event.source.unit_number and storage.pid[event.source.unit_number]
    setup_combinator(event.destination, carryover_settings)
end)

script.on_event(defines.events.on_player_setup_blueprint, function(event)
    local mapping = event.mapping.get()
    if not next(mapping) then return end

    local blueprint = event.stack
    if not (blueprint and blueprint.valid_for_read and blueprint.is_blueprint) then
        local player = game.get_player(event.player_index)
        if not player then return end
        if player.blueprint_to_setup and player.blueprint_to_setup.valid_for_read then
            blueprint = player.blueprint_to_setup
        elseif player.cursor_stack and player.cursor_stack.valid_for_read and player.cursor_stack.is_blueprint then
            blueprint = player.cursor_stack
        else
            return
        end
    end

    for blueprint_index, entity in pairs(mapping) do
        if entity.valid and entity.name == "pid-combinator" then
            local source = storage.pid and storage.pid[entity.unit_number]
            if source then
                local pid_settings = {}
                PidSettings.copy(source, pid_settings)
                blueprint.set_blueprint_entity_tag(blueprint_index, "pid_settings", pid_settings)
            end
        end
    end
end)

local function process_pid(state, tick)
    local entity = state.entity

    if entity.status == defines.entity_status.no_power then
        state.prev_tick = nil
        local cb = state.output_entity.get_or_create_control_behavior()
        local section = cb.get_section(1)
        if section then section.clear_slot(1) end
        return
    end

    local red_network = entity.get_circuit_network(connector_id.input["red"])
    local green_network = entity.get_circuit_network(connector_id.input["green"])

    if not red_network and not green_network then return end

    local pv = 0
    local sp = 0
    local kp = state.kp
    local ki = state.ki
    local kd = state.kd
    local max_integral = state.max_integral

    if red_network then
        if state.signals.pv and state.networks.pv.red then
            pv = pv + (red_network.get_signal(state.signals.pv) or 0)
        end
        if state.signals.sp and state.networks.sp.red then
            sp = sp + (red_network.get_signal(state.signals.sp) or 0)
        end
    end

    if green_network then
        if state.signals.pv and state.networks.pv.green then
            pv = pv + (green_network.get_signal(state.signals.pv) or 0)
        end
        if state.signals.sp and state.networks.sp.green then
            sp = sp + (green_network.get_signal(state.signals.sp) or 0)
        end
    end

    local err = sp - pv

    local prev_tick = state.prev_tick or (tick - 1)
    local dt = (tick - prev_tick) / 60
    -- Clamp dt to limit huge integral tick
    if dt > 1 then dt = 1 end
    -- Safeguard against abnormal ticks
    if dt <= 0 then state.prev_tick = tick; return end
    state.prev_tick = tick

    -- Clamp integral to prevent windup
    state.integral = math.max(-max_integral, math.min(max_integral, state.integral + err * dt))
    local derivative = (err - state.prev_error) / dt
    state.prev_error = err
    local output = kp * err
        + ki * state.integral
        + kd * derivative


    write_output(state, output)
    return { output = output, pv = pv, sp = sp }
end

script.on_event(defines.events.on_tick, function(event)
    if not storage.pid then return end
    for unit_number, state in pairs(storage.pid) do
        if not state.entity.valid or not state.output_entity.valid then
            storage.pid[unit_number] = nil
        else
            local value = process_pid(state, event.tick)
            pid_gui.on_tick(unit_number, state.entity.status, state.graph_data, event.tick, value)
        end
    end
end)
