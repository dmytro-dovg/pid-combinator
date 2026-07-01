local List = require "utils.list"
local SignalPicker = require "gui.signal-picker"
local ValueSlider = require "gui.value-slider"
local SettingsTarget = require "gui.settings-target"

local PidCombinatorGui = {}
local function debugp(msg)
    localised_print("[PID CONTROLLER GUI]: " .. msg)
end

local consts = {
    tile_size = 32,
    viewport = {
        width = 300,
        height = 200,
    },
    preview = {
        width = 200,
        height = 200,
    },
}

local offset = { x = (consts.viewport.width / consts.tile_size) / 2, y = (consts.viewport.height / consts.tile_size) / 2 }
local size_tiles = { width = consts.viewport.width / consts.tile_size, height = consts.viewport.height / consts.tile_size }

local function status_visuals(status)
    local visuals = {
        [defines.entity_status.no_power] = { sprite = "utility/status_not_working", caption = {"entity-status.no-power"} },
        [defines.entity_status.low_power] = { sprite = "utility/status_yellow", caption = {"entity-status.low-power"} },
        ghost = { sprite = "utility/status_yellow", caption = {"entity-status.ghost"} },
        default = { sprite = "utility/status_working", caption = {"entity-status.working"} },
    }
    return visuals[status] or visuals.default
end

local function update_status(viewers, status)
    for _, gui_state in pairs(viewers) do
        if gui_state.controls.last_status ~= status then
            gui_state.controls.last_status = status
            local status_visuals = status_visuals(status)
            local sprite_element = gui_state.controls.status_sprite
            local label_element = gui_state.controls.status_label
            if sprite_element and sprite_element.valid then sprite_element.sprite = status_visuals.sprite end
            if label_element and label_element.valid then label_element.caption = status_visuals.caption end
        end
    end
end

local function format_value(n)
    if n == 0 then return "0" end
    local abs = math.abs(n)
    if abs >= 1e9 then return string.format("%.1fG", n / 1e9) end
    if abs >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if abs >= 1e4 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n))
end

local function set_caption(label, n)
    if not label or not label.valid then return end
    label.caption = n and format_value(n) or ""
end

local function update_value_labels(viewers, value)
    for _, gui_state in pairs(viewers) do
        set_caption(gui_state.controls.sp_value_label, value and value.sp)
        set_caption(gui_state.controls.pv_value_label, value and value.pv)
        set_caption(gui_state.controls.output_value_label, value and value.output)
    end
end

local function gui_state(player_index, unit_number)
    local viewers = storage.pid_guis and storage.pid_guis[unit_number]
    return viewers and viewers[player_index]
end

