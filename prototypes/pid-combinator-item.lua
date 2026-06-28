local item = table.deepcopy(data.raw["item"]["arithmetic-combinator"])
item.name = "pid-combinator"
item.place_result = "pid-combinator"
item.icon = "__pid-combinator__/graphics/icons/pid-combinator.png"
item.order = "c[combinators]-e[pid-combinator]"


local recipe = {
    type = "recipe",
    name = "pid-combinator",
    subgroup = "circuit-network",
    enabled = false,
    ingredients = {
        {type = "item", name="arithmetic-combinator", amount = 3},
        {type = "item", name = "electronic-circuit", amount = 5},
    },
    results = {{type="item", name="pid-combinator", amount=1}},
}

data:extend({item, recipe})
