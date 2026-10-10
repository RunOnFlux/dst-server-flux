-- A modinfo.lua shaped like real ones (Combined Status, Global Positions): locale-dependent
-- strings, a local helper, and configuration_options.
local function en_zh(en, zh) return (locale == "zh" or locale == "zht") and zh or en end
name = en_zh("Test Mod", "测试")
description = "A mod for the tests, in " .. folder_name
author = "flux"
version = "1.2.3"
api_version_dst = 10
dst_compatible = true
client_only_mod = false
all_clients_require_mod = true
configuration_options = {
  {
    name = "SHOW",
    label = "Show it",
    hover = "Whether to show it.",
    options = { { description = "Show", data = true }, { description = "Hide", data = false } },
    default = true,
  },
}
