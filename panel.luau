-- Process panel: five tabs, each showing a sorted list of processes.
--
-- Tabs: CPU · Memory · GPU · Network · Disk
-- Every row: Name, PID, plus the tab-specific metric(s).
-- Uses noctalia palette tokens so the UI follows the current theme.
--
-- Refresh is driven by two mechanisms:
--   1. state.watch("procs") fires render() immediately when the service publishes
--   2. setUpdateInterval (from the refresh_interval setting) re-arms update() as backup

local currentTab = "cpu"

local TAB_GLYPHS = { cpu = "cpu", mem = "server", gpu = "device-desktop", net = "network", disk = "database" }
local TAB_LABELS = { cpu = "CPU", mem = "Memory", gpu = "GPU", net = "Network", disk = "Disk" }

local function humanBytesPerSec(b)
	if b >= 1e9 then
		return string.format("%.1f GB/s", b / 1e9)
	end
	if b >= 1e6 then
		return string.format("%.1f MB/s", b / 1e6)
	end
	if b >= 1e3 then
		return string.format("%.1f KB/s", b / 1e3)
	end
	return string.format("%.0f B/s", b)
end

-- Format raw MB as "x.x GB" or "xxx MB".
local function humanMemMb(mb)
	if mb >= 1024 then
		return string.format("%.1f GB", mb / 1024)
	end
	return string.format("%.0f MB", mb)
end

-- Format raw bytes as "x.x GB" or "xxx MB".
local function humanBytesMiB(b)
	return humanMemMb(b / (1024 * 1024))
end

-- Metric value coloring shared by every tab: primary at rest, warning from
-- 50%, error from 80% — same as the CPU tab.
local function metricColor(v)
	if v >= 80 then return "error" end
	if v >= 50 then return "warning" end
	return "primary"
end

