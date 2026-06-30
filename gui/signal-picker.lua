
local SignalPicker = {}

function SignalPicker.new(parent, title, config)
    local signal_outer_container = parent.add {
        type = "flow",
        direction = "vertical",
    }

    signal_outer_container.add {
        type = "label",
        caption = title,
        tooltip = config.title_tooltip,
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
        name = config.r_checkbox_name,
        state = config.r_state,
        tooltip = config.r_tooltip,
    }

    signal_table.add {
        type = "label",
        caption = {"gui-network-selector.red-label"},
        style = "grey_label",
    }

    signal_table.add {
        type = "checkbox",
        name = config.g_checkbox_name,
        state = config.g_state,
        tooltip = config.g_tooltip,
    }

    signal_table.add {
        type = "label",
        caption = {"gui-network-selector.green-label"},
        style = "grey_label",
    }

    local elem_container = signal_container.add {
        type = "flow",
        direction = "vertical",
    }
    elem_container.style.width = 40
    elem_container.style.height = 40

    elem_container.add {
        type = "choose-elem-button",
        name = config.choose_elem_button_name,
        elem_type = "signal",
        signal = config.signal,
    }

    local overlay = elem_container.add {
        type = "flow",
        direction = "vertical",
    }
    overlay.style.top_margin = -40
    overlay.style.width = 40
    overlay.style.height = 40
    overlay.style.horizontal_align = "right"
    overlay.style.vertical_align = "bottom"
    overlay.style.right_padding = 2
    overlay.style.bottom_padding = 2
    overlay.ignored_by_interaction = true

    local value_label = overlay.add {
        type = "label",
        caption = "",
        style = "count_label",
    }

    return { value_label = value_label }
end

return SignalPicker
