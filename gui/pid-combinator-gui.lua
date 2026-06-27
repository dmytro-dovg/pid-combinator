
local List = require "utils.list"

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

function this.cleanup(player)
    local surface_name = "graph_surface_" .. player.index
    local surface = game.get_surface (surface_name)
    if surface then
        game.delete_surface(surface)
    end
end

function this.destroy(player)
    player.gui.screen["pid-combinator-frame"].destroy()
    rendering.clear("pid-combinator")
    for _, state in pairs(storage.pid) do
        state.graph_data_points = List.new()
    end
end

local function create_graph(player, parent)
    local surface_name = "graph_surface_" .. player.index
    local surface_size = { width = 1, height = 1, }
    local surface = game.get_surface (surface_name) or game.create_surface(surface_name, surface_size)
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

    local graph_camera = parent.add{
        type = "camera",
        name = "graph_camera",
        position = { offset.x, 0 },
        surface_index = surface.index,
        zoom = 1.0
    }
    graph_camera.style.width = consts.viewport.width
    graph_camera.style.height = consts.viewport.height
    return graph_camera
end

function this.build_frame(player, entity)
    this.unit_number = entity.unit_number
    local frame = player.gui.screen.add {
        type = "frame",
        name = "pid-combinator-frame",
        direction = "vertical",
    }

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
        name = "close_button",
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

    local graph = create_graph(player, graph_frame)

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
    preview.entity = entity

    local section_2 = contents.add {
        type = "flow",
        direction = "horizontal",
        name = "section_2",
    }

    local slider = section_2.add {
        type = "slider",
        name = "time_scale_slider_" .. entity.unit_number,
        minimum_value = 0.4,
        maximum_value = 5,
        value = 1,
        value_step = 0.1,
        discrete_values = true,
    }
end

function this.plot(player, point, state, tick)

    local surface_name = "graph_surface_" .. player.index
    local surface = game.get_surface (surface_name)
    if not surface then return end

    if state.entity.unit_number ~= this.unit_number then 
        debugp("Expected " .. this.unit_number .. " got " .. state.entity.unit_number)
        return
    end

    local data = state.graph_data_points
    List.pushright(data, point)
    if List.length(data) < 2 then return end

    rendering.clear("pid-combinator")
    local tiles_per_second = state.graph_time_scale
    local ticks_per_second = 60
    local scale = 50
    local tick_grid_offset = (tick % ticks_per_second) / ticks_per_second

    while List.length(data) > size_tiles.width / tiles_per_second * ticks_per_second do
        List.popleft(data)
    end

    for i=0, math.floor(size_tiles.width / tiles_per_second) do
        rendering.draw_line{
            surface = surface,
            from = { 2 * offset.x - (tick_grid_offset + i) * tiles_per_second, offset.y}, to = { 2 * offset.x - (tick_grid_offset + i) * tiles_per_second, -offset.y},
            color = {r=0.1, g=0.1, b=0.1, a=1},
            width = 1,
            players = { player },
        }
    end

    for i=0, math.floor(size_tiles.height) do
        rendering.draw_line{
            surface = surface,
            from = { 0, -offset.y + i}, to = { 2 * offset.x, -offset.y + i},
            color = {r=0.1, g=0.1, b=0.1, a=1},
            width = 1,
            players = { player },
        }
    end

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
        }
    end
end

script.on_event(defines.events.on_gui_value_changed, function(event)
    if not string.find(event.element.name, "^time_scale_slider") then return end
    debugp("Slider " .. event.element.slider_value)
    local unit_number = tonumber(string.sub(event.element.name, 19))
    local pid_state = storage.pid[unit_number]
    pid_state.graph_time_scale = event.element.slider_value
end)

script.on_event(defines.events.on_gui_click, function(event)
  if event.element.name == "close_button" then
    local player = game.get_player(event.player_index)
    this.destroy(player)
  end
end)

return this
