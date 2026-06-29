local this = {}

function this.new(parent, title, config)
    local container = parent.add {
        type = "flow",
        direction = "horizontal",
    }
    container.style.horizontal_spacing = 12
    container.style.vertical_align = "center"

    local label = container.add {
        type = "label",
        caption = title,
        style = "bold_label",
    }
    label.style.width = 16

    config.slider.type = "slider"
    local slider = container.add(config.slider)

    local textfield = container.add {
        type = "textfield",
        name = config.textfield.name,
        text = config.slider.value,
        numeric = true,
        allow_decimal = true,
    }
    textfield.style.width = 48
    textfield.style.horizontal_align = "center"
    return { textfield = textfield, slider = slider }
end

return this
