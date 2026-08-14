-- System monitor sampler service.
--
-- Runs at a configurable interval (default 2s). One POSIX shell pipeline reads
-- /proc for every process (cpu ticks, rss pages, write_bytes), `ss -ntinp`
-- yields per-process TCP byte counters, and a grep+awk pass over drm fdinfo
-- sums per-process GPU VRAM/GTT. Deltas between samples produce cpu%,
-- memory% and write/network rates, published to noctalia.state as five sorted
-- lists: procs.cpu / procs.mem / procs.gpu / procs.disk / procs.net

local TOP_N = 20

-- Line 1: page size in bytes. Line 2: MemTotal in KiB. Then TSV rows:
-- pid, comm, cpu-ticks (utime+stime), rss-pages, write_bytes.
local PROC_CMD = [[
getconf PAGESIZE
awk '/^MemTotal:/{print $2}' /proc/meminfo
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  [ -r "$d/stat" ] || continue
  IFS= read -r line < "$d/stat" || continue
  # Quoted parens: bare `*(` is an extglob error in bash, which then leaves
  # comm as the whole stat line (broken names in every process list).
  comm=${line#*"("}; comm=${comm%")"*}
  rest=${line##*)}
  set -- $rest
  ticks=$(( ${12:-0} + ${13:-0} ))
  rss=0
  # NOTE: no IFS= prefix — empty IFS disables field splitting and the whole
  # statm line lands in the first discard var, leaving rss empty (mem all 0).
  read -r _ rss _ < "$d/statm" 2>/dev/null || rss=0
  wb=0
  [ -r "$d/io" ] && wb=$(sed -n "s/^write_bytes: *//p" "$d/io" 2>/dev/null) || wb=0
  printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$comm" "$ticks" "${rss:-0}" "${wb:-0}"
done
]]
local NET_CMD = [[
ss -ntinp 2>/dev/null | awk '
/^[A-Z]/    { if ($0 !~ /^State/ && match($0, /pid=[0-9]+/)) pid=substr($0,RSTART+4,RLENGTH-4); else pid=""; next }
            { if (pid!="" && match($0, /bytes_acked:[0-9]+/)) { a=substr($0,RSTART+12,RLENGTH-12); r=0; if (match($0, /bytes_received:[0-9]+/)) r=substr($0,RSTART+15,RLENGTH-15); rx[pid]+=r; tx[pid]+=a } }
END         { for (p in rx) print p "\t" rx[p] "\t" tx[p] }
'
]]
-- Per-process GPU memory: sums drm-memory-vram/gtt KiB from kernel fdinfo
-- for every process with an amdgpu DRM fd. Several fds of one process usually
-- pin the same buffers, so identical cumulative values are counted once
-- (aggregated in the second awk). Pure shell: the Lua callback only parses a
-- few short lines, well inside the per-call CPU budget.
local GPU_CMD = [[
grep -l 'drm-driver:' /proc/[0-9]*/fdinfo/* 2>/dev/null | while read -r f; do
  [ -r "$f" ] || continue
  awk 'BEGIN{key=ARGV[1]} $1=="drm-memory-vram:"{vram+=$2; v=1} $1=="drm-memory-gtt:"{gtt+=$2} END{if(v) print key "\t" vram "\t" gtt}' "$f"
done | awk -F'\t' '
  { pid=$1; sub(/^\/proc\//,"",pid); sub(/\/.*/,"",pid)
    vk=pid SUBSEP $2; if(!(vk in vs)) { vs[vk]=1; vram[pid]+=$2 }
    gk=pid SUBSEP $3; if(!(gk in gs)) { gs[gk]=1; gtt[pid]+=$3 }
    gpu[pid]=1 }
  END { for (p in gpu) print p "\t" vram[p] "\t" gtt[p] }'
]]
local prevTicks = {}
local prevIo = {}
local prevAtMs = 0
local prevNet = {}
local prevNetAtMs = 0
local nameOf = {}

local procsCache = { cpu = {}, mem = {}, disk = {}, net = {}, gpu = {}, gpuAvailable = false }

