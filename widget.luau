-- Bar widget: CPU and RAM percentages.
-- Click opens the process panel.
--
-- Declarative ui.* trees do NOT inherit the widget instance's configured
-- color/icon_color (those only reach the imperative setText/setGlyph path),
-- so the plugin declares its own color settings (plugin.toml) and applies
-- them explicitly. icon_color falls back to color, mirroring the host's own
-- `color` -> `icon_color` chain; an empty value keeps the theme default.

noctalia.setUpdateInterval(2000)

-- Widgets are rebuilt when a setting changes, so reading at load is enough.
local textColor = noctalia.getConfig("color")
local iconColor = noctalia.getConfig("icon_color")

-- A color setting is an empty string when never configured.
local function pickColor(primary, fallback)
	if type(primary) == "string" and primary ~= "" then
		return primary
	end
	return fallback
end

local labelColor = pickColor(textColor, nil)
local glyphColor = pickColor(iconColor, pickColor(textColor, nil))

function update()
	local stats = noctalia.systemStats()
	local container = barWidget.isVertical() and ui.column or ui.row

	if not stats then
		barWidget.render(container({ gap = 8, align = "center" }, {
			ui.glyph({ name = "cpu", size = 14, color = glyphColor }),
			ui.label({ text = "--", fontWeight = "bold", color = labelColor }),
			ui.glyph({ name = "server", size = 14, color = glyphColor }),
			ui.label({ text = "--", fontWeight = "bold", color = labelColor }),
		}))
		return
	end

	barWidget.render(container({ gap = 8, align = "center" }, {
		ui.glyph({ name = "cpu", size = 14, color = glyphColor }),
		ui.label({ text = string.format("%.0f%%", stats.cpu.usagePercent), fontWeight = "bold", color = labelColor }),
		ui.glyph({ name = "server", size = 14, color = glyphColor }),
		ui.label({ text = string.format("%.0f%%", stats.ram.usagePercent), fontWeight = "bold", color = labelColor }),
	}))
end

function onClick()
	noctalia.togglePanel("zerone/system-monitor:processes")
end