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

-- ============================================================================
-- Entity functions
-- ============================================================================

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
    hidden.operable = false
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

local function position_key(surface_index, position)
    return surface_index .. ":" .. position.x .. ":" .. position.y
end

-- ============================================================================
-- Fast-replace stash
-- ============================================================================

local function stash_fast_replace(entity, snapshot)
    storage.fast_replace_stash = storage.fast_replace_stash or {}
    for key, stash in pairs(storage.fast_replace_stash) do
        if stash.tick ~= game.tick then
            storage.fast_replace_stash[key] = nil
        end
    end
    storage.fast_replace_stash[position_key(entity.surface.index, entity.position)] =
        { settings = snapshot, tick = game.tick }
end

local function pop_fast_replace(entity)
    if not storage.fast_replace_stash then return nil end
    local key = position_key(entity.surface.index, entity.position)
    local stash = storage.fast_replace_stash[key]
    if not stash then return nil end
    storage.fast_replace_stash[key] = nil
    if stash.tick ~= game.tick then return nil end
    return stash.settings
end

-- ============================================================================
-- Undo / redo
-- undo_cache: written on mine, consumed when undo-of-a-mine restores a ghost.
-- redo_cache: written on any removal, consumed when redo-of-a-build restores
-- the entity that was removed by undo.
-- on_undo_applied / on_redo_applied fire BEFORE the game applies the action,
-- so restoration is deferred one tick.
-- ============================================================================

local UNDO_REDO_MAX_AGE = 60 * 60 * 60

local function cache_put(cache, entity, snapshot)
    for key, cached in pairs(cache) do
        if game.tick - cached.tick > UNDO_REDO_MAX_AGE then
            cache[key] = nil
        end
    end
    cache[position_key(entity.surface.index, entity.position)] =
        { settings = snapshot, tick = game.tick }
end

local function cache_pop(cache, surface_index, position)
    if not cache then return nil end
    local key = position_key(surface_index, position)
    local cached = cache[key]
    if not cached then return nil end
    cache[key] = nil
    return cached.settings
end

local function remember_for_undo(entity, snapshot)
    storage.undo_cache = storage.undo_cache or {}
    cache_put(storage.undo_cache, entity, snapshot)
end

local function remember_for_redo(entity, snapshot)
    storage.redo_cache = storage.redo_cache or {}
    cache_put(storage.redo_cache, entity, snapshot)
end

local function apply_undo_redo(surface_index, position, settings)
    local surface = game.get_surface(surface_index)
    if not surface or not surface.valid then return end

    for _, ghost in ipairs(surface.find_entities_filtered { position = position, ghost_name = "pid-combinator" }) do
        if ghost.valid then
            local tags = ghost.tags or {}
            tags.pid_settings = settings
            ghost.tags = tags
        end
    end

    for _, entity in ipairs(surface.find_entities_filtered { position = position, name = "pid-combinator" }) do
        if entity.valid then
            local state = storage.pid and storage.pid[entity.unit_number]
            if state then
                PidSettings.copy(settings, state)
            end
        end
    end
end

-- ============================================================================
-- Lifecycle handlers
-- ============================================================================

local function on_built(event)
    debugp("on_built")
    local entity = event.entity
    if not entity then return end

    if entity.name == "pid-combinator" then
        local carryover_settings = (event.tags and event.tags.pid_settings) or pop_fast_replace(entity)
        entity.operable = false
        setup_combinator(entity, carryover_settings)
        pid_gui.migrate_ghost_viewers(entity)
    elseif entity.type == "entity-ghost" and entity.ghost_name == "pid-combinator" then
        entity.operable = false
    end
end

local function on_removed(event)
    local entity = event.entity
    if not entity or entity.name ~= "pid-combinator" then return end

    local state = storage.pid and storage.pid[entity.unit_number]
    if state then
        local snapshot = {}
        PidSettings.copy(state, snapshot)
        remember_for_redo(entity, snapshot)
        if event.name == defines.events.on_pre_player_mined_item
            or event.name == defines.events.on_robot_pre_mined then
            stash_fast_replace(entity, snapshot)
            remember_for_undo(entity, snapshot)
        end
    end

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

    if state and state.output_entity and state.output_entity.valid then
        debugp("Destroyed hidden " .. serpent.dump(state.output_entity))
        state.output_entity.destroy()
    end

    if event.name == defines.events.on_entity_died then return end
    if storage.pid then
        storage.pid[entity.unit_number] = nil
    end
