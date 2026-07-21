local List = require "utils.list"
local InfoLabel = require "gui.info-label"
local SignalPicker = require "gui.signal-picker"
local ValueSlider = require "gui.value-slider"
local SettingsTarget = require "gui.settings-target"
local PidTuning = require "model.pid-tuning"
local C = require "constants"

---@class PidGuiControls
---@field status_sprite LuaGuiElement?
---@field status_label LuaGuiElement?
---@field last_status any
---@field sp_value_label LuaGuiElement?
---@field pv_value_label LuaGuiElement?
---@field output_value_label LuaGuiElement?
---@field sp_picker SignalPickerViews?
---@field pv_picker SignalPickerViews?
---@field output_picker SignalPickerViews?
---@field terms_button LuaGuiElement?
---@field pin_button LuaGuiElement?
---@field close_button LuaGuiElement?
---@field kp_views ValueSliderViews?
---@field ki_views ValueSliderViews?
---@field kd_views ValueSliderViews?
---@field anti_windup_limit_field LuaGuiElement?
---@field auto_tune_textfield LuaGuiElement?
---@field auto_tune_button LuaGuiElement?
---@field dropdown LuaGuiElement?
---@field bipolar_checkbox LuaGuiElement?
---@field side_frame LuaGuiElement?
---@field p_camera LuaGuiElement?
---@field i_camera LuaGuiElement?
---@field d_camera LuaGuiElement?
---@field graph LuaGuiElement?

---@class PidGuiState
---@field frame LuaGuiElement outer window
---@field graph { surface: LuaSurface, time_scale: number, peak: number? }
---@field controls PidGuiControls
---@field target SettingsTargetDescriptor descriptor for live/ghost target
---@field ghost_origin { surface_index: uint, position: { x: number, y: number } }? tracked for ghost migrations

---@alias PidGuis table<uint, PidGuiState> keyed by player_index

local PidCombinatorGui = {}

local offset = {
    x = (C.graph.viewport.width  / C.graph.tile_size) / 2,
    y = (C.graph.viewport.height / C.graph.tile_size) / 2,
}
local viewport_tile_width = C.graph.viewport.width / C.graph.tile_size

---Map a data value onto the graph surface's Y coordinate
---@param value number
---@param maximum_value number
---@return number
local function map_y(value, maximum_value)
    return -offset.y * (value / maximum_value)
end

---Center of a term indicator within a surface. P=1, I=2, D=3.
---@param index integer
---@return { x: number, y: number }
local function term_indicator_center(index)
    local row_pitch = (C.term_indicator.height_px + C.term_indicator.row_gap_px) * C.graph.px_per_tile
    return {
        x = C.term_indicator.surface_origin.x,
        y = C.term_indicator.surface_origin.y + (index - 1) * row_pitch,
    }
end

---Set the auto-tune button to the green "start" or red "cancel" look.
---@param button LuaGuiElement?
---@param tuning boolean
local function set_autotune_button(button, tuning)
    if not button or not button.valid then return end
    if tuning then
        button.style = "red_button"
        button.caption = {"gui-pid-combinator.autotune-cancel"}
        button.tooltip = {"gui-pid-combinator.autotune-cancel-tooltip"}
    else
        button.style = "green_button"
        button.caption = {"gui-pid-combinator.autotune"}
        button.tooltip = {"gui-pid-combinator.autotune-tooltip"}
    end
end

---Sync the status sprite, caption and auto-tune button on every open GUI of a combinator.
---@param guis PidGuis
---@param status any lookup key for `C.status_visuals`
local function update_status(guis, status)
    for _, gui_state in pairs(guis) do
        if gui_state.controls.last_status ~= status then
            gui_state.controls.last_status = status
            local status_visuals = C.status_visuals[status] or C.status_visuals.default
            local sprite_element = gui_state.controls.status_sprite
            local label_element = gui_state.controls.status_label
            if sprite_element and sprite_element.valid then sprite_element.sprite = status_visuals.sprite end
            if label_element and label_element.valid then label_element.caption = status_visuals.caption end
            set_autotune_button(gui_state.controls.auto_tune_button, status == "tuning")
        end
    end
end

---4-significant-figure compact format for gain fields.
---@param n number?
---@return string
local function format_gain(n)
    if n == nil then return "" end
    return string.format("%.4g", n)
end

---Compact format for value labels: whole numbers with k/M/G suffixes.
---@param n number
---@return string
local function format_value(n)
    if n == 0 then return "0" end
    local abs = math.abs(n)
    if abs >= 1e9 then return string.format("%.1fG", n / 1e9) end
    if abs >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if abs >= 1e4 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n))
end

---@param label LuaGuiElement?
---@param n number?
local function set_caption(label, n)
    if not label or not label.valid then return end
    label.caption = n and format_value(n) or ""
end

---@param guis PidGuis
---@param value PidTickResult?
local function update_value_labels(guis, value)
    for _, gui_state in pairs(guis) do
        set_caption(gui_state.controls.sp_value_label, value and value.sp)
        set_caption(gui_state.controls.pv_value_label, value and value.pv)
        set_caption(gui_state.controls.output_value_label, value and value.output)
    end
end

---@param player_index uint
---@param unit_number uint
---@return PidGuiState?
local function gui_state(player_index, unit_number)
    local guis = storage.pid_guis and storage.pid_guis[unit_number]
    return guis and guis[player_index]
end

---Sync a GUI update to every open GUI of a combinator except the initiator's.
---@param unit_number uint
---@param player_index uint? initiator's player_index; their GUI is skipped
---@param apply fun(controls: PidGuiControls)
local function broadcast(unit_number, player_index, apply)
    local guis = storage.pid_guis and storage.pid_guis[unit_number]
    if not guis then return end
    for pi, gui in pairs(guis) do
        if pi ~= player_index and gui.controls then
            apply(gui.controls)
        end
    end
end

