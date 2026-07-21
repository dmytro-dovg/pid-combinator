---@class ValueSliderConfig
---@field slider { name: string, type: string, minimum_value: number, maximum_value: number, value: number, value_step: number? }
---@field textfield { name: string }

---@class ValueSliderViews
---@field slider LuaGuiElement
---@field textfield LuaGuiElement

local ValueSlider = {}

---Adds a horizontal flow with a slider and a numeric textfield that show the
---same value. The caller is responsible for keeping the two in sync via
---`on_gui_value_changed` / `on_gui_text_changed` handlers.
---@param parent LuaGuiElement
---@param config ValueSliderConfig
---@return ValueSliderViews
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
    textfield.style.width = 80
    textfield.style.horizontal_align = "center"
    return { textfield = textfield, slider = slider }
end

return ValueSlider