local function render()
	local procs = noctalia.state.get("procs")
	local list = procs and procs[currentTab] or nil
	local stats = noctalia.systemStats()
	local diskStats = noctalia.diskStats("/")

	local children = {}

	-- System-wide summary: icons secondary, text primary
	if stats then
		local summaryItems = {
			ui.row({ gap = 4, align = "center" }, {
				ui.glyph({ name = "cpu", size = 14, color = "secondary" }),
				ui.label({ text = string.format("CPU %.0f%%", stats.cpu.usagePercent), fontWeight = "bold", color = "primary" }),
			}),
			ui.row({ gap = 4, align = "center" }, {
				ui.glyph({ name = "server", size = 14, color = "secondary" }),
				ui.label({
					text = string.format("RAM %s · %.0f%%", humanMemMb(stats.ram.usedMb), stats.ram.usagePercent),
					fontWeight = "bold",
					color = "primary",
				}),
			}),
		}
		local gpu = stats.gpu
		if type(gpu) == "table" and (gpu.usagePercent ~= nil or gpu.vramUsedBytes ~= nil) then
			local parts = {}
			if gpu.vramUsedBytes ~= nil then
				local vramText = humanBytesMiB(gpu.vramUsedBytes)
				if gpu.vramTotalBytes ~= nil and gpu.vramTotalBytes > 0 then
					vramText = vramText .. " / " .. humanBytesMiB(gpu.vramTotalBytes)
				end
				table.insert(parts, vramText)
			end
			if gpu.usagePercent ~= nil then
				table.insert(parts, string.format("%.0f%%", gpu.usagePercent))
			end
			table.insert(summaryItems, ui.row({ gap = 4, align = "center" }, {
				ui.glyph({ name = "device-desktop", size = 14, color = "secondary" }),
				ui.label({ text = "GPU " .. table.concat(parts, " · "), fontWeight = "bold", color = "primary" }),
			}))
		end
		if diskStats then
			table.insert(summaryItems, ui.row({ gap = 4, align = "center" }, {
				ui.glyph({ name = "database", size = 14, color = "secondary" }),
				ui.label({ text = string.format("Disk %.0f%%", diskStats.usagePercent), fontWeight = "bold", color = "primary" }),
			}))
		end
		table.insert(children, ui.row({ gap = 12, padding = 4, align = "center" }, summaryItems))
	end

	-- Tab bar
	local tabButtons = {}
	for _, id in ipairs({ "cpu", "mem", "gpu", "net", "disk" }) do
		table.insert(tabButtons, ui.button({
			key = id,
			glyph = TAB_GLYPHS[id],
			text = TAB_LABELS[id],
			variant = currentTab == id and "primary" or "ghost",
			selected = currentTab == id,
			controlSize = "sm",
			onClick = function()
				currentTab = id
				render()
			end,
		}))
	end
	table.insert(children, ui.row({ gap = 4 }, tabButtons))

	-- Column headers — metric column(s) vary by tab; all caps, secondary color
	local headerCells = {
		ui.label({ text = "NAME", flexGrow = 1, fontWeight = "bold", color = "secondary" }),
		ui.label({ text = "PID", width = 64, fontWeight = "bold", color = "secondary", textAlign = "right" }),
	}
	if currentTab == "net" then
		table.insert(headerCells, ui.label({ text = "DOWN", width = 100, fontWeight = "bold", color = "secondary", textAlign = "right" }))
		table.insert(headerCells, ui.label({ text = "UP",   width = 100, fontWeight = "bold", color = "secondary", textAlign = "right" }))
	elseif currentTab == "disk" then
		table.insert(headerCells, ui.label({ text = "WRITE", width = 100, fontWeight = "bold", color = "secondary", textAlign = "right" }))
	elseif currentTab == "mem" then
		-- Two header cells to align with the two data cells (progress + label)
		table.insert(headerCells, ui.label({ text = "",       width = 80, color = "secondary" }))
		table.insert(headerCells, ui.label({ text = "MEMORY", width = 100, fontWeight = "bold", color = "secondary", textAlign = "right" }))
	elseif currentTab == "gpu" then
		table.insert(headerCells, ui.label({ text = "",      width = 80, color = "secondary" }))
		table.insert(headerCells, ui.label({ text = "GPU",   width = 140, fontWeight = "bold", color = "secondary", textAlign = "right" }))
	else -- cpu
		table.insert(headerCells, ui.label({ text = "CPU", width = 172, fontWeight = "bold", color = "secondary", textAlign = "right" }))
	end
	table.insert(children, ui.row({ gap = 12, paddingV = 6, paddingH = 8, fill = "surface_variant/0.3" }, headerCells))

	-- Data rows
	if list and #list > 0 then
		local rowWidgets = {}
		for i, row in ipairs(list) do
			local rowFill = i % 2 == 0 and "surface_variant/0.1" or nil
			local cells = {
				ui.label({ text = row.name, flexGrow = 1, maxLines = 1 }),
				ui.label({ text = tostring(row.pid), width = 64, color = "on_surface_variant", textAlign = "right" }),
			}
			if currentTab == "net" then
				table.insert(cells, ui.label({ text = humanBytesPerSec(row.down), width = 100, color = metricColor(row.down), textAlign = "right" }))
				table.insert(cells, ui.label({ text = humanBytesPerSec(row.up),   width = 100, color = metricColor(row.up), textAlign = "right" }))
			elseif currentTab == "disk" then
				table.insert(cells, ui.label({ text = humanBytesPerSec(row.write), width = 100, color = metricColor(row.write), textAlign = "right" }))
			elseif currentTab == "mem" then
				local val = row.mem
				local col = metricColor(val)
				local mb  = row.memMb or 0
				table.insert(cells, ui.progress({ progress = math.clamp(val / 100, 0, 1), width = 80, height = 6, fill = "primary", track = "surface_variant" }))
				table.insert(cells, ui.label({
					text = string.format("%s · %.0f%%", humanMemMb(mb), val),
					width = 100,
					color = col,
					textAlign = "right",
				}))
			elseif currentTab == "gpu" then
				local gfx = row.gpu or 0
				local mb = row.gpuMemMb or 0
				local col = metricColor(gfx)
				table.insert(cells, ui.progress({ progress = math.clamp(gfx / 100, 0, 1), width = 80, height = 6, fill = "primary", track = "surface_variant" }))
				table.insert(cells, ui.label({
					text = gfx > 0 and string.format("%s · %.0f%%", humanMemMb(mb), gfx) or humanMemMb(mb),
					width = 140,
					color = col,
					textAlign = "right",
				}))
			else -- cpu
				local val = row.cpu
				local col = metricColor(val)
				table.insert(cells, ui.progress({ progress = math.clamp(val / 100, 0, 1), width = 112, height = 6, fill = "primary", track = "surface_variant" }))
				table.insert(cells, ui.label({ text = string.format("%.0f%%", val), width = 48, color = col, textAlign = "right" }))
			end
			table.insert(rowWidgets, ui.row({
				key = tostring(row.pid),
				gap = 12,
				align = "center",
				paddingV = 6,
				paddingH = 8,
				fill = rowFill,
			}, cells))
		end
		table.insert(children, ui.scroll({ flexGrow = 1 }, rowWidgets))
	else
		local msg = "No data"
		if procs == nil then
			msg = "Sampling…"
		elseif currentTab == "gpu" and procs.gpuAvailable ~= true then
			msg = procs.gpuAvailable == false and "Sampling GPU…" or "GPU — " .. tostring(procs.gpuAvailable)
		end
		table.insert(children, ui.scroll({ flexGrow = 1 }, {
			ui.label({ text = msg, color = "on_surface_variant", padding = 8 }),
		}))
	end

	-- flexGrow on the root: the panel host only stretches the tree root when
	-- it asks for it; without it the column keeps its natural (content) height
	-- and the 20-row list overflows the panel surface.
	panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 12 }, children))
end

-- React immediately whenever the service publishes fresh process data.
noctalia.state.watch("procs", function(_)
	render()
end)

local function intervalMs()
	return (noctalia.getConfig("refresh_interval") or 2) * 1000
end

function onOpen(_context)
	noctalia.setUpdateInterval(intervalMs())
	render()
end

function update()
	noctalia.setUpdateInterval(intervalMs())
	render()
end

function onClose()
	-- nothing to clean up
end
