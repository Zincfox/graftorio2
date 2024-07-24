local flib_table = require("__flib__.table")

local prometheusCombinatorItem = flib_table.deep_copy(data.raw["item"]["constant-combinator"])
local prometheusCombinatorEntity = flib_table.deep_copy(data.raw["constant-combinator"]["constant-combinator"])


prometheusCombinatorItem.type = "item-with-tags"
prometheusCombinatorItem.name = "prometheus-combinator"
prometheusCombinatorItem.place_result = "prometheus-combinator"
prometheusCombinatorItem.icon = "__graftorio2__/graphics/icons/prometheus-combinator.png"

prometheusCombinatorEntity.name = "prometheus-combinator"
prometheusCombinatorEntity.minable.result = "prometheus-combinator"
prometheusCombinatorEntity.item_slot_count = 0
prometheusCombinatorEntity.allow_copy_paste = false
prometheusCombinatorEntity.sprites.sheets = {
    {
        frames = 4,
        size = { 57, 52 },
        filename = "__graftorio2__/graphics/entity/prometheus-combinator.png",
        hr_version = {
            frames = 4,
            size = { 114, 102 },
            shift = { 0, 0.125 },
            filename = "__graftorio2__/graphics/entity/hr-prometheus-combinator.png",
            scale = 0.5
        }
    },
    {
        frames = 4,
        size = { 50, 34 },
        filename = "__graftorio2__/graphics/entity/prometheus-combinator-shadow.png",
        draw_as_shadow = true,
        hr_version = {
            frames = 4,
            size = { 98, 66 },
            shift = { 0.234375, 0.109375 },
            filename = "__graftorio2__/graphics/entity/hr-prometheus-combinator-shadow.png",
            scale = 0.5,
            draw_as_shadow = true
        }
    }
}

local prometheusCombinatorRecipe = {
    type = "recipe",
    name = "prometheus-combinator",
    enabled = false,
    energy_required = 0.5,
    ingredients = { { "constant-combinator", 1 }, { "electronic-circuit", 1 } },
    result = "prometheus-combinator"
}

table.insert(data.raw["technology"]["circuit-network"].effects, { type = "unlock-recipe", recipe = "prometheus-combinator" })
data:extend { prometheusCombinatorItem, prometheusCombinatorEntity, prometheusCombinatorRecipe }
