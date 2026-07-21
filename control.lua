local PidGui = require "gui.pid-combinator-gui"
local List = require "utils.list"
local PidSettings = require "model.pid-settings"
local SettingsTarget = require "gui.settings-target"
local PidTuning = require "model.pid-tuning"
local C = require "constants"

---@class PidPendingConnectionChange
---@field wire_type WireType
---@field value boolean

---@class PidGraphSample
---@field tick uint
---@field value integer
---@field sp integer?

---@class PidState: PidSettings
---@field entity LuaEntity
---@field output_entity LuaEntity hidden constant combinator entity
---@field pending_connection_changes PidPendingConnectionChange[]
---@field integral number
---@field prev_tick uint? last tick that ran the PID compute
---@field prev_pv integer? PV on the previous tick
---@field filtered_derivative number low-pass-filtered derivative
---@field graph_data List<PidGraphSample>
---@field tuner PidTuningSession? active autotune session

---@class PidTickResult
---@field output number
---@field pv integer
---@field sp integer
---@field p number
---@field i number
---@field d number

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

---Wipes transient PID state.
---@param state PidState
local function state_reset(state)
    state.prev_tick = nil
    state.prev_pv = nil
    state.integral = 0
    state.filtered_derivative = 0
    state.tuner = nil
end

-- ============================================================================
-- Entity functions
-- ============================================================================

---Toggle section.
---@param section LuaLogisticSection?
---@param wanted boolean
local function set_section_active(section, wanted)
    if section and section.active ~= wanted then
        section.active = wanted
    end
end

---@param state PidState
---@param value number
local function write_output(state, value)
    local cb = state.output_entity.get_or_create_control_behavior()
    if not cb then return end
    local section = cb.get_section(1)
    if not section then
        section = cb.add_section("output")
    end

    local pending_changes = state.pending_connection_changes or {}
    if next(pending_changes) then
        for _, change in pairs(pending_changes) do
            local origin = defines.wire_origin.script
            local wire_type = change.wire_type
            local pid_combinator_connector = state.entity.get_wire_connector(connector_id.output[wire_type], false)
            local output_combinator_connector = state.output_entity.get_wire_connector(connector_id.input[wire_type], false)
            if pid_combinator_connector and output_combinator_connector then
                if change.value then
                    pid_combinator_connector.connect_to(output_combinator_connector, false, origin)
                else
                    pid_combinator_connector.disconnect_from(output_combinator_connector, origin)
                end
            end
        end

        -- Empty list since changes were applied
        state.pending_connection_changes = {}
    end

    if state.signals.output then
        set_section_active(section, true)
        -- Clamp value as the game crashes when it goes out of bounds of int32
        local clamped = math.min(C.pid.output_max, math.max(C.pid.output_min, math.floor(value)))
        if clamped ~= state.last_value then
            section.set_slot(1, {
                value = {
                    type = state.signals.output.type,
                    name = state.signals.output.name,
                    comparator = "=",
                    quality = state.signals.output.quality or "normal",
                },
                min = clamped,
            })
            state.last_value = clamped
        end
    else
        set_section_active(section, false)
    end
end

---Creates the hidden constant combinator entity paired with a PID combinator and
---wires it up to both output connectors.
---@param entity LuaEntity
---@return LuaEntity?
local function create_output_for(entity)
    local surface = entity.surface
    local hidden = surface.create_entity{
        name = "pid-combinator-output",
        position = entity.position,
        force = entity.force,
        create_build_effect_smoke = false,
    }
    if not hidden then return end
    hidden.destructible = false
    hidden.operable = false
    for _, wire_type in ipairs({"red", "green"}) do
        local pid_combinator_connector = entity.get_wire_connector(connector_id.output[wire_type], true)
        local output_combinator_connector = hidden.get_wire_connector(connector_id.input[wire_type], true)
        if pid_combinator_connector and output_combinator_connector then
            pid_combinator_connector.connect_to(output_combinator_connector, false, defines.wire_origin.script)
        end
    end

    return hidden