end

local function on_post_entity_died(event)
    local unit_number = event.unit_number
    if not unit_number then return end
    if event.prototype and event.prototype.name ~= "pid-combinator" then return end

    local source = storage.pid and storage.pid[unit_number]
    local ghost = event.ghost
    -- Carry over settings to the replacement entity via the ghost's tags.
    if ghost and ghost.valid and source then
        local pid_settings = {}
        PidSettings.copy(source, pid_settings)
        local tags = ghost.tags or {}
        tags.pid_settings = pid_settings
        ghost.tags = tags
    end

    if storage.pid then
        storage.pid[unit_number] = nil
    end
end

local function on_entity_cloned(event)
    local dst = event.destination
    if not dst or dst.name ~= "pid-combinator" then return end
    local src = event.source
    local carryover_settings = src and src.unit_number and storage.pid and storage.pid[src.unit_number]
    setup_combinator(dst, carryover_settings)
end

local function schedule_undo_redo(surface_index, position, settings)
    storage.pending_undo_redo = storage.pending_undo_redo or {}
    storage.pending_undo_redo[#storage.pending_undo_redo + 1] = {
        surface_index = surface_index,
        position = { x = position.x, y = position.y },
        settings = settings,
        due_tick = game.tick + 1,
    }
end

local function collect_undo_redo(actions, cache)
    for _, action in ipairs(actions or {}) do
        if action.target and action.target.name == "pid-combinator" and action.surface_index then
            local settings = cache_pop(cache, action.surface_index, action.target.position)
            if settings then
                schedule_undo_redo(action.surface_index, action.target.position, settings)
            end
        end
    end
end

local function on_undo_applied(event)
    collect_undo_redo(event.actions, storage.undo_cache)
end

local function on_redo_applied(event)
    collect_undo_redo(event.actions, storage.redo_cache)
end

-- ============================================================================
-- Player handlers
-- ============================================================================

local function on_player_removed(event)
    local player = game.get_player(event.player_index)
    if player then pid_gui.cleanup(player) end
    if storage.copy_sources then
        storage.copy_sources[event.player_index] = nil
    end
end

-- ============================================================================
-- Interaction handlers
-- ============================================================================

local function on_open_input(event)
    local player = game.get_player(event.player_index)
    if not player then return end

    -- Skip when the cursor is holding something (wire, blueprint, etc.).
    if player.cursor_stack and player.cursor_stack.valid_for_read then return end
    if player.cursor_ghost then return end

    local entity = player.selected
    if not entity then return end
    if player.force ~= entity.force then return end

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

    debugp("Opening " .. entity.name)
    pid_gui.destroy(event.player_index, entity.unit_number)
    pid_gui.display(player, target)
end

local function selected_pid_state(event)
    local player = game.get_player(event.player_index)
    if not player then return nil end
    local entity = player.selected
    if not entity or entity.name ~= "pid-combinator" then return nil end
    if player.force ~= entity.force then return nil end
    return storage.pid and storage.pid[entity.unit_number]
end

local function on_copy_input(event)
    local state = selected_pid_state(event)
    if not state then return end
    storage.copy_sources = storage.copy_sources or {}
    local snapshot = {}
    PidSettings.copy(state, snapshot)
    storage.copy_sources[event.player_index] = snapshot
end

local function on_paste_input(event)
    local state = selected_pid_state(event)
    if not state then return end
    local snapshot = storage.copy_sources and storage.copy_sources[event.player_index]
    if not snapshot then return end
    PidSettings.copy(snapshot, state)
end

