
local remnants = table.deepcopy(data.raw["corpse"]["arithmetic-combinator-remnants"])
remnants.name = "pid-combinator-remnants"
remnants.icon = "__pid-combinator__/graphics/icons/pid-combinator.png"

data:extend({ remnants })