end

---Queue reconnection of both output wires to match the `networks.output`
---flags. Needed after settings are applied outside the GUI.
---@param state PidState
local function sync_output_connections(state)
    state.pending_connection_changes = {
        { wire_type = "red", value = state.networks.output.red },
        { wire_type = "green", value = state.networks.output.green },
    }
end

---Initialises PidState for new entity.
---@param entity LuaEntity
---@param settings PidSettings?
local function setup_combinator(entity, settings)
    if storage.pid and storage.pid[entity.unit_number] then return end
    local output_entity = create_output_for(entity)
    storage.pid = storage.pid or {}
    storage.pid[entity.unit_number] = {
        entity = entity,
        output_entity = output_entity,
        pending_connection_changes = { },
        -- PID state
        integral = 0,
        prev_tick = nil,
        prev_pv = nil,
        filtered_derivative = 0,
        graph_data = List.new(),
    }
    local new_settings = storage.pid[entity.unit_number]
    if settings then
        PidSettings.copy(settings, new_settings)
    else
        PidSettings.copy(PidSettings.defaults(), new_settings)
    end
end

---@param surface_index uint
---@param position MapPosition
---@return string
local function position_key(surface_index, position)
    return surface_index .. ":" .. position.x .. ":" .. position.y
end

---@param entity LuaEntity
---@param signal SignalID?
---@param use_red boolean
---@param use_green boolean
local function read_signal(entity, signal, use_red, use_green)
    if not signal then return 0 end

    local red_id = use_red and connector_id.input["red"] or nil
    local green_id = use_green and connector_id.input["green"] or nil

    if red_id and green_id then
        return entity.get_signal(signal, red_id, green_id) or 0
    elseif red_id or green_id then
        return entity.get_signal(signal, red_id or green_id) or 0
    end
    return 0
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

local function cache_put(cache, entity, snapshot)
    for key, cached in pairs(cache) do
        if game.tick - cached.tick > C.undo_redo_max_age_ticks then
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
            PidGui.refresh(ghost.unit_number)
        end
    end

    for _, entity in ipairs(surface.find_entities_filtered { position = position, name = "pid-combinator" }) do
        if entity.valid then
            local state = storage.pid and storage.pid[entity.unit_number]
            if state then
                PidSettings.copy(settings, state)
                sync_output_connections(state)
                PidGui.refresh(entity.unit_number)
            end
        end
    end
end

-- ============================================================================
-- Lifecycle handlers
-- ============================================================================

local function on_built(event)
    local entity = event.entity
    if not entity or not entity.valid then return end
    if entity.name == "pid-combinator" then
        local carryover_settings = (event.tags and event.tags.pid_settings) or pop_fast_replace(entity)
        entity.operable = false
        setup_combinator(entity, carryover_settings)
        PidGui.migrate_ghost_guis(entity)
    elseif entity.type == "entity-ghost" and entity.ghost_name == "pid-combinator" then
        entity.operable = false
    end
end

