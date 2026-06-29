
local remnants = table.deepcopy(data.raw["corpse"]["arithmetic-combinator-remnants"])
remnants.name = "pid-combinator-remnants"
remnants.icon = "__pid-combinator__/graphics/icons/pid-combinator.png"
remnants.animation.filename = "__pid-combinator__/graphics/entity/combinator/remnants/pid/pid-combinator-remnants.png"

data:extend({ remnants })
