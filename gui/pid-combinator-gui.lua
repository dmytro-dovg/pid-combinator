local this = {}
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

local function gui_state(player_index, unit_number)
    if not storage.pid_guis or not storage.pid_guis[player_index] or not storage.pid_guis[player_index][unit_number] then
        return
    end
    return storage.pid_guis[player_index][unit_number]
end

function this.cleanup(player)
    if not storage.pid_guis or not storage.pid_guis[player.index] then return end
    local unit_numbers = {}
    for unit_number, _ in pairs(storage.pid_guis[player.index]) do unit_numbers[#unit_numbers + 1] = unit_number end
    for _, unit_number in ipairs(unit_numbers) do this.destroy(player.index, unit_number) end
    storage.pid_guis[player.index] = nil
end

function this.destroy(player_index, unit_number)
    local gui_state = gui_state(player_index, unit_number)
    if not gui_state then return end
    if gui_state.frame.valid then
        gui_state.frame.destroy()
    end
    if gui_state.graph.surface.valid then
        game.delete_surface(gui_state.graph.surface)
    end
    storage.pid_guis[player_index][unit_number] = nil
    storage.pid_guis_count = storage.pid_guis_count -1
end

function this.gui_count()
    return storage.pid_guis_count or 0
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

local function create_graph(gui_state, parent)
    local graph_camera = parent.add{
        type = "camera",
        name = "graph_camera",
        position = { offset.x, 0 },
        surface_index = gui_state.graph.surface.index,
        zoom = 1.0
    }

    graph_camera.style.width = consts.viewport.width
    graph_camera.style.height = consts.viewport.height
    return graph_camera
end

function this.display(player, state)
    storage.pid_guis = storage.pid_guis or {}
    storage.pid_guis[player.index] = storage.pid_guis[player.index] or {}
    local entry = storage.pid_guis[player.index][state.entity.unit_number]
    if not entry then
        entry = { graph = { time_scale = 1.0 }, controls = {} }
        storage.pid_guis[player.index][state.entity.unit_number] = entry
        storage.pid_guis_count = (storage.pid_guis_count or 0) + 1
    end
    local gui_state = storage.pid_guis[player.index][state.entity.unit_number]
    local frame = player.gui.screen.add {
        type = "frame",
        name = "pid_combinator_frame_" .. player.index .. "_" .. state.entity.unit_number,
        direction = "vertical",
    }
    gui_state.frame = frame

    local titlebar = frame.add {
        type = "flow",
        name = "titlebar",
    }
    titlebar.drag_target = frame

    titlebar.add {
        type = "label",
        style = "frame_title",
        caption = "PID Combinator",
        ignored_by_interaction = true,
    }

    local filler = titlebar.add {
        type = "empty-widget",
        style = "draggable_space_header",
        ignored_by_interaction = true,
    }
    filler.style.horizontally_stretchable = true
    filler.style.height = 24
    filler.style.right_margin = 4

    -- Close button
    titlebar.add {
        type = "sprite-button",
        name = "pid_combinator_close_button_" .. state.entity.unit_number,
        style = "frame_action_button",
        sprite = "utility/close",
        clicked_sprite = "utility/close_black",
        tooltip = "Close",
    }

    local contents = frame.add {
        type = "frame",
        style = "inside_shallow_frame",
        direction = "vertical",
    }
    contents.style.height = 300

    local header = contents.add {
        type = "frame",
        style = "subheader_frame",
    }
    header.style.height = 32
    header.style.horizontally_stretchable = true
    header.style.bottom_margin = 24


    local section_1 = contents.add {
        type = "flow",
        direction = "horizontal",
        name = "section_1",
    }
    section_1.style.horizontal_spacing = 8
    section_1.style.padding = 8

    local graph_frame = section_1.add {
        type = "frame",
        style = "deep_frame_in_shallow_frame",
        name = "graph_frame",
    }

    graph_frame.style.width = consts.viewport.width
    graph_frame.style.height = consts.viewport.height

    gui_state.graph.surface = gui_state.graph.surface or create_surface()
    local graph = create_graph(gui_state, graph_frame)

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
    preview.entity = state.entity

    local section_2 = contents.add {
        type = "flow",
        direction = "horizontal",
        name = "section_2",
    }

    local slider = section_2.add {
        type = "slider",
        name = "pid_combinator_time_scale_slider_" .. state.entity.unit_number,
        minimum_value = 0.4,
        maximum_value = 5,
        value = 1,
        value_step = 0.1,
        discrete_values = true,
    }

    gui_state.controls.time_scale_slider = slider
end

function this.plot(player, gui_state, state, tick)
    if not gui_state then return end
    local surface = gui_state.graph.surface
    if not surface then return end

    local tiles_per_second = gui_state.graph.time_scale
    local ticks_per_second = 60
    local scale = 50
    local tick_grid_offset = (tick % ticks_per_second) / ticks_per_second
    -- With every added GUI reduce sample rate to protect game UPS
    local ttl = this.gui_count()
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

    local data = state.graph_data_points

    for i=data.first + 1,data.last do
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

script.on_event(defines.events.on_gui_value_changed, function(event)
    local matched_unit = tonumber(event.element.name:match("^pid_combinator_time_scale_slider_(%d+)$"))
    if not matched_unit then return end
    local per_player = storage.pid_guis and storage.pid_guis[event.player_index]
    local gui_state = per_player and per_player[matched_unit]
    if not gui_state then return end
    gui_state.graph.time_scale = event.element.slider_value
end)

script.on_event(defines.events.on_gui_click, function(event)
    local matched_unit = tonumber(event.element.name:match("^pid_combinator_close_button_(%d+)$"))
    if not matched_unit then return end
    this.destroy(event.player_index, matched_unit)
end)

return this
