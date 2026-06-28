
local this = {}

function this.new(parent, title, config)
    local signal_outer_container = parent.add {
        type = "flow",
        direction = "vertical",
    }

    signal_outer_container.add {
        type = "label",
        caption = title,
        style = "bold_label",
    }

    local signal_container = signal_outer_container.add {
        type = "flow",
        direction = "horizontal",
    }
    signal_container.style.horizontal_spacing = 8

    local signal_table = signal_container.add {
        type = "table",
        column_count = 2,
        vertical_centering = true,
    }
    signal_table.style.cell_padding = 0
    signal_table.style.horizontal_spacing = 8
    signal_table.style.vertical_spacing = 0

    signal_table.add {
        type = "checkbox",
        state = config.r_state or true,
    }

    signal_table.add {
        type = "label",
        name = config.r_checkbox_name,
        caption = "R",
        style = "grey_label",
    }

    signal_table.add {
        type = "checkbox",
        state = config.g_state or true,
    }

    signal_table.add {
        type = "label",
        name = config.g_checkbox_name,
        caption = "G",
        style = "grey_label",
    }

    signal_container.add {
        type = "choose-elem-button",
        name = config.choose_elem_button_name,
        elem_type = "signal",
        elem_value = "signal",
        signal = config.signal,
    }
end

return this