local function take(list, n)
	local out = {}
	for i = 1, math.min(n, #list) do
		table.insert(out, list[i])
	end
	return out
end

local function publish()
	noctalia.state.set("procs", procsCache)
end

local function onProcSample(result)
	if result.exitCode ~= 0 or not result.stdout then
		noctalia.log(`[sysmon] proc sample failed: exit {tostring(result.exitCode)}`)
		return
	end

	local lines = {}
	for line in result.stdout:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end
	if #lines < 2 then
		return
	end

	local pagesize = tonumber(lines[1])
	local memtotalKb = tonumber(lines[2])
	if not pagesize or not memtotalKb or memtotalKb <= 0 then
		noctalia.log("[sysmon] bad proc sample header")
		return
	end

	local nowMs = noctalia.nowMs()
	local dt = (nowMs - prevAtMs) / 1000
	local rows = {}

	for i = 3, #lines do
		local line = lines[i]
		local pid, comm, ticks, rssPages, wb =
			line:match("([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)")
		if pid then
			local pidNum = tonumber(pid)
			local t = tonumber(ticks) or 0
			local r = tonumber(rssPages) or 0
			local w = tonumber(wb) or 0

			-- USER_HZ is 100 on Linux, so cpu% = tick-delta / dt.
			local cpuPct = 0
			local writeRate = 0
			if prevAtMs > 0 and dt > 0 then
				local pt = prevTicks[pidNum]
				if pt and t >= pt then
					cpuPct = (t - pt) / dt
				end
				local pw = prevIo[pidNum]
				if pw and w >= pw then
					writeRate = (w - pw) / dt
				end
			end

			prevTicks[pidNum] = t
			prevIo[pidNum] = w
			nameOf[pidNum] = comm

			local memPct = (r * pagesize / 1024) / memtotalKb * 100
			local memMb = (r * pagesize) / (1024 * 1024)

			table.insert(rows, {
				name = comm,
				pid = pidNum,
				cpu = cpuPct,
				mem = memPct,
				memMb = memMb,
				write = writeRate,
				down = 0,
				up = 0,
			})
		end
	end

	prevAtMs = nowMs

	local cpuList = {}
	local memList = {}
	local diskList = {}
	for _, r in ipairs(rows) do
		table.insert(cpuList, r)
		table.insert(memList, r)
		table.insert(diskList, r)
	end
	table.sort(cpuList, function(a, b)
		return a.cpu > b.cpu
	end)
	table.sort(memList, function(a, b)
		return a.mem > b.mem
	end)
	table.sort(diskList, function(a, b)
		return a.write > b.write
	end)

	procsCache.cpu = take(cpuList, TOP_N)
	procsCache.mem = take(memList, TOP_N)
	procsCache.disk = take(diskList, TOP_N)
	publish()
end

local function onNetSample(result)
	if result.exitCode ~= 0 then
		noctalia.log(`[sysmon] net sample failed: exit {tostring(result.exitCode)}`)
		return
	end
	local nowMs = noctalia.nowMs()
	local dt = (nowMs - prevNetAtMs) / 1000
	local cur = {}
	local output = result.stdout or ""
	for pid, rx, tx in output:gmatch("(%d+)%s+(%d+)%s+(%d+)") do
		local pidNum = tonumber(pid)
		cur[pidNum] = { rx = tonumber(rx), tx = tonumber(tx) }
	end
	if prevNetAtMs > 0 and dt > 0 then
		local rows = {}
		for pidNum, c in pairs(cur) do
			local prev = prevNet[pidNum]
			if prev and c.rx >= prev.rx and c.tx >= prev.tx then
				table.insert(rows, {
					name = nameOf[pidNum] or tostring(pidNum),
					pid = pidNum,
					cpu = 0,
					mem = 0,
					write = 0,
					down = (c.rx - prev.rx) / dt,
					up = (c.tx - prev.tx) / dt,
				})
			end
		end
		table.sort(rows, function(a, b)
			return (a.down + a.up) > (b.down + b.up)
		end)
		procsCache.net = take(rows, TOP_N)
		publish()
	end
	prevNet = cur
	prevNetAtMs = nowMs
end

-- (GPU rows come from the shell command above; no JSON parsing needed.)
-- gpuAvailable: true once a sample parses; on command failure it stays true
-- with the previous rows (a hiccup is not "tool missing").
local function onGpuSample(result)
	if result.exitCode ~= 0 then
		noctalia.log(`[sysmon] gpu sample failed: exit {tostring(result.exitCode)}`)
		return
	end
	-- Lines: pid\tvramKiB\tgttKiB, vram already deduped by the shell.
	local rows = {}
	for line in tostring(result.stdout):gmatch("[^\r\n]+") do
		local pid, vramKiB = line:match("^(%d+)\t(%d+)")
		if pid then
			local pidNum = tonumber(pid)
			table.insert(rows, {
				name = nameOf[pidNum] or tostring(pidNum),
				pid = pidNum,
				cpu = 0,
				mem = 0,
				memMb = 0,
				write = 0,
				down = 0,
				up = 0,
				gpu = 0,
				gpuMemMb = (tonumber(vramKiB) or 0) / 1024,
			})
		end
	end
	table.sort(rows, function(a, b)
		return a.gpuMemMb > b.gpuMemMb
	end)
	procsCache.gpuAvailable = true
	procsCache.gpu = take(rows, TOP_N)
	publish()
end

local function sample()
	noctalia.runAsync(PROC_CMD, onProcSample)
	noctalia.runAsync(NET_CMD, onNetSample)
	noctalia.runAsync(GPU_CMD, onGpuSample)
end

-- Arm the first interval, then re-arm on every update() call so the
-- configured value is picked up whenever the user changes the setting.
local function intervalMs()
	return (noctalia.getConfig("refresh_interval") or 2) * 1000
end

noctalia.setUpdateInterval(intervalMs())
sample()

function update()
	noctalia.setUpdateInterval(intervalMs())
	sample()
end
