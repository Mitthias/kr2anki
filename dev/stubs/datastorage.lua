local out = os.getenv("HARNESS_OUT")
return {
    getSettingsDir = function() return out .. "/settings" end,
    getDataDir = function() return out end,
    getFullDataDir = function() return out end,
}
