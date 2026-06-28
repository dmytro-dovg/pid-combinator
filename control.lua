local pid_gui = require "gui.pid-combinator-gui"

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

local function write_output(output_entity, value)
    local cb = output_entity.get_or_create_control_behavior()
    local section = cb.get_section(1)
    if not section then
        section = cb.add_section("output")
        section.active = true
    end
    local filter = {
        value = {
            type = "virtual",
            name = "signal-O",
            comparator = "=",
            quality = "normal",
        },
        -- Clamp value as the game crashes when it goes out of bounds of int32
        min = math.min(2147483647, math.max(-2147483648, value)),
    }
    section.set_slot(1, filter)
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
    for _, color in ipairs({"red", "green"}) do
        local transmitter = entity.get_wire_connector(connector_id.output[color], true)
        local receiver = hidden.get_wire_connector(connector_id.input[color], true)
        transmitter.connect_to(receiver, false, defines.wire_origin.script)
    end

    return hidden
end

local function on_built(event)
    local entity = event.entity
    if not entity or entity.name ~= "pid-combinator" then return end
    if storage.pid and storage.pid[entity.unit_number] then return end
    local output_entity = create_output_for(entity)
    debugp("Created main " .. serpent.dump(entity))
    debugp("Created hidden " .. serpent.dump(output_entity))
    storage.pid = storage.pid or {}
    storage.pid[entity.unit_number] = {
        entity = entity,
        output_entity = output_entity,
        -- PID settings
        kp = 1.0, ki = 0.0, kd = 0.0,
        max_integral = 200, -- anti-windup
        signals = {
            pv = { name = "signal-V", type = "virtual" },
            sp = { name = "signal-S", type = "virtual" },
            out = { name = "signal-O", type = "virtual" },
        },
        -- PID state
        integral = 0,
        prev_error = 0,
        prev_tick = nil,
    }
end

local function on_removed(event)
    debugp("Event: " .. event.name)
    local entity = event.entity
    if not entity or entity.name ~= "pid-combinator" then return end

    if storage.pid_guis then
        for player_index, per_player in pairs(storage.pid_guis) do
            if per_player[entity.unit_number] then
                pid_gui.destroy(player_index, entity.unit_number)
            end
        end
    end

    local state = storage.pid and storage.pid[entity.unit_number]
    if state and state.output_entity and state.output_entity.valid then
        debugp("Destroyed hidden " .. serpent.dump(state.output_entity))
        state.output_entity.destroy()
    end

    if storage.pid then
        storage.pid[entity.unit_number] = nil
    end

end

local function on_gui_open(event)
    local entity = event.entity
    if not entity or entity.name ~= "pid-combinator" then return end
    local state = storage.pid and storage.pid[entity.unit_number]
    if not state then return end
    debugp("Opening " .. entity.name)
    local player = game.get_player(event.player_index)
    pid_gui.destroy(event.player_index, entity.unit_number)
    player.opened = nil
    pid_gui.display(player, state)
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

local function process_pid(state, tick)
    local entity = state.entity

    local red_network = entity.get_circuit_network(connector_id.input["red"])
    local green_network = entity.get_circuit_network(connector_id.input["green"])

    if not red_network and not green_network then return end

    --debugp("Red " .. serpent.dump(red_network))
    --debugp("Green " .. serpent.dump(green_network))

    local pv = 0
    local sp = 0
    local kp = state.kp
    local ki = state.ki
    local kd = state.kd
    local max_integral = state.max_integral
    -- TODO: toggle networks
    if red_network then
        pv = pv + (red_network.get_signal(state.signals.pv) or 0)
        sp = sp + (red_network.get_signal(state.signals.sp) or 0)
    end

    if green_network then
        pv = pv + (green_network.get_signal(state.signals.pv) or 0)
        sp = sp + (green_network.get_signal(state.signals.sp) or 0)
    end

    local err = sp - pv

    local prev_tick = state.prev_tick or (tick - 1)
    local dt = (tick - prev_tick) / 60
    -- Clamp dt to limit huge integral tick
    if dt > 1 then dt = 1 end
    -- Safeguard agains abnormal ticks
    if dt <= 0 then state.prev_tick = tick; return end
    state.prev_tick = tick

    -- Clamp integral to prevent windup
    state.integral = math.max(-max_integral, math.min(max_integral, state.integral + err * dt))
    local derivative = (err - state.prev_error) / dt
    state.prev_error = err
    local output = kp * err
        + ki * state.integral
        + kd * derivative


    write_output(state.output_entity, math.floor(output))
    return { output = output, pv = pv, sp = sp }
end

script.on_event(defines.events.on_tick, function(event)
    if not storage.pid then return end
    for unit_number, state in pairs(storage.pid) do
        if not state.entity.valid or not state.output_entity.valid then
            storage.pid[unit_number] = nil
        else
            local value = process_pid(state, event.tick)
            -- With every added GUI reduce sample rate to protect game UPS
            local n = pid_gui.gui_count()
            if value and n > 0 and event.tick % n == 0 then
                for player_index, per_player in pairs(storage.pid_guis) do
                    local gui_state = per_player[unit_number]
                    if gui_state then
                        pid_gui.plot(player_index, gui_state, value.pv, event.tick)
                    end
                end
            end
        end
    end
end)
