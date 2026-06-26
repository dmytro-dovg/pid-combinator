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

    local output_entity = create_output_for(entity)
    debugp("Created main " .. serpent.dump(entity))
    debugp("Created hidden " .. serpent.dump(output_entity))
    storage.pid = storage.pid or {}
    storage.pid[entity.unit_number] = {
        entity = entity,
        output_entity = output_entity,
        -- PID coefficients 
        kp = 1.0, ki = 0.0, kd = 0.0,
        -- PID state
        integral = 0,
        prev_error = 0,
        -- Signals
        pv_signal = { name = "signal-P", type = "virtual" },
        sp_signal = { name = "signal-S", type = "virtual" },
        out_signal = { name = "signal-O", type = "virtual" },
    }
end

local function on_removed(event)
    debugp("Event: " .. event.name)
    local entity = event.entity
    if not entity or entity.name ~= "pid-combinator" then return end

    local state = storage.pid and storage.pid[entity.unit_number]
    if state and state.output_entity and state.output_entity.valid then
        debugp("Destroyed hidden " .. serpent.dump(state.output_entity))
        state.output_entity.destroy()
    end

    if storage.pid then
        storage.pid[entity.unit_number] = nil
    end
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

local UPDATE_RATE = 1

local function process_pid(state, dt)
    local entity = state.entity

    local red_network = entity.get_circuit_network(connector_id.input["red"])
    local green_network = entity.get_circuit_network(connector_id.input["green"])

    if not red_network and not green_network then return end

    debugp("Red " .. serpent.dump(red_network))
    debugp("Green " .. serpent.dump(green_network))

    local pv = 0
    local sp = 0
    -- TODO: toggle networks
    if red_network then
        pv = pv + (red_network.get_signal(state.pv_signal) or 0)
        sp = sp + (red_network.get_signal(state.sp_signal) or 0)
    end

    if green_network then
        pv = pv + (green_network.get_signal(state.pv_signal) or 0)
        sp = sp + (green_network.get_signal(state.sp_signal) or 0)
    end

    local error = sp - pv
    debugp("pv = " .. pv .. ", sp = " .. sp .. ", error = " .. error)
    state.integral = math.max(-200, math.min(200, state.integral + error * dt))
    local derivative = (error - state.prev_error) / dt
    state.prev_error = error
    local output = 2.0 * error
        + 1 * state.integral
        + 0.6 * derivative

    write_output(state.output_entity, math.floor(output))
end

script.on_event(defines.events.on_tick, function(event)
    if event.tick % UPDATE_RATE ~= 0 then return end
    if not storage.pid then return end

    local dt = UPDATE_RATE / 60

    for unit_number, state in pairs(storage.pid) do
        if not state.entity.valid or not state.output_entity.valid then
            storage.pid[unit_number] = nil
        else
            process_pid(state, dt)
        end
    end
end)