---Destroy every GUI the player has open.
---@param player LuaPlayer
function PidCombinatorGui.cleanup(player)
    if not storage.pid_guis then return end
    local unit_numbers = {}
    for unit_number, guis in pairs(storage.pid_guis) do
        if guis[player.index] then unit_numbers[#unit_numbers + 1] = unit_number end
    end
    for _, unit_number in ipairs(unit_numbers) do PidCombinatorGui.destroy(player.index, unit_number) end
end

---Close a single GUI.
---@param player_index uint
---@param unit_number uint
function PidCombinatorGui.destroy(player_index, unit_number)
    local gui_state = gui_state(player_index, unit_number)
    if not gui_state then return end
    if gui_state.frame.valid then
        gui_state.frame.destroy()
    end
    if gui_state.graph.surface.valid then
        game.delete_surface(gui_state.graph.surface)
    end
    local guis = storage.pid_guis[unit_number]
    guis[player_index] = nil
    storage.pid_guis_count = storage.pid_guis_count - 1
    if next(guis) == nil then
        storage.pid_guis[unit_number] = nil
        -- Remove data when nobody's watching
        if storage.pid and storage.pid[unit_number] then
            storage.pid[unit_number].graph_data = List.new()
        end
    end
end

---Total open GUI windows across all players and combinators. Used by
---the tick handler to gate GUI update work.
---@return integer
function PidCombinatorGui.gui_count()
    return storage.pid_guis_count or 0
end

---When a ghost is revived to a live combinator, move any players who had
---the ghost's GUI open onto the new live entity's GUI.
---@param new_live_entity LuaEntity
function PidCombinatorGui.migrate_ghost_guis(new_live_entity)
    if not storage.pid_guis then return end
    local new_unit_number = new_live_entity.unit_number
    if not new_unit_number then return end
    local new_surface_index = new_live_entity.surface.index
    local new_position_x = new_live_entity.position.x
    local new_position_y = new_live_entity.position.y

    local migrations = {}
    for ghost_unit_number, guis in pairs(storage.pid_guis) do
        if ghost_unit_number ~= new_unit_number then
            for player_index, gui in pairs(guis) do
                local ghost_origin = gui.ghost_origin
                if gui.target and gui.target.kind == "ghost" and ghost_origin
                    and ghost_origin.surface_index == new_surface_index
                    and ghost_origin.position.x == new_position_x
                    and ghost_origin.position.y == new_position_y then
                    migrations[#migrations + 1] = {
                        ghost_unit_number = ghost_unit_number,
                        player_index = player_index,
                    }
                end
            end
        end
    end

    for _, migration in ipairs(migrations) do
        PidCombinatorGui.destroy(migration.player_index, migration.ghost_unit_number)
        local player = game.get_player(migration.player_index)
        if player and player.valid then
            PidCombinatorGui.display(player, SettingsTarget.live(new_unit_number))
        end
    end
end

---@return integer
local function next_surface_id()
    storage.next_graph_surface_id = (storage.next_graph_surface_id or 0) + 1
    return storage.next_graph_surface_id
end

---Create the private graph-rendering surface for a GUI window.
---@return LuaSurface
local function create_surface()
    local surface_name = "graph_surface_" .. next_surface_id()
    local surface_size = { width = 1, height = 1, }

    local surface = game.create_surface(surface_name, surface_size)

    for _, force in pairs(game.forces) do
        force.set_surface_hidden(surface, not C.debug.show_surface)
    end

    surface.peaceful_mode = true
    surface.request_to_generate_chunks({0, 0}, 1)
    surface.force_generate_chunk_requests()

    local tiles = {}
    local radius = C.graph.surface_tile_radius
    for x = -radius, radius do
        for y = -radius, radius do
            table.insert(tiles, {name = "out-of-map", position = {x, y}})
        end
    end
    surface.set_tiles(tiles)
    return surface
end

---@param gui_state PidGuiState
---@param parent LuaGuiElement
---@param initial_zoom number
---@return LuaGuiElement graph_camera the camera element pointed at the graph surface
local function create_graph(gui_state, parent, initial_zoom)
    local graph_camera = parent.add{
        type = "camera",
        name = "graph_camera",
        position = { offset.x, 0 },
        surface_index = gui_state.graph.surface.index,
        zoom = initial_zoom
    }

    graph_camera.style.width = C.graph.viewport.width
    graph_camera.style.height = C.graph.viewport.height
    return graph_camera
end

---@param gui_state PidGuiState
---@param parent LuaGuiElement
---@param index integer 1-based term index (P=1, I=2, D=3)
---@param caption LocalisedString
---@param initial_zoom number
---@return LuaGuiElement
local function create_term_camera(gui_state, parent, index, caption, initial_zoom)
    local container = parent.add {
        type = "flow",
        direction = "vertical",
    }
    container.style.horizontal_align = "center"
    container.add {
        type = "label",
        caption = caption,
        style = "caption_label",
    }
    local camera_frame = container.add {
        type = "frame",
        style = "deep_frame_in_shallow_frame",
    }
    local camera = camera_frame.add {
        type = "camera",
        position = term_indicator_center(index),
        surface_index = gui_state.graph.surface.index,
        zoom = initial_zoom,
    }
    camera.style.width  = C.term_indicator.width_px
    camera.style.height = C.term_indicator.height_px
    return camera
end

---Draw a line-graph for a single PID term (P, I, or D) onto
---the private graph surface.
---@param surface LuaSurface
---@param player LuaPlayer
---@param ttl uint frames the drawing should live for
---@param center { x: number, y: number }
---@param term_value number? current signed value of the term
---@param bar_color number[]
local function draw_term_indicator(surface, player, ttl, center, term_value, bar_color)
    local inset = C.graph.px_per_tile
    local half_w = C.term_indicator.width_px * 0.5 * C.graph.px_per_tile
    local half_h = C.term_indicator.height_px * 0.5 * C.graph.px_per_tile
    local top = center.y - half_h
    local bottom = center.y + half_h
    local inner_top = top + inset
    local inner_bottom = bottom - inset

    -- Frame and background
    rendering.draw_rectangle {
        surface = surface,
        left_top     = { center.x - half_w, bottom },
        right_bottom = { center.x + half_w, top },
        filled = true,
        color = C.colors.terms.frame,
        players = { player },
        time_to_live = ttl,
    }
    rendering.draw_rectangle {
        surface = surface,
        left_top     = { center.x - half_w + inset, inner_bottom },
        right_bottom = { center.x + half_w - inset, inner_top },
        filled = true,
        color = C.colors.terms.background,
        players = { player },
        time_to_live = ttl,
    }

    -- Value bar
    local max_extent = half_w - inset
    local raw_extent = term_value * C.graph.px_per_tile
    local extent = math.max(-max_extent, math.min(max_extent, raw_extent))
    local bar_left  = math.min(center.x, center.x + extent)
    local bar_right = math.max(center.x, center.x + extent)
    rendering.draw_rectangle {
        surface = surface,
        left_top     = { bar_left,  inner_bottom },
        right_bottom = { bar_right, inner_top },
        filled = true,
        color = bar_color,
        players = { player },
        time_to_live = ttl,
    }

    -- Tick marks
    for i = 1, C.term_indicator.tick_count do
        local dx = i * C.term_indicator.tick_step_px * C.graph.px_per_tile
        for _, tick_x in ipairs({ center.x - dx, center.x + dx }) do
            rendering.draw_line {
                surface = surface,
                from = { tick_x, inner_bottom },
                to   = { tick_x, inner_top },
                color = C.colors.terms.tick,
                width = 1,
                players = { player },
                time_to_live = ttl,
            }
        end
    end

    -- Zero line
    rendering.draw_line {
        surface = surface,
        from = { center.x, bottom },
        to   = { center.x, top },
        color = C.colors.terms.zero,
        width = C.term_indicator.zero_line_width,
        players = { player },
        time_to_live = ttl,
    }
end

---Render one frame of the graph (SP/PV lines, gridlines, axis labels, and
---the PID term indicators) onto the private surface for one player.
---@param player LuaPlayer
---@param gui_state PidGuiState
---@param state PidState
---@param tick uint
---@param value PidTickResult
local function plot(player, gui_state, state, tick, value)
    local data = state and state.graph_data
    if not data then return end
    if not gui_state then return end
    local surface = gui_state.graph.surface
    if not surface or not surface.valid then return end

    local tiles_per_second = gui_state.graph.time_scale
    local tick_grid_offset = (tick % C.ticks_per_second) * C.seconds_per_tick
    -- With every added GUI reduce sample rate to protect game UPS
    local ttl = PidCombinatorGui.gui_count()

    -- Auto-scale y-axis symmetrically around 0. Grow-only.
    local visible_ticks = math.ceil(viewport_tile_width / tiles_per_second) * C.ticks_per_second
    local peak = gui_state.graph.peak or 0
    for i = data.first, data.last do
        local sample = data[i]
        if tick - sample.tick <= visible_ticks then
            local pv_magnitude = math.abs(sample.value)
            if pv_magnitude > peak then peak = pv_magnitude end
            if sample.sp then
                local sp_magnitude = math.abs(sample.sp)
                if sp_magnitude > peak then peak = sp_magnitude end
            end
        end
    end
    gui_state.graph.peak = peak

    local axis_maximum = math.max(peak, C.graph.axis_min_scale) * C.graph.axis_margin

    -- Vertical gridlines
    for i = 0, math.floor(viewport_tile_width / tiles_per_second) do
        local x = 2 * offset.x - (tick_grid_offset + i) * tiles_per_second
        if x >= 0 then
            rendering.draw_line{
                surface = surface,
                from = { x, offset.y },
                to = { x, -offset.y },
                color = C.colors.graph.gridline,
                width = 1,
                players = { player },
                time_to_live = ttl,
            }
        end
    end

    -- Snap the gridline step to 1/2/5 * 10^n so lines land on round values
    -- step adapts to axis_maximum.
    local rough_step = axis_maximum / 3
    local magnitude = 10 ^ math.floor(math.log(rough_step, 10))
    local normalized_step = rough_step / magnitude
    local grid_step
    if normalized_step < 1.5 then grid_step = magnitude
    elseif normalized_step < 3 then grid_step = 2 * magnitude
    elseif normalized_step < 7 then grid_step = 5 * magnitude
    else grid_step = 10 * magnitude
    end
    local step_count = math.floor(axis_maximum / grid_step)
    for step = -step_count, step_count do
        local grid_value = step * grid_step
        local gridline_color = (step == 0) and C.colors.graph.prominent_gridline or C.colors.graph.gridline
        local text_color = (step == 0) and C.colors.graph.prominent_gridline_label or C.colors.graph.gridline_label
        local y = map_y(grid_value, axis_maximum)
        -- Horizontal gridlines
        rendering.draw_line {
            surface = surface,
            from = { 0, y }, to = { 2 * offset.x, y },
            color = gridline_color,
            width = 1,
            players = { player },
            time_to_live = ttl,
        }

        -- Horizontal gridlines text
        rendering.draw_text {
            text = grid_value,
            surface = surface,
            target = { 2 * offset.x - C.graph.label_right_padding, y },
            color = text_color,
            font = "default-semibold",
            scale = 1.0,
            alignment = "right",
            players = { player },
            time_to_live = ttl,
        }
    end

    -- Tuning taget
    if PidTuning.is_running(state.tuner) then
        rendering.draw_line {
            surface = surface,
            from = { 0, map_y(state.tuner.target, axis_maximum) },
            to = { 2 * offset.x, map_y(state.tuner.target, axis_maximum) },
            gap_length = 0.2,
            dash_length = 0.2,
            color = C.colors.graph.tuning_line,
            width = 1,
            players = { player },
            time_to_live = ttl,
        }
    end

    for i = data.first + 1, data.last do
        local previous_sample = data[i - 1]
        local current_sample = data[i]
        local previous_x = 2 * offset.x - (tick - previous_sample.tick) * C.seconds_per_tick * tiles_per_second
        local current_x = 2 * offset.x - (tick - current_sample.tick) * C.seconds_per_tick * tiles_per_second

        -- Setpoint line
        if not PidTuning.is_running(state.tuner) and previous_sample.sp and current_sample.sp then
            rendering.draw_line {
                surface = surface,
                from = { previous_x, map_y(previous_sample.sp, axis_maximum) },
                to = { current_x, map_y(current_sample.sp, axis_maximum) },
                color = C.colors.graph.sp_line,
                width = 1,
                players = { player },
                time_to_live = ttl,
            }
        end

        -- Process variable line
        rendering.draw_line {
            surface = surface,
            from = { previous_x, map_y(previous_sample.value, axis_maximum) },
            to = { current_x, map_y(current_sample.value, axis_maximum) },
            color = C.colors.graph.pv_line,
            width = 1,
            players = { player },
            time_to_live = ttl,
        }
    end

    -- PID term indicators.
    -- Skip when the side panel is hidden.
    local side_frame = gui_state.controls.side_frame
    if side_frame and side_frame.valid and side_frame.visible then
        for index, term in ipairs(C.terms) do
            draw_term_indicator(surface, player, ttl,
                term_indicator_center(index),
                value[term.key],
                C.colors.terms[term.key .. "_bar"])
        end
    end
end

---Re-read the stored settings and sync settings controls.
---@param unit_number uint
function PidCombinatorGui.refresh(unit_number)
    local guis = storage.pid_guis and storage.pid_guis[unit_number]
    if not guis then return end
    for _, gui in pairs(guis) do
        local target = SettingsTarget.resolve(gui.target)
        if target and target:valid() then
            local controls = gui.controls

            for _, component in ipairs({"p", "i", "d"}) do
                local views = controls["k" .. component .. "_views"]
                local value = target:get_k(component)
                if views and value then
                    if views.slider and views.slider.valid then
                        views.slider.slider_value = value
                    end
                    if views.textfield and views.textfield.valid then
                        views.textfield.text = format_gain(value)
                    end
                end
            end

            local anti_windup_limit_field = controls.anti_windup_limit_field
            if anti_windup_limit_field and anti_windup_limit_field.valid then
                anti_windup_limit_field.text = tostring(target:get_anti_windup_limit() or "")
            end

            for _, role in ipairs({"sp", "pv", "output"}) do
                local picker = controls[role .. "_picker"]
                if picker then
                    if picker.elem_button and picker.elem_button.valid then
                        picker.elem_button.elem_value = target:get_signal(role)
                    end
                    local network = target:get_network(role)
                    if network then
                        if picker.r_checkbox and picker.r_checkbox.valid then
                            picker.r_checkbox.state = network.red
                        end
                        if picker.g_checkbox and picker.g_checkbox.valid then
                            picker.g_checkbox.state = network.green
                        end
                    end
                end
            end
        end
    end
end

---Per-tick GUI update.
---@param unit_number uint
---@param state PidState
---@param tick uint
---@param value PidTickResult?
function PidCombinatorGui.on_tick(unit_number, state, tick, value)
    local guis = storage.pid_guis and storage.pid_guis[unit_number]
    if not guis then return end

    local status = PidTuning.is_running(state.tuner) and "tuning" or state.entity.status
    update_status(guis, status)
    update_value_labels(guis, value)

    local data = state.graph_data
    if not data or not value then return end

    -- Graph renders at 32px per second. 30hz sampling at 60 UPS is close enough.
    if tick % 2 == 0 then
        List.pushright(data, { tick = tick, value = value.pv, sp = value.sp })
    end
    if List.length(data) > 1 then
        -- Trim older data points
        while List.length(data) > 0 and (tick - data[data.first].tick) * C.seconds_per_tick > C.graph.data_retention_seconds do
            List.popleft(data)
        end
        -- With every added GUI reduce sample rate to protect game UPS
        local n = PidCombinatorGui.gui_count()
        if n > 0 and tick % n == 0 then
            for player_index, gui_state in pairs(guis) do
                plot(player_index, gui_state, state, tick, value)
            end
        end
    end
end

---Open or restore a combinator GUI for a player.
---@param player LuaPlayer
---@param target SettingsTarget
function PidCombinatorGui.display(player, target)
    local unit_number = target:unit_number()
    if not unit_number then return end
    storage.pid_guis = storage.pid_guis or {}
    storage.pid_guis[unit_number] = storage.pid_guis[unit_number] or {}
    local entry = storage.pid_guis[unit_number][player.index]
    if not entry then
        entry = { graph = { time_scale = 1.0 }, controls = {} }
        storage.pid_guis[unit_number][player.index] = entry
        storage.pid_guis_count = (storage.pid_guis_count or 0) + 1
    end
    local gui_state = entry
    -- Remember which data backend PidCombinatorGui GUI edits so handlers can resolve it.
    gui_state.target = target:descriptor()
    if gui_state.target.kind == "ghost" then
        local ghost_entity = target:preview_entity()
        if ghost_entity and ghost_entity.valid then
            gui_state.ghost_origin = {
                surface_index = ghost_entity.surface.index,
                position = { x = ghost_entity.position.x, y = ghost_entity.position.y },
            }
        end
    else
        gui_state.ghost_origin = nil
    end
    -- Outer invisible frame container
    local outer = player.gui.screen.add {
        type = "frame",
        name = "pid_combinator_frame_" .. player.index .. "_" .. unit_number,
        style = C.debug.show_invisible_frame and "pid_combinator_chroma_frame" or "invisible_frame",
        direction = "horizontal",
    }
    outer.auto_center = true
    gui_state.frame = outer

    local frame = outer.add {
        type = "frame",
        direction = "vertical",
    }

    local titlebar = frame.add {
        type = "flow",
        name = "titlebar",
    }
    titlebar.drag_target = outer

    titlebar.add {
        type = "label",
        style = "frame_title",
        caption = {"gui-pid-combinator.title"},
        ignored_by_interaction = true,
    }

    local filler = titlebar.add {
        type = "empty-widget",
        style = "draggable_space_header",
        ignored_by_interaction = true,
    }
    filler.style.horizontally_stretchable = true
    filler.style.height = 24
    filler.style.right_margin = 8
    filler.style.left_margin = 8

    local terms_button = titlebar.add {
        type = "sprite-button",
        name = "pid_combinator_terms_button_" .. unit_number,
        style = "frame_action_button",
        sprite = "pid-combinator-terms",
        tooltip = {"gui-pid-combinator.terms-button-tooltip"},
    }
    terms_button.style.right_margin = 4
    terms_button.toggled = false
    gui_state.controls.terms_button = terms_button

    local pin_button = titlebar.add {
        type = "sprite-button",
        name = "pid_combinator_pin_button_" .. unit_number,
        style = "frame_action_button",
        sprite = "pid-combinator-pin",
        tooltip = {"gui-pid-combinator.pin-tooltip"},
    }
    pin_button.style.right_margin = 4
    pin_button.toggled = false
    gui_state.controls.pin_button = pin_button

    -- Close button
    local close_button = titlebar.add {
        type = "sprite-button",
        name = "pid_combinator_close_button_" .. unit_number,
        style = "frame_action_button",
        sprite = "utility/close",
        tooltip = {"gui.close-instruction"},
    }
    gui_state.controls.close_button = close_button

    local contents = frame.add {
        type = "frame",
        style = "inside_shallow_frame",
        direction = "vertical",
    }

    -- local header = contents.add {
    --     type = "frame",
    --     style = "subheader_frame",
    -- }
    -- header.style.height = 36
    -- header.style.horizontally_stretchable = true
    -- header.style.bottom_margin = 8

    local initial_status
    if gui_state.target.kind == "ghost" then
        initial_status = "ghost"
    else
        local entity = target:preview_entity()
        initial_status = entity and entity.valid and entity.status or nil
        local live_state = storage.pid and storage.pid[unit_number]
        if live_state and PidTuning.is_running(live_state.tuner) then
            initial_status = "tuning"
        end
    end
    local status_visuals = C.status_visuals[initial_status] or C.status_visuals.default

    local status_flow = contents.add {
        type = "flow",
        direction = "horizontal",
        name = "status_flow",
    }
    status_flow.style.vertical_align = "center"
    status_flow.style.left_padding = 12
    status_flow.style.top_margin = 8
    status_flow.style.bottom_margin = 8
    status_flow.style.horizontal_spacing = 4

    local status_sprite = status_flow.add {
        type = "sprite",
        name = "status_sprite",
        sprite = status_visuals.sprite,
        style = "mod_updates_status_image",
    }

    local status_label = status_flow.add {
        type = "label",
        name = "status_label",
        caption = status_visuals.caption,
    }

    gui_state.controls.status_sprite = status_sprite
    gui_state.controls.status_label = status_label
    gui_state.controls.last_status = initial_status

    local section_1 = contents.add {
        type = "flow",
        direction = "horizontal",
        name = "section_1",
    }
    section_1.style.horizontal_spacing = 12
    section_1.style.padding = 12
    section_1.style.top_padding = 0
    section_1.style.bottom_padding = 0

    local graph_frame = section_1.add {
        type = "frame",
        style = "deep_frame_in_shallow_frame",
        name = "graph_frame",
    }

    graph_frame.style.width = C.graph.viewport.width
    graph_frame.style.height = C.graph.viewport.height

    gui_state.graph.surface = gui_state.graph.surface or create_surface()
    gui_state.controls.graph = create_graph(gui_state, graph_frame, player.display_scale)
    gui_state.controls.graph.tooltip = {"gui-pid-combinator.graph-tooltip"}

    local preview_frame = section_1.add {
        type = "frame",
        style = "deep_frame_in_shallow_frame",
        name = "preview_frame",
    }

    local preview = preview_frame.add {
        type = "entity-preview",
        style = "wide_entity_button",
        name = "preview",
    }

    preview.style.height = C.graph.preview.height
    preview.style.width = C.graph.preview.width
    preview.entity = target:preview_entity()

    local section_2 = contents.add {
        type = "flow",
        direction = "horizontal",
        name = "section_2",
    }

    local tabbed_pane = section_2.add {
        type = "tabbed-pane",
        name = "tabbed_pane",
    }
    tabbed_pane.style.horizontally_stretchable = true

    local tab_variables = tabbed_pane.add {
        type = "tab",
        caption = {"gui-pid-combinator.tab-variables"},
        tooltip = {"gui-pid-combinator.tab-variables-tooltip"},
    }

    local tab_tuning = tabbed_pane.add {
        type = "tab",
        caption = {"gui-pid-combinator.tab-tuning"},
        tooltip = {"gui-pid-combinator.tab-tuning-tooltip"},
    }

    local tab_variables_content = tabbed_pane.add {
        type = "flow",
        direction = "horizontal",
        name = "tab_variables_content",
    }
    tab_variables_content.style.padding = 8
    tab_variables_content.style.top_padding = 0

    local tab_tuning_content = tabbed_pane.add {
        type = "flow",
        direction = "vertical",
        name = "tab_tuning_content",
    }
    tab_tuning_content.style.padding = 8
    tab_tuning_content.style.top_padding = 0
    tab_tuning_content.style.horizontally_stretchable = true

    tabbed_pane.add_tab(tab_variables, tab_variables_content)
    tabbed_pane.add_tab(tab_tuning, tab_tuning_content)
    tabbed_pane.selected_tab_index = 1

    local tab_variables_content_left = tab_variables_content.add {
        type = "flow",
        direction = "horizontal",
        name = "tab_variables_content_left",
    }
    tab_variables_content_left.style.horizontally_stretchable = true

    tab_variables_content_left.style.horizontal_spacing = 12

    -- local tab_variables_content_right = tab_variables_content.add {
    --     type = "flow",
    --     direction = "vertical",
    --     name = "tab_variables_content_right",
    -- }
    -- tab_variables_content_right.style.horizontally_stretchable = true


    local red_network_tooltip = {"gui-network-selector.red-connected"}
    local green_network_tooltip = {"gui-network-selector.green-connected"}

    local sp_network = target:get_network("sp")
    local sp_picker = SignalPicker.new(tab_variables_content_left, {"gui-pid-combinator.setpoint"}, {
        r_checkbox_name = "sp_r_checkbox_" .. unit_number,
        g_checkbox_name = "sp_g_checkbox_" .. unit_number,
        r_state = sp_network.red,
        g_state = sp_network.green,
        r_tooltip = red_network_tooltip,
        g_tooltip = green_network_tooltip,
        title_tooltip = {"gui-pid-combinator.setpoint-tooltip"},
        choose_elem_button_name = "sp_choose_elem_button_" .. unit_number,
        signal = target:get_signal("sp"),
    })
    gui_state.controls.sp_value_label = sp_picker.value_label
    gui_state.controls.sp_picker = sp_picker

    local pv_network = target:get_network("pv")
    local pv_picker = SignalPicker.new(tab_variables_content_left, {"gui-pid-combinator.process-variable"}, {
        r_checkbox_name = "pv_r_checkbox_" .. unit_number,
        g_checkbox_name = "pv_g_checkbox_" .. unit_number,
        r_state = pv_network.red,
        g_state = pv_network.green,
        r_tooltip = red_network_tooltip,
        g_tooltip = green_network_tooltip,
        title_tooltip = {"gui-pid-combinator.process-variable-tooltip"},
        choose_elem_button_name = "pv_choose_elem_button_" .. unit_number,
        signal = target:get_signal("pv"),
    })
    gui_state.controls.pv_value_label = pv_picker.value_label
    gui_state.controls.pv_picker = pv_picker

    local tab_variables_content_filler = tab_variables_content_left.add {
        type = "empty-widget",
        ignored_by_interaction = true,
    }
    tab_variables_content_filler.style.horizontally_stretchable = true

    local output_network = target:get_network("output")
    local output_picker = SignalPicker.new(tab_variables_content_left, {"gui-pid-combinator.output"}, {
        r_checkbox_name = "output_r_checkbox_" .. unit_number,
        g_checkbox_name = "output_g_checkbox_" .. unit_number,
        r_state = output_network.red,
        g_state = output_network.green,
        r_tooltip = red_network_tooltip,
        g_tooltip = green_network_tooltip,
        choose_elem_button_name = "output_choose_elem_button_" .. unit_number,
        signal = target:get_signal("output"),
    })
    gui_state.controls.output_value_label = output_picker.value_label
    gui_state.controls.output_picker = output_picker

    local tuning_table = tab_tuning_content.add {
        type = "table",
        column_count = 2,
        vertical_centering = true,
    }
    tuning_table.style.horizontally_stretchable = true
    tuning_table.style.right_cell_padding = 8
    ---@diagnostic disable: assign-type-mismatch
    tuning_table.style.column_alignments[1] = "left"
    tuning_table.style.column_alignments[2] = "right"
    ---@diagnostic enable: assign-type-mismatch

    -- Proportional
    InfoLabel.new(tuning_table,
        {"gui-pid-combinator.gain-proportional"},
        {"gui-pid-combinator.gain-proportional-tooltip"})

    gui_state.controls.kp_views = ValueSlider.new(tuning_table, {
        slider = {
            name = "pid_combinator_kp_slider_" .. unit_number,
            minimum_value = 0.0,
            maximum_value = 5,
            value = target:get_k("p") or 0,
            value_step = 0.05,
        },
        textfield = {
            name = "pid_combinator_kp_textfield_" .. unit_number,
        },
    })
    gui_state.controls.kp_views.textfield.text = format_gain(target:get_k("p"))

    -- Integral
    InfoLabel.new(tuning_table,
        {"gui-pid-combinator.gain-integral"},
        {"gui-pid-combinator.gain-integral-tooltip"})

    gui_state.controls.ki_views = ValueSlider.new(tuning_table, {
        slider = {
            name = "pid_combinator_ki_slider_" .. unit_number,
            minimum_value = 0.0,
            maximum_value = 5,
            value = target:get_k("i") or 0,
            value_step = 0.05,
        },
        textfield = {
            name = "pid_combinator_ki_textfield_" .. unit_number,
        },
    })
    gui_state.controls.ki_views.textfield.text = format_gain(target:get_k("i"))

    -- Derivative

    InfoLabel.new(tuning_table,
        {"gui-pid-combinator.gain-derivative"},
        {"gui-pid-combinator.gain-derivative-tooltip"})

    gui_state.controls.kd_views = ValueSlider.new(tuning_table, {
        slider = {
            name = "pid_combinator_kd_slider_" .. unit_number,
            minimum_value = 0.0,
            maximum_value = 5,
            value = target:get_k("d") or 0,
            value_step = 0.05,
        },
        textfield = {
            name = "pid_combinator_kd_textfield_" .. unit_number,
        },
    })
    gui_state.controls.kd_views.textfield.text = format_gain(target:get_k("d"))

    -- Anti-windup limit
    InfoLabel.new(tuning_table, {"gui-pid-combinator.anti-windup-limit"}, {"gui-pid-combinator.anti-windup-limit-tooltip"})

    local anti_windup_limit_field = tuning_table.add {
        type = "textfield",
        name = "pid_combinator_anti_windup_limit_textfield_" .. unit_number,
        text = tostring(target:get_anti_windup_limit()),
        numeric = true,
        allow_decimal = false,
        allow_negative = false,
        tooltip = {"gui-pid-combinator.anti-windup-limit-tooltip"},
    }
    anti_windup_limit_field.style.width = 80
    anti_windup_limit_field.style.horizontal_align = "center"
    gui_state.controls.anti_windup_limit_field = anti_windup_limit_field

    InfoLabel.new(tuning_table,
        {"gui-pid-combinator.autotune-target"},
        {"gui-pid-combinator.autotune-target-tooltip"})

    local auto_tune_textfield = tuning_table.add {
        type = "textfield",
        name = "pid_combinator_autotune_target_textfield_" .. unit_number,
        text = "80",
        numeric = true,
        allow_decimal = true,
        tooltip = {"gui-pid-combinator.autotune-target-tooltip"},
    }
    auto_tune_textfield.style.horizontal_align = "center"

    local rule_items = {}

    for _, item in ipairs(C.pid.rules) do
        table.insert(rule_items, item.name)
    end

    InfoLabel.new(tuning_table,
        {"gui-pid-combinator.autotune-rule"},
        {"gui-pid-combinator.autotune-rule-tooltip"})

    local auto_tune_dropdown = tuning_table.add {
        type = "drop-down",
        name = "pid_combinator_auto_tune_rule_dropdown_" .. unit_number,
        items = rule_items,
        selected_index = 1,
        tooltip = {"gui-pid-combinator.autotune-rule-tooltip"},
    }
    gui_state.controls.dropdown = auto_tune_dropdown
    auto_tune_textfield.style.width = 80
    gui_state.controls.auto_tune_textfield = auto_tune_textfield

    InfoLabel.new(tuning_table,
        {"gui-pid-combinator.autotune-bipolar"},
        {"gui-pid-combinator.autotune-bipolar-tooltip"})

    local bipolar_checkbox = tuning_table.add {
        type = "checkbox",
        name = "pid_combinator_autotune_bipolar_checkbox_" .. unit_number,
        state = false,
        tooltip = {"gui-pid-combinator.autotune-bipolar-tooltip"},
    }
    gui_state.controls.bipolar_checkbox = bipolar_checkbox

    -- Empty space to move tuning button to the right
    tuning_table.add {
        type = "empty-widget",
    }

    local auto_tune_button = tuning_table.add {
        type = "button",
        style = "green_button",
        caption = {"gui-pid-combinator.autotune"},
        name = "pid_combinator_auto_tune_button_" .. unit_number,
        tooltip = {"gui-pid-combinator.autotune-tooltip"},
        enabled = gui_state.target.kind ~= "ghost",
    }
    set_autotune_button(auto_tune_button, initial_status == "tuning")
    gui_state.controls.auto_tune_button = auto_tune_button

    -- Stretch left column
    for i, child in ipairs(tuning_table.children) do
        if (i - 1) % 2 == 0 then
            child.style.horizontally_stretchable = true
        end
    end

    -- PID terms side panel
    local side_frame = outer.add {
        type = "frame",
        direction = "vertical",
    }
    side_frame.visible = false

    local side_titlebar = side_frame.add {
        type = "flow",
        name = "side_titlebar",
    }
    side_titlebar.drag_target = outer
    side_titlebar.add {
        type = "label",
        style = "frame_title",
        caption = {"gui-pid-combinator.term-panel-title"},
        ignored_by_interaction = true,
    }
    local side_filler = side_titlebar.add {
        type = "empty-widget",
        style = "draggable_space_header",
        ignored_by_interaction = true,
    }
    side_filler.style.horizontally_stretchable = true
    side_filler.style.height = 24
    side_filler.style.right_margin = 0
    side_filler.style.left_margin = 8

    local side_contents = side_frame.add {
        type = "frame",
        style = "inside_shallow_frame",
        direction = "vertical",
    }
    side_contents.style.padding = 8

    for index, term in ipairs(C.terms) do
        gui_state.controls[term.key .. "_camera"] =
            create_term_camera(gui_state, side_contents, index, term.caption, player.display_scale)
    end
    gui_state.controls.side_frame = side_frame

    player.opened = outer
end

script.on_event(defines.events.on_gui_value_changed, function(event)
    local match_component, matched_unit = event.element.name:match("^pid_combinator_k([a-z])_slider_([0-9]+)")
    local unit_number = tonumber(matched_unit)
    if not unit_number then return end

    local gui_state = gui_state(event.player_index, unit_number)
    if not gui_state or not gui_state.target then return end
    local target = SettingsTarget.resolve(gui_state.target)
    if not target or not target:valid() then return end

    local value = event.element.slider_value
    local string_value = format_gain(value)

    target:set_k(match_component, value)
    local views_key = "k" .. match_component .. "_views"
    local own_views = gui_state.controls[views_key]
    if own_views and own_views.textfield and own_views.textfield.valid then
        own_views.textfield.text = string_value
    end
    broadcast(unit_number, event.player_index, function(controls)
        local views = controls[views_key]
        if not views then return end
        if views.slider and views.slider.valid then views.slider.slider_value = value end
        if views.textfield and views.textfield.valid then views.textfield.text = string_value end
    end)
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
    local unit_number = tonumber(event.element.name:match("^pid_combinator_anti_windup_limit_textfield_(%d+)$"))
    if unit_number then
        local gui_state = gui_state(event.player_index, unit_number)
        if not gui_state or not gui_state.target then return end
        local target = SettingsTarget.resolve(gui_state.target)
        if not target or not target:valid() then return end
        local value = tonumber(event.element.text)
        if value then
            target:set_anti_windup_limit(value)
            local text = event.element.text
            broadcast(unit_number, event.player_index, function(controls)
                local field = controls.anti_windup_limit_field
                if field and field.valid then field.text = text end
            end)
        end
        return
    end

    local match_component, matched_unit = event.element.name:match("^pid_combinator_k([a-z])_textfield_([0-9]+)")
    unit_number = tonumber(matched_unit)
    if not unit_number then return end

    local gui_state = gui_state(event.player_index, unit_number)
    local value = tonumber(event.element.text)
    if not gui_state or not gui_state.target or not value then return end
    local target = SettingsTarget.resolve(gui_state.target)
    if not target or not target:valid() then return end

    target:set_k(match_component, value)
    local views_key = "k" .. match_component .. "_views"
    local own_views = gui_state.controls[views_key]
    if own_views and own_views.slider and own_views.slider.valid then
        own_views.slider.slider_value = value
    end
    local string_value = event.element.text
    broadcast(unit_number, event.player_index, function(controls)
        local views = controls[views_key]
        if not views then return end
        if views.slider and views.slider.valid then views.slider.slider_value = value end
        if views.textfield and views.textfield.valid then views.textfield.text = string_value end
    end)
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
    local match_component, matched_unit = event.element.name:match("^([a-z]+)_choose_elem_button_([0-9]+)")
    local unit_number = tonumber(matched_unit)
    if not unit_number then return end

    local gui_state = gui_state(event.player_index, unit_number)
    if not gui_state or not gui_state.target then return end
    local target = SettingsTarget.resolve(gui_state.target)
    if not target or not target:valid() then return end

    local value = event.element.elem_value
    target:set_signal(match_component, value)
    local picker_key = match_component .. "_picker"
    broadcast(unit_number, event.player_index, function(controls)
        local picker = controls[picker_key]
        if picker and picker.elem_button and picker.elem_button.valid then
            picker.elem_button.elem_value = value
        end
    end)
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
    local match_component, matched_wire_type, matched_unit = event.element.name:match("^([a-z]+)_(.)_checkbox_([0-9]+)")
    local unit_number = tonumber(matched_unit)
    if not unit_number then return end

    local gui_state = gui_state(event.player_index, unit_number)
    if not gui_state or not gui_state.target then return end
    local target = SettingsTarget.resolve(gui_state.target)
    if not target or not target:valid() then return end

    local value = event.element.state
    local wire_type = matched_wire_type == "r" and "red" or "green"

    target:set_network(match_component, wire_type, value)

    local picker_key = match_component .. "_picker"
    local checkbox_key = matched_wire_type == "r" and "r_checkbox" or "g_checkbox"
    broadcast(unit_number, event.player_index, function(controls)
        local picker = controls[picker_key]
        if picker and picker[checkbox_key] and picker[checkbox_key].valid then
            picker[checkbox_key].state = value
        end
    end)

    -- Output is handled differently.
    -- We control it by disconnecting output constant combinator from PID combinator outputs.
    if match_component == 'output' then
        target:queue_output_connection_change(wire_type, value)
    end
end)

script.on_event(defines.events.on_gui_click, function(event)
    local unit_number = tonumber(event.element.name:match("^pid_combinator_terms_button_(%d+)$"))
    if unit_number then
        local gui_state = gui_state(event.player_index, unit_number)
        if not gui_state then return end
        local side_frame = gui_state.controls.side_frame
        if not (side_frame and side_frame.valid) then return end
        side_frame.visible = not side_frame.visible
        event.element.toggled = side_frame.visible
        return
    end

    unit_number = tonumber(event.element.name:match("^pid_combinator_pin_button_(%d+)$"))
    if unit_number then
        local gui_state = gui_state(event.player_index, unit_number)
        if not gui_state then return end
        local player = game.get_player(event.player_index)
        if not player then return end
        event.element.toggled = not event.element.toggled
        event.element.sprite = event.element.toggled and "pid-combinator-pin-toggled" or "pid-combinator-pin"
        local close_button = gui_state.controls.close_button
        if close_button and close_button.valid then
            close_button.tooltip = event.element.toggled and {"gui.close"} or {"gui.close-instruction"}
        end
        if event.element.toggled then
            if player.opened == gui_state.frame then
                player.opened = nil
            end
        else
            if gui_state.frame and gui_state.frame.valid then
                player.opened = gui_state.frame
            end
        end
        return
    end

    unit_number = tonumber(event.element.name:match("^pid_combinator_auto_tune_button_(%d+)$"))
    if unit_number then
        local state = storage.pid and storage.pid[unit_number]
        local gui_state = gui_state(event.player_index, unit_number)
        if state and gui_state and gui_state.target.kind ~= "ghost" then
            if PidTuning.is_running(state.tuner) then
                PidTuning.abort(state.tuner)
            else
                local rule = C.pid.rules[gui_state.controls.dropdown.selected_index]
                local target = tonumber(gui_state.controls.auto_tune_textfield.text)
                local bipolar = gui_state.controls.bipolar_checkbox
                    and gui_state.controls.bipolar_checkbox.valid
                    and gui_state.controls.bipolar_checkbox.state
                state.tuner = PidTuning.new({
                    target = target,
                    rule = rule,
                    bipolar = bipolar,
                })
            end
        end
        return
    end

    unit_number = tonumber(event.element.name:match("^pid_combinator_close_button_(%d+)$"))
    if not unit_number then return end
    PidCombinatorGui.destroy(event.player_index, unit_number)
end)

script.on_event(defines.events.on_gui_closed, function(event)
    if not event.element or not event.element.valid then return end
    local unit_number = tonumber(event.element.name:match("^pid_combinator_frame_%d+_(%d+)$"))
    if not unit_number then return end
    local gui_state = gui_state(event.player_index, unit_number)
    if not gui_state then return end
    local pin_button = gui_state.controls.pin_button
    if pin_button and pin_button.valid and pin_button.toggled then
        return
    end
    PidCombinatorGui.destroy(event.player_index, unit_number)
end)

script.on_event(defines.events.on_player_display_scale_changed, function (event)
    local player = game.get_player(event.player_index)
    if not player then return end
    if not storage.pid_guis then return end

    for _, guis in pairs(storage.pid_guis) do
        local gui_state = guis[player.index]
        if gui_state then
            local cameras = { gui_state.controls.graph }
            for _, term in ipairs(C.terms) do
                cameras[#cameras + 1] = gui_state.controls[term.key .. "_camera"]
            end
            for _, camera in pairs(cameras) do
                if camera and camera.valid then
                    camera.zoom = player.display_scale
                end
            end
        end
    end
end)

return PidCombinatorGui
