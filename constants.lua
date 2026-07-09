local C = {}

C.debug = {
    show_surface = false,
    show_invisible_frame = false,
}

C.ticks_per_second = 60

-- Drop undo/redo entries older than this.
C.undo_redo_max_age_ticks = 60 * 60 * 60 -- 1 hour

C.pid = {
    -- Low-pass filter coefficient for the derivative. Smaller - smoother.
    derivative_lpf_alpha = 0.3,
    -- Clamp tick delta so a long pause doesn't produce a huge integral jump.
    dt_clamp_seconds = 1,
    -- Factorio combinator output is int32. The game crashes on out-of-range.
    output_min = -2147483648,
    output_max = 2147483647,
}

C.graph = {
    tile_size = 32,
    viewport = { width = 300, height = 200, },
    preview  = { width = 200, height = 200, },
    -- Grow-only y-axis: never scale below this magnitude.
    axis_min_scale = 50,
    -- Headroom above the max peak.
    axis_margin = 1.1,
    -- Trim samples older than this from the graph buffer.
    data_retention_seconds = 25,
    -- Right-side inset for gridline value labels.
    label_right_padding = 0.125, -- tiles
    -- Half-side of the tile square drawn on the hidden graph surface.
    surface_tile_radius = 16,
}
C.graph.px_per_tile = 1 / C.graph.tile_size

C.term_indicator = {
    width_px = 110,
    height_px = 12,
    tick_step_px = 6,
    tick_count = 8,
    zero_line_width = 2,
    -- Gap between rendered indicators on the surface
    row_gap_px = 0,
    -- 10 to clear graph's position.
    surface_origin = { x = 0, y = 10, },
}

-- The three PID term indicators, in display order.
C.terms = {
    { key = "p", caption = {"gui-pid-combinator.term-p"}, },
    { key = "i", caption = {"gui-pid-combinator.term-i"}, },
    { key = "d", caption = {"gui-pid-combinator.term-d"}, },
}

-- Power status sprite/caption pairs shown in the combinator GUI header.
C.status_visuals = {
    [defines.entity_status.no_power]  = { sprite = "utility/status_not_working", caption = {"entity-status.no-power"} },
    [defines.entity_status.low_power] = { sprite = "utility/status_yellow",       caption = {"entity-status.low-power"} },
    ghost   = { sprite = "utility/status_yellow",  caption = {"entity-status.ghost"} },
    default = { sprite = "utility/status_working", caption = {"entity-status.working"} },
}

C.colors = {
    graph = {
        sp_line = { 0.0, 0.447, 0.698, 1.0, },
        pv_line = { 0.714, 0.835, 0.122, 1.0, },
        prominent_gridline = { 0.25, 0.25, 0.25, 1.0, },
        gridline = { 0.1, 0.1, 0.1, 1.0, },
        prominent_gridline_label = { 0.25, 0.25, 0.25, 1.0, },
        gridline_label = { 0.25, 0.25, 0.25, 1.0, },
    },
    terms = {
        p_bar = { 5, 243, 0, },
        i_bar = { 5, 243, 0, },
        d_bar = { 5, 243, 0, },
        frame = { 62, 61, 62, },
        background = { 80, 80, 80, },
        tick = { 62, 61, 62, },
        zero = { 42, 41, 42, },
    },
}

return C
