local styles = data.raw["gui-style"].default

-- Solid-color chroma-key frame for recording.
styles["pid_combinator_chroma_frame"] = {
    type = "frame_style",
    parent = "invisible_frame",
    padding = 0,
    graphical_set = {
        base = {
            filename = "__pid-combinator__/graphics/chroma.png",
            corner_size = 1,
            position = { 0, 0 },
        },
    },
}
