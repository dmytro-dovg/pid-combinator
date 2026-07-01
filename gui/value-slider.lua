local ValueSlider = {}

function ValueSlider.new(parent, config)
    local container = parent.add {
        type = "flow",
        direction = "horizontal",
    }
    container.style.horizontal_spacing = 12
    container.style.vertical_align = "center"

    config.slider.type = "slider"
    local slider = container.add(config.slider)

    local textfield = container.add {
        type = "textfield",
        name = config.textfield.name,
        text = tostring(config.slider.value),
        numeric = true,
        allow_decimal = true,
    }
    textfield.style.width = 48
    textfield.style.horizontal_align = "center"
    return { textfield = textfield, slider = slider }
end

return ValueSlider
