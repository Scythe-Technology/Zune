local inner_foo = require("@inner_foo")
local inner_kool = require("@inner")
assert(inner_foo == "inner file foo")
assert(inner_kool == "inner file kool")
return "The bar exam"