-- Fallback for editor mode: `operable = false` and `not-selectable-in-game`
-- are both bypassed there, so the vanilla arithmetic combinator GUI and the
-- hidden constant combinator GUI can still be opened.
local function on_gui_opened_fallback(event)
    local entity = event.entity
    if not entity or not entity.valid then return end
    local player = game.get_player(event.player_index)
    if not player then return end

    if entity.name == "pid-combinator-output" then
        player.opened = nil
        return
    end

    if entity.name == "pid-combinator" then
        local state = storage.pid and storage.pid[entity.unit_number]
        if not state then return end
        player.opened = nil
        pid_gui.destroy(event.player_index, entity.unit_number)
        pid_gui.display(player, SettingsTarget.live(entity.unit_number))
        return
    end

    if entity.type == "entity-ghost" and entity.ghost_name == "pid-combinator" then
        player.opened = nil
        pid_gui.destroy(event.player_index, entity.unit_number)
        pid_gui.display(player, SettingsTarget.ghost(entity))
    end
end

-- ============================================================================
-- Blueprint handlers
-- ============================================================================

local function on_blueprint_settings_pasted(event)
    local entity = event.entity
    if not entity or not entity.valid then return end
    if entity.name ~= "pid-combinator" then return end
    local state = storage.pid and storage.pid[entity.unit_number]
    if not state then return end

    if event.player_index then
        local player = game.get_player(event.player_index)
        if not player or not player.valid then return end
        if player.force ~= entity.force then return end
    end

    if event.tags and event.tags.pid_settings then
        PidSettings.copy(event.tags.pid_settings, state)
    end
end

local function on_player_setup_blueprint(event)
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
end

-- ============================================================================
-- PID processing
-- ============================================================================

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

local function drain_pending_undo_redo(tick)
    if not storage.pending_undo_redo or #storage.pending_undo_redo == 0 then return end
    local remaining = {}
    for _, pending in ipairs(storage.pending_undo_redo) do
        if tick >= pending.due_tick then
            apply_undo_redo(pending.surface_index, pending.position, pending.settings)
        else
            remaining[#remaining + 1] = pending
        end
    end
    storage.pending_undo_redo = remaining
end

local function on_tick(event)
    drain_pending_undo_redo(event.tick)
    if not storage.pid then return end
    for unit_number, state in pairs(storage.pid) do
        if not state.entity.valid or not state.output_entity.valid then
            storage.pid[unit_number] = nil
        else
            local value = process_pid(state, event.tick)
            pid_gui.on_tick(unit_number, state.entity.status, state.graph_data, event.tick, value)
        end
    end
end

-- ============================================================================
-- Events
-- ============================================================================

local pid_filter = {{filter = "name", name = "pid-combinator"}}
local built_filter = {
    {filter = "name", name = "pid-combinator"},
    {filter = "ghost_name", name = "pid-combinator", mode = "or"},
}

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
    defines.events.script_raised_destroy,
}

for _, event in pairs(on_built_events) do
    script.on_event(event, on_built, built_filter)
end

for _, event in pairs(on_removed_events) do
    script.on_event(event, on_removed, pid_filter)
end

script.on_event(defines.events.on_post_entity_died, on_post_entity_died, {{filter = "type", type = "arithmetic-combinator"}})
script.on_event(defines.events.on_entity_cloned, on_entity_cloned)
script.on_event(defines.events.on_undo_applied, on_undo_applied)
script.on_event(defines.events.on_redo_applied, on_redo_applied)
script.on_event(defines.events.on_player_removed, on_player_removed)
script.on_event(defines.events.on_blueprint_settings_pasted, on_blueprint_settings_pasted)
script.on_event(defines.events.on_player_setup_blueprint, on_player_setup_blueprint)
script.on_event(defines.events.on_tick, on_tick)

script.on_event("pid-combinator-open", on_open_input)
script.on_event("pid-combinator-copy", on_copy_input)
script.on_event("pid-combinator-paste", on_paste_input)

script.on_event(defines.events.on_gui_opened, on_gui_opened_fallback)

-- Stub to handle migration in future version
local function on_configuration_changed(_event) end

script.on_init(function() end)
script.on_configuration_changed(on_configuration_changed)