function PidCombinatorGui.cleanup(player)
    if not storage.pid_guis then return end
    local unit_numbers = {}
    for unit_number, viewers in pairs(storage.pid_guis) do
        if viewers[player.index] then unit_numbers[#unit_numbers + 1] = unit_number end
    end
    for _, unit_number in ipairs(unit_numbers) do PidCombinatorGui.destroy(player.index, unit_number) end
end

function PidCombinatorGui.destroy(player_index, unit_number)
    local gui_state = gui_state(player_index, unit_number)
    if not gui_state then return end
    if gui_state.frame.valid then
        gui_state.frame.destroy()
    end
    if gui_state.graph.surface.valid then
        game.delete_surface(gui_state.graph.surface)
    end
    local viewers = storage.pid_guis[unit_number]
    viewers[player_index] = nil
    storage.pid_guis_count = storage.pid_guis_count - 1
    if next(viewers) == nil then
        storage.pid_guis[unit_number] = nil
        -- Remove data when nobody's watching
        if storage.pid and storage.pid[unit_number] then
            storage.pid[unit_number].graph_data = List.new()
        end
    end
end

function PidCombinatorGui.gui_count()
    return storage.pid_guis_count or 0
end

function PidCombinatorGui.migrate_ghost_viewers(new_live_entity)
    if not storage.pid_guis then return end
    local new_unit_number = new_live_entity.unit_number
    if not new_unit_number then return end
    local new_surface_index = new_live_entity.surface.index
    local new_position_x = new_live_entity.position.x
    local new_position_y = new_live_entity.position.y

    local migrations = {}
    for ghost_unit_number, viewers in pairs(storage.pid_guis) do
        if ghost_unit_number ~= new_unit_number then
            for player_index, viewer_state in pairs(viewers) do
                local ghost_origin = viewer_state.ghost_origin
                if viewer_state.target and viewer_state.target.kind == "ghost" and ghost_origin
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

local function next_surface_id()
    storage.next_graph_surface_id = (storage.next_graph_surface_id or 0) + 1
    return storage.next_graph_surface_id
end

local function create_surface()
    local surface_name = "graph_surface_" .. next_surface_id()
    local surface_size = { width = 1, height = 1, }

    local surface = game.create_surface(surface_name, surface_size)

    for _, force in pairs(game.forces) do
        force.set_surface_hidden(surface, true)
    end

    surface.peaceful_mode = true
    surface.request_to_generate_chunks({0, 0}, 1)
    surface.force_generate_chunk_requests()

    local tiles = {}
    for x = -16, 16 do
        for y = -16, 16 do
            table.insert(tiles, {name = "out-of-map", position = {x, y}})
        end
    end
    surface.set_tiles(tiles)
    debugp("Surface created " .. surface_name)
    return surface
end

local function create_graph(gui_state, parent, initial_zoom)
    local graph_camera = parent.add{
        type = "camera",
        name = "graph_camera",
        position = { offset.x, 0 },
        surface_index = gui_state.graph.surface.index,
        zoom = initial_zoom
    }

    graph_camera.style.width = consts.viewport.width
    graph_camera.style.height = consts.viewport.height
    return graph_camera
end

local function plot(player, gui_state, data, tick)
    if not gui_state then return end
    local surface = gui_state.graph.surface
    if not surface or not surface.valid then return end

    local tiles_per_second = gui_state.graph.time_scale
    local ticks_per_second = 60
    local scale = 50
    local tick_grid_offset = (tick % ticks_per_second) / ticks_per_second
    -- With every added GUI reduce sample rate to protect game UPS
    local ttl = PidCombinatorGui.gui_count()
    for i=0, math.floor(size_tiles.width / tiles_per_second) do
        rendering.draw_line{
            surface = surface,
            from = { 2 * offset.x - (tick_grid_offset + i) * tiles_per_second, offset.y}, to = { 2 * offset.x - (tick_grid_offset + i) * tiles_per_second, -offset.y},
            color = {r=0.1, g=0.1, b=0.1, a=1},
            width = 1,
            players = { player },
            time_to_live = ttl,
        }
    end

    for i=0, math.floor(size_tiles.height) do
        rendering.draw_line{
            surface = surface,
            from = { 0, -offset.y + i}, to = { 2 * offset.x, -offset.y + i},
            color = {r=0.1, g=0.1, b=0.1, a=1},
            width = 1,
            players = { player },
            time_to_live = ttl,
        }
    end

    for i=data.first + 1, data.last do
        local p1 = data[i - 1]
        local p2 = data[i]
        local from = { 2*offset.x - (tick - p1.tick) / ticks_per_second * tiles_per_second, -p1.value / scale}
        local to = { 2*offset.x - (tick - p2.tick) / ticks_per_second * tiles_per_second, -p2.value / scale}

        rendering.draw_line {
            surface = surface,
            from = from, to = to,
            color = {r=0, g=1, b=0, a=1},
            width = 1,
            players = { player },
            time_to_live = ttl,
        }
    end
end

function PidCombinatorGui.on_tick(unit_number, status, data, tick, value)
    local viewers = storage.pid_guis and storage.pid_guis[unit_number]
    if not viewers then return end

    update_status(viewers, status)
    update_value_labels(viewers, value)

    if not data or not value then return end

    List.pushright(data, { tick = tick, value = value.pv })

    if List.length(data) > 1 then
        -- Trim older data points
        while List.length(data) > 0 and (tick - data[data.first].tick) / 60 > 25 do
            List.popleft(data)
        end
        -- With every added GUI reduce sample rate to protect game UPS
        local n = PidCombinatorGui.gui_count()
        if n > 0 and tick % n == 0 then
            for player_index, gui_state in pairs(viewers) do
                plot(player_index, gui_state, data, tick)
            end
        end
    end
end

function PidCombinatorGui.display(player, target)
    local unit_number = target:unit_number()
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
    local frame = player.gui.screen.add {
        type = "frame",
        name = "pid_combinator_frame_" .. player.index .. "_" .. unit_number,
        direction = "vertical",
    }
    gui_state.frame = frame
    frame.auto_center = true

    local titlebar = frame.add {
        type = "flow",
        name = "titlebar",
    }
    titlebar.drag_target = frame

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

    local header = contents.add {
        type = "frame",
        style = "subheader_frame",
    }
    header.style.height = 36
    header.style.horizontally_stretchable = true
    header.style.bottom_margin = 8

    local initial_status
    if gui_state.target.kind == "ghost" then
        initial_status = "ghost"
    else
        local entity = target:preview_entity()
        initial_status = entity and entity.valid and entity.status or nil
    end
    local status_viusuals = status_visuals(initial_status)

    local status_flow = contents.add {
        type = "flow",
        direction = "horizontal",
        name = "status_flow",
    }
    status_flow.style.vertical_align = "center"
    status_flow.style.left_padding = 12
    status_flow.style.bottom_padding = 8
    status_flow.style.horizontal_spacing = 4

    local status_sprite = status_flow.add {
        type = "sprite",
        name = "status_sprite",
        sprite = status_viusuals.sprite,
    }
    status_sprite.style.size = 16

    local status_label = status_flow.add {
        type = "label",
        name = "status_label",
        caption = status_viusuals.caption,
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

    graph_frame.style.width = consts.viewport.width
    graph_frame.style.height = consts.viewport.height

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

    preview.style.height = 200
    preview.style.width = 200
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

    -- local slider = tab_variables_content_left.add {
    --     type = "slider",
    --     name = "pid_combinator_time_scale_slider_" .. unit_number,
    --     minimum_value = 0.4,
    --     maximum_value = 5,
    --     value = 1,
    --     value_step = 0.1,
    --     discrete_values = false,
    -- }

    -- gui_state.controls.time_scale_slider = slider


    local tab_tuning_content_left = tab_tuning_content.add {
        type = "flow",
        direction = "vertical",
        name = "tab_tuning_content_left",
    }
    tab_tuning_content_left.style.horizontally_stretchable = true

    local tuning_table = tab_tuning_content_left.add {
        type = "table",
        column_count = 2,
        vertical_centering = true,
    }
    tuning_table.style.right_cell_padding = 8

    -- Proportional
    tuning_table.add {
        type = "label",
        caption = {"gui-pid-combinator.gain-proportional"},
        style = "bold_label",
    }

    gui_state.kp_views = ValueSlider.new(tuning_table, {
        slider = {
            name = "pid_combinator_kp_slider_" .. unit_number,
            minimum_value = 0.0,
            maximum_value = 5,
            value = target:get_k("p"),
            value_step = 0.1,
        },
        textfield = {
            name = "pid_combinator_kp_textfield_" .. unit_number,
        },
    })

    -- Integral
    tuning_table.add {
        type = "label",
        caption = {"gui-pid-combinator.gain-integral"},
        style = "bold_label",
    }

    gui_state.ki_views = ValueSlider.new(tuning_table, {
        slider = {
            name = "pid_combinator_ki_slider_" .. unit_number,
            minimum_value = 0.0,
            maximum_value = 5,
            value = target:get_k("i"),
            value_step = 0.1,
        },
        textfield = {
            name = "pid_combinator_ki_textfield_" .. unit_number,
        },
    })

    -- Derivative
    tuning_table.add {
        type = "label",
        caption = {"gui-pid-combinator.gain-derivative"},
        style = "bold_label",
    }

    gui_state.kd_views = ValueSlider.new(tuning_table, {
        slider = {
            name = "pid_combinator_kd_slider_" .. unit_number,
            minimum_value = 0.0,
            maximum_value = 5,
            value = target:get_k("d"),
            value_step = 0.1,
        },
        textfield = {
            name = "pid_combinator_kd_textfield_" .. unit_number,
        },
    })

    player.opened = frame
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
    local string_value = tostring(value)

    target:set_k(match_component, value)
    if match_component == 'p' then
        gui_state.kp_views.textfield.text = string_value
    elseif match_component == 'i' then
        gui_state.ki_views.textfield.text = string_value
    elseif match_component == 'd' then
        gui_state.kd_views.textfield.text = string_value
    end

    local matched_unit = tonumber(event.element.name:match("^pid_combinator_time_scale_slider_(%d+)$"))
    if not matched_unit then return end

    local viewers = storage.pid_guis and storage.pid_guis[matched_unit]
    local gui_state = viewers and viewers[event.player_index]

    if not gui_state then return end
    gui_state.graph.time_scale = event.element.slider_value
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
    local match_component, matched_unit = event.element.name:match("^pid_combinator_k([a-z])_textfield_([0-9]+)")
    local unit_number = tonumber(matched_unit)
    if not unit_number then return end

    local gui_state = gui_state(event.player_index, unit_number)
    local value = tonumber(event.element.text)
    if not gui_state or not gui_state.target or not value then return end
    local target = SettingsTarget.resolve(gui_state.target)
    if not target or not target:valid() then return end

    target:set_k(match_component, value)
    if match_component == 'p' then
        gui_state.kp_views.slider.slider_value = value
    elseif match_component == 'i' then
        gui_state.ki_views.slider.slider_value = value
    elseif match_component == 'd' then
        gui_state.kd_views.slider.slider_value = value
    end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
    local match_component, matched_unit = event.element.name:match("^([a-z]+)_choose_elem_button_([0-9]+)")
    local unit_number = tonumber(matched_unit)
    if not unit_number then return end

    local gui_state = gui_state(event.player_index, unit_number)
    if not gui_state or not gui_state.target then return end
    local target = SettingsTarget.resolve(gui_state.target)
    if not target or not target:valid() then return end

    target:set_signal(match_component, event.element.elem_value)
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

    -- Output is handled differently.
    -- We control it by disconnecting output constant combinator from PID combinator outputs.
    if match_component == 'output' then
        target:queue_output_connection_change(wire_type, value)
    end
end)

script.on_event(defines.events.on_gui_click, function(event)
    local pin_unit_number = tonumber(event.element.name:match("^pid_combinator_pin_button_(%d+)$"))
    if pin_unit_number then
        local viewer_state = gui_state(event.player_index, pin_unit_number)
        if not viewer_state then return end
        local player = game.get_player(event.player_index)
        if not player then return end
        event.element.toggled = not event.element.toggled
        event.element.sprite = event.element.toggled and "pid-combinator-pin-toggled" or "pid-combinator-pin"
        local close_button = viewer_state.controls.close_button
        if close_button and close_button.valid then
            close_button.tooltip = event.element.toggled and {"gui.close"} or {"gui.close-instruction"}
        end
        if event.element.toggled then
            if player.opened == viewer_state.frame then
                player.opened = nil
            end
        else
            if viewer_state.frame and viewer_state.frame.valid then
                player.opened = viewer_state.frame
            end
        end
        return
    end

    local matched_unit = tonumber(event.element.name:match("^pid_combinator_close_button_(%d+)$"))
    if not matched_unit then return end
    PidCombinatorGui.destroy(event.player_index, matched_unit)
end)

script.on_event(defines.events.on_gui_closed, function(event)
    if not event.element or not event.element.valid then return end
    local unit_number = tonumber(event.element.name:match("^pid_combinator_frame_%d+_(%d+)$"))
    if not unit_number then return end
    local viewer_state = gui_state(event.player_index, unit_number)
    if not viewer_state then return end
    local pin_button = viewer_state.controls.pin_button
    if pin_button and pin_button.valid and pin_button.toggled then
        return
    end
    PidCombinatorGui.destroy(event.player_index, unit_number)
end)

script.on_event(defines.events.on_player_display_scale_changed, function (event)
    local player = game.get_player(event.player_index)
    if not player then return end
    if not storage.pid_guis then return end

    for _, viewers in pairs(storage.pid_guis) do
        local gui_state = viewers[player.index]
        if gui_state and gui_state.controls.graph.valid then
            debugp("Setting zoom " .. player.display_scale)
            gui_state.controls.graph.zoom = player.display_scale
        end
    end
end)

return PidCombinatorGui