---@param unit_number uint
local function close_guis(unit_number)
    local guis = storage.pid_guis and storage.pid_guis[unit_number]
    if not guis then return end
    local player_indices = {}
    for player_index, _ in pairs(guis) do
        player_indices[#player_indices + 1] = player_index
    end
    for _, player_index in ipairs(player_indices) do
        PidGui.destroy(player_index, unit_number)
    end
end

local function on_removed(event)
    local entity = event.entity
    if not entity or not entity.valid then return end

    -- In editor mode a player can select and remove the hidden entity directly.
    -- Destroy main combinator if hidden output is removed.
    if entity.name == "pid-combinator-output" then
        for _, pid in ipairs(entity.surface.find_entities_filtered {
            position = entity.position,
            name = "pid-combinator",
        }) do
            if pid.valid then
                pid.destroy{ raise_destroy = true }
            end
        end
        return
    end

    if entity.type == "entity-ghost" and entity.ghost_name == "pid-combinator" then
        close_guis(entity.unit_number)
        return
    end

    if entity.name ~= "pid-combinator" then return end

    local state = storage.pid and storage.pid[entity.unit_number]
    if state then
        local snapshot = {}
        PidSettings.copy(state, snapshot)
        remember_for_redo(entity, snapshot)
        if event.name == defines.events.on_pre_player_mined_item
            or event.name == defines.events.on_robot_pre_mined
            or event.name == defines.events.on_space_platform_pre_mined then
            stash_fast_replace(entity, snapshot)
            remember_for_undo(entity, snapshot)
        end
    end

    close_guis(entity.unit_number)

    if state and state.output_entity and state.output_entity.valid then
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
    dst.operable = false
    -- Area clone will also duplicate the hidden output combinator.
    -- Delete it before we setup a new one.
    local old_output = dst.surface.find_entity("pid-combinator-output", dst.position)
    if old_output then
        old_output.destroy()
    end
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
    if player then PidGui.cleanup(player) end
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
    if not entity or not entity.valid then return end
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

    PidGui.destroy(event.player_index, entity.unit_number)
    PidGui.display(player, target)
end

---@param event { player_index: uint }
---@param type string?
---@return LuaEntity?
local function entity_for_input_event(event, type)
    local player = game.get_player(event.player_index)
    if not player then return nil end
    local entity = player.selected
    if not entity or not entity.valid then return nil end
    if player.force ~= entity.force then return nil end
    if type and entity.name ~= type then return nil end
    return entity
end

---@param entity LuaEntity
---@return PidState?
local function selected_pid_state(entity)
    return storage.pid and storage.pid[entity.unit_number]
end

local function on_copy_input(event)
    local entity = entity_for_input_event(event, "pid-combinator")
    storage.copy_sources = storage.copy_sources or {}
    -- Copy has been called on a different entity type.
    -- Clear currently copied settings to match vanilla Factorio behaviour.
    if not entity then
        storage.copy_sources[event.player_index] = nil
        return
    end
    local state = selected_pid_state(entity)
    if not state then return end
    local snapshot = {}
    PidSettings.copy(state, snapshot)
    storage.copy_sources[event.player_index] = snapshot
end

local function on_paste_input(event)
    local entity = entity_for_input_event(event, "pid-combinator")
    if not entity then return end
    local state = selected_pid_state(entity)
    if not state then return end
    local snapshot = storage.copy_sources and storage.copy_sources[event.player_index]
    if not snapshot then return end
    PidSettings.copy(snapshot, state)
    sync_output_connections(state)
    PidGui.refresh(state.entity.unit_number)
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
        PidGui.destroy(event.player_index, entity.unit_number)
        PidGui.display(player, SettingsTarget.live(entity.unit_number))
        return
    end

    if entity.type == "entity-ghost" and entity.ghost_name == "pid-combinator" then
        player.opened = nil
        PidGui.destroy(event.player_index, entity.unit_number)
        PidGui.display(player, SettingsTarget.ghost(entity))
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
        sync_output_connections(state)
        PidGui.refresh(state.entity.unit_number)
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

    if not blueprint then return end
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

---Main per-tick PID compute. Reads PV/SP from the circuit networks, updates
---integrator and derivative filter, computes output, writes to the actuator.
---Runs `PidTuning` if a tune is in progress.
---@param state PidState
---@param tick uint
---@return PidTickResult? nil when nothing needs to be reported to the GUI
local function process_pid(state, tick)
    local entity = state.entity
    if entity.status == defines.entity_status.no_power then
        state_reset(state)
        local cb = state.output_entity.get_or_create_control_behavior()
        if not cb then return end
        local section = cb.get_section(1)
        set_section_active(section, false)
        return
    end

    local pv = read_signal(entity, state.signals.pv, state.networks.pv.red, state.networks.pv.green)
    local sp = read_signal(entity, state.signals.sp, state.networks.sp.red, state.networks.sp.green)

    if state.tuner then
        if PidTuning.is_running(state.tuner) then
            local tuner_output = PidTuning.loop(state.tuner, pv, tick)
            write_output(state, tuner_output)
            if PidGui.gui_count() > 0 then
                return { output = tuner_output, pv = pv, sp = sp, p = 0, i = 0, d = 0 }
            end
            return
        elseif PidTuning.is_done(state.tuner) then
            state.kp = state.tuner.result.kp
            state.ki = state.tuner.result.ki
            state.kd = state.tuner.result.kd
            state_reset(state)
            PidGui.refresh(entity.unit_number)
        elseif PidTuning.is_aborted(state.tuner) then
            state_reset(state)
        end
    end

    local anti_windup_limit = state.anti_windup_limit
    local err = sp - pv

    local prev_tick = state.prev_tick or (tick - 1)
    local dt = (tick - prev_tick) * C.seconds_per_tick
    if dt > C.pid.dt_clamp_seconds then dt = C.pid.dt_clamp_seconds end
    -- Safeguard against abnormal ticks
    if dt <= 0 then state.prev_tick = tick; return end
    state.prev_tick = tick

    -- Clamp integral to prevent windup
    state.integral = math.max(-anti_windup_limit, math.min(anti_windup_limit, state.integral + err * dt))

    -- Derivative on the measurement (not the error) so a setpoint step doesn't
    -- produce a derivative kick. Passed through a low-pass filter to tame noise on Kd.
    local prev_pv = state.prev_pv or pv
    local raw_derivative = -(pv - prev_pv) / dt
    local alpha = C.pid.derivative_lpf_alpha
    state.filtered_derivative = (1 - alpha) * (state.filtered_derivative or 0) + alpha * raw_derivative
    state.prev_pv = pv

    local p_term = state.kp * err
    local i_term = state.ki * state.integral
    local d_term = state.kd * state.filtered_derivative
    local output = p_term + i_term + d_term

    write_output(state, output)
    -- We don't need to build a table when there are no open GUIs
    if PidGui.gui_count() > 0 then
        return { output = output, pv = pv, sp = sp, p = p_term, i = i_term, d = d_term }
    end
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
        if not state.entity.valid then
            close_guis(unit_number)
            storage.pid[unit_number] = nil
        elseif not state.output_entity.valid then
            state.entity.destroy{ raise_destroy = true }
        else
            local value = process_pid(state, event.tick)
            PidGui.on_tick(unit_number, state, event.tick, value)
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
local removed_filter = {
    {filter = "name", name = "pid-combinator"},
    {filter = "name", name = "pid-combinator-output", mode = "or"},
    {filter = "ghost_name", name = "pid-combinator", mode = "or"},
}

local on_built_events = {
    defines.events.on_built_entity,
    defines.events.on_robot_built_entity,
    defines.events.on_space_platform_built_entity,
    defines.events.script_raised_built,
    defines.events.script_raised_revive,
}

local on_removed_events = {
    defines.events.on_entity_died,
    defines.events.on_pre_player_mined_item,
    defines.events.on_robot_pre_mined,
    defines.events.on_space_platform_pre_mined,
    defines.events.script_raised_destroy,
}

for _, event in pairs(on_built_events) do
    script.on_event(event, on_built, built_filter)
end

for _, event in pairs(on_removed_events) do
    script.on_event(event, on_removed, removed_filter)
end

-- Introduced in 2.1
if defines.events.on_blueprint_settings_pasted then
    script.on_event(defines.events.on_blueprint_settings_pasted, on_blueprint_settings_pasted)
end
script.on_event(defines.events.on_post_entity_died, on_post_entity_died, {{filter = "type", type = "arithmetic-combinator"}})
script.on_event(defines.events.on_entity_cloned, on_entity_cloned)
script.on_event(defines.events.on_undo_applied, on_undo_applied)
script.on_event(defines.events.on_redo_applied, on_redo_applied)
script.on_event(defines.events.on_player_removed, on_player_removed)
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
