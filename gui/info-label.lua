local InfoLabel = {}

---A label with a bold caption and an "info" sprite that shares the tooltip.
---@param parent LuaGuiElement
---@param caption LocalisedString|string
---@param tooltip LocalisedString|string
function InfoLabel.new(parent, caption, tooltip)
    local flow = parent.add {
        type = "flow",
        direction = "horizontal",
    }
    flow.style.vertical_align = "center"
    flow.style.horizontal_spacing = 4
    flow.add {
        type = "label",
        caption = caption,
        tooltip = tooltip,
        style = "bold_label",
    }
    flow.add {
        type = "sprite",
        sprite = "info_no_border",
        tooltip = tooltip,
    }
end
return InfoLabel
