local function gen_display(shift)
    return util.draw_as_glow({
        scale = 0.5,
        filename = "__pid-combinator__/graphics/entity/combinator/combinator-displays.png",
        x = 30,
        width = 30,
        height = 22,
        shift = shift
    })
end

local display_sprites = {
    north = gen_display(util.by_pixel(0, -4.5)),
    east = gen_display(util.by_pixel(0, -10.5)),
    south = gen_display(util.by_pixel(0, -4.5)),
    west = gen_display(util.by_pixel(0, -10.5)),
}

local sprites = make_4way_animation_from_spritesheet({ 
    layers ={
        {
            scale = 0.5,
            filename = "__pid-combinator__/graphics/entity/combinator/pid-combinator.png",
            width = 144,
            height = 124,
            shift = util.by_pixel(0.5, 7.5)
        },
        {
            scale = 0.5,
            filename = "__base__/graphics/entity/combinator/arithmetic-combinator-shadow.png",
            width = 148,
            height = 156,
            shift = util.by_pixel(13.5, 24.5),
            draw_as_shadow = true
        }
    }
})

local function copy_prototype(ptype, name, new_name)
    local copy = table.deepcopy(data.raw[ptype][name])
    copy.name = new_name

    if copy.minable and copy.minable.result then
        copy.minable.result = new_name
    end
    if copy.place_result then copy.place_result = new_name end
    return copy
end

local combinator = copy_prototype("arithmetic-combinator", "arithmetic-combinator", "pid-combinator")
combinator.icon = "__pid-combinator__/graphics/icons/pid-combinator.png"
combinator.sprites = sprites
combinator.corpse = "pid-combinator-remnants"
combinator.fast_replaceable_group = "pid-combinator"
combinator.plus_symbol_sprites = display_sprites
combinator.minus_symbol_sprites = display_sprites
combinator.multiply_symbol_sprites = display_sprites
combinator.divide_symbol_sprites = display_sprites
combinator.modulo_symbol_sprites = display_sprites
combinator.power_symbol_sprites = display_sprites
combinator.left_shift_symbol_sprites = display_sprites
combinator.right_shift_symbol_sprites = display_sprites
combinator.and_symbol_sprites = display_sprites
combinator.or_symbol_sprites = display_sprites
combinator.xor_symbol_sprites = display_sprites

local hidden_constant_combinator = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
hidden_constant_combinator.name = "pid-combinator-output"
hidden_constant_combinator.flags = {
    'hide-alt-info',
    'no-copy-paste',
    'not-blueprintable',
    'not-deconstructable',
    'not-flammable',
    'not-in-kill-statistics',
    'not-in-made-in',
    'not-on-map',
    'not-repairable',
    'not-selectable-in-game',
    'not-upgradable',
    'placeable-off-grid',
}

hidden_constant_combinator.minable = nil
hidden_constant_combinator.active_energy_usage = '0.0W'
hidden_constant_combinator.activity_led_sprites = nil
hidden_constant_combinator.collision_box = nil
hidden_constant_combinator.collision_mask = { layers = {} }
hidden_constant_combinator.draw_circuit_wires = false
hidden_constant_combinator.energy_source = { type = 'void' }
hidden_constant_combinator.hidden = true
hidden_constant_combinator.hidden_in_factoriopedia = true
hidden_constant_combinator.icon = nil
hidden_constant_combinator.selectable_in_game = false
hidden_constant_combinator.selection_box = nil
hidden_constant_combinator.sprites = nil

data:extend({ combinator })
data:extend({ hidden_constant_combinator })
