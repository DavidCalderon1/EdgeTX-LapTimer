-- toolName = "TNS|Lap Timer|TNE
-- Lap Timer V2.0.2
-- Modified by RadioMaster RC 2023
-- www.radiomasterrc.com
-- https://github.com/Radiomaster-RC/EdgeTX-LapTimer
-- 
-- Original Credit to:
-- Lap Timer by Jeremy Cowgar <jeremy@cowgar.com>
-- https://github.com/jcowgar/opentx-laptimer

--
-- User Configuration
--

local SOUND_GOOD_LAP = 'LAPTIME/better.wav'
local SOUND_BAD_LAP = 'LAPTIME/worse.wav'
local SOUND_RACE_SAVE = 'LAPTIME/rsaved.wav'
local SOUND_RACE_DISCARD = 'LAPTIME/rdiscard.wav'
local SOUND_LAP = 'LAPTIME/lap.wav'

--
-- User Configuration Done
--
-- Do not alter below unless you know what you're doing!
--

--
-- Constants
--

-- Define the screen size
local MAXLAP = 99

local OFF_MS = 100
local MID_MS_MIN = -100
local MID_MS_MAX = 100
local ON_MS  = 924

local SCREEN_RACE_SETUP = 1
local SCREEN_CONFIGURATION = 2
local SCREEN_TIMER = 3
local SCREEN_POST_RACE = 4

local SWITCH_NAMES = { 'sa', 'sb', 'sc', 'sd', 'se', 'sf', 'sg', 'sh', 'si'}

local CONFIG_FILENAME = '/LAPTIME.cfg'
local CSV_FILENAME = '/LAPTIME.csv'

--
-- Configuration Variables
--

local ConfigThrottleChannelNumber = 1
local ConfigThrottleChannel = 'ch2'
local ConfigLapSwitch = 'sd'
local ConfigSpeakGoodBad = true
local ConfigSpeakLapNumber = true
local ConfigSpeakLapTime = true
local ConfigBeepOnMidLap = true
local ConfigCsvSeparator = ';'

--
-- State Variables
--

local currentScreen = SCREEN_RACE_SETUP

-- Setup Related

local lapCount = 3

-- Timer Related

local isTiming = false
local lastLapSw = -2048
local spokeGoodBad = false

local laps = {}
local lapNumber = 0
local lapStartDateTime = {}
local lapStartTicks = 0
local lapSpokeMid = false

local raceThrottleSum = 0
local raceThrottleSamples = 0
local raceFullThrottleCount = 0
local wasFullThrottle = false

local lapThrottleSum = 0
local lapThrottleSamples = 0
local lapFullThrottleCount = 0
local lapWasFullThrottle = false

-----------------------------------------------------------------------
--
-- Helper Methods (Generic)
--
-----------------------------------------------------------------------

local function iif(cond, T, F)
    if cond then return T else return F end
end

local function throttlePercent(sum, samples)
	if samples <= 0 then
		return 0.0
	end

	-- Raw channel value spans -1024 (idle) to 1024 (full stick), so shift
	-- it into a 0-100% range instead of a signed -100%..100% one.
	return ((sum / samples) + 1024) / 20.48
end

local function formatLapTime(ticks)
	-- ticks are centiseconds (hundredths of a second), so the millisecond
	-- digit is always a multiple of 10 -- that is the best precision the
	-- timer actually has.
	local minutes = math.floor(ticks / 6000)
	local seconds = math.floor(ticks / 100) % 60
	local millis = (ticks % 100) * 10

	return string.format('%02d:%02d.%03d', minutes, seconds, millis)
end

-----------------------------------------------------------------------
--
-- Configuration
--
-----------------------------------------------------------------------

local CONFIG_FIELD_THROTTLE = 1
local CONFIG_FIELD_ConfigLapSwitch = 2
local CONFIG_FIELD_SPEAK_BETTER_WORSE = 3
local CONFIG_FIELD_SPEAK_LAP = 4
local CONFIG_FIELD_SPEAK_LAP_TIME = 5
local CONFIG_FIELD_BEEP_AT_HALF = 6
local CONFIG_FIELD_CSV_SEPARATOR = 7

local CONFIG_OPTIONS = {
	{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
	SWITCH_NAMES,
	{ 'Yes', 'No' },
	{ 'Yes', 'No' },
	{ 'Yes', 'No' },
	{ 'Yes', 'No' },
	{ ',', ';' }
}

local ConfigCurrentField = CONFIG_FIELD_THROTTLE
local ConfigEditing = false

local function config_read()
	--
	-- OpenTX Lua throws an error if you attempt to open a file that does not exist:
	--
	-- f_open(/Users/jeremy/Documents/RC/Taranis-X9E-SD/LAPTIME.cfg) = INVALID_NAME
	-- f_close(0x1439291e05400000) (FIL:0x114392828)
	-- PANIC: unprotected error in call to Lua API ((null))
	--
	-- Thus, let's open it in append mode, which should create a blank file if it does
	-- not yet exist.
	--
	
	local f = io.open(CONFIG_FILENAME, 'a')
	if f ~= nil then
		io.close(f)
	end

	f = io.open(CONFIG_FILENAME, 'r')
	if f == nil then
		-- defaults will be used
		return false
	end
	
	local content = io.read(f, 1024)
	io.close(f)
	
	if content == '' then
		-- defaults will be used
		return false
	end
	
	local c = {}

	for value in string.gmatch(content, '([^,]+)') do
		c[#c + 1] = value
	end
	
	ConfigThrottleChannelNumber = tonumber(c[1])
	ConfigThrottleChannel = 'ch' .. c[1]
	ConfigLapSwitch = c[2]
	ConfigSpeakGoodBad = (c[3] == 'true')
	ConfigSpeakLapNumber = (c[4] == 'true')
	ConfigBeepOnMidLap = (c[5] == 'true')

	-- c[6] did not exist in configs saved before "Speak Lap Time" was added,
	-- so keep the default (true) instead of forcing it off for existing users.
	if c[6] ~= nil then
		ConfigSpeakLapTime = (c[6] == 'true')
	end

	-- c[7] is stored as the word "comma" or "semi" rather than the literal
	-- character, since a literal comma would be misread as an extra,
	-- empty field by the comma-delimited parser above.
	if c[7] ~= nil then
		ConfigCsvSeparator = iif(c[7] == 'comma', ',', ';')
	end

	return true
end

local function config_write()
	local f = io.open(CONFIG_FILENAME, 'w')
	io.write(f, ConfigThrottleChannelNumber)
	io.write(f, ',' .. ConfigLapSwitch)
	io.write(f, ',' .. iif(ConfigSpeakGoodBad, 'true', 'false'))
	io.write(f, ',' .. iif(ConfigSpeakLapNumber, 'true', 'false'))
	io.write(f, ',' .. iif(ConfigBeepOnMidLap, 'true', 'false'))
	io.write(f, ',' .. iif(ConfigSpeakLapTime, 'true', 'false'))
	io.write(f, ',' .. iif(ConfigCsvSeparator == ',', 'comma', 'semi'))
	io.close(f)
end

local function config_cycle_editing_value(keyEvent)
	local values = CONFIG_OPTIONS[ConfigCurrentField]
	local value
	
	if ConfigCurrentField == CONFIG_FIELD_THROTTLE then
		value = ConfigThrottleChannelNumber
	elseif ConfigCurrentField == CONFIG_FIELD_ConfigLapSwitch then
		value = ConfigLapSwitch
	elseif ConfigCurrentField == CONFIG_FIELD_SPEAK_BETTER_WORSE then
		value = iif(ConfigSpeakGoodBad, 'Yes', 'No')
	elseif ConfigCurrentField == CONFIG_FIELD_SPEAK_LAP then
		value = iif(ConfigSpeakLapNumber, 'Yes', 'No')
	elseif ConfigCurrentField == CONFIG_FIELD_BEEP_AT_HALF then
		value = iif(ConfigBeepOnMidLap, 'Yes', 'No')
	elseif ConfigCurrentField == CONFIG_FIELD_SPEAK_LAP_TIME then
		value = iif(ConfigSpeakLapTime, 'Yes', 'No')
	elseif ConfigCurrentField == CONFIG_FIELD_CSV_SEPARATOR then
		value = ConfigCsvSeparator
	end

	local idx = 1

	for i = 1, #values do
		if values[i] == value then
			idx = i
		end
	end
	
	if keyEvent == EVT_ROT_LEFT then
		idx = idx - 1
	elseif keyEvent == EVT_ROT_RIGHT then
		idx = idx + 1
	end
	
	if idx < 1 then
		idx = #values
	elseif idx > #values then
		idx = 1
	end

	value = values[idx]

	if ConfigCurrentField == CONFIG_FIELD_THROTTLE then
		ConfigThrottleChannelNumber = idx
		ConfigThrottleChannel = 'ch' .. string.format('%d', idx)
	elseif ConfigCurrentField == CONFIG_FIELD_ConfigLapSwitch then
		ConfigLapSwitch = value
	elseif ConfigCurrentField == CONFIG_FIELD_SPEAK_BETTER_WORSE then
		ConfigSpeakGoodBad = (value == 'Yes')
	elseif ConfigCurrentField == CONFIG_FIELD_SPEAK_LAP then
		ConfigSpeakLapNumber = (value == 'Yes')
	elseif ConfigCurrentField == CONFIG_FIELD_BEEP_AT_HALF then
		ConfigBeepOnMidLap = (value == 'Yes')
	elseif ConfigCurrentField == CONFIG_FIELD_SPEAK_LAP_TIME then
		ConfigSpeakLapTime = (value == 'Yes')
	elseif ConfigCurrentField == CONFIG_FIELD_CSV_SEPARATOR then
		ConfigCsvSeparator = value
	end
end

local function configuration_func(keyEvent)
	if keyEvent == EVT_ENTER_BREAK then
		if ConfigEditing then
			ConfigEditing = false
		else
			ConfigEditing = true
		end
	
	elseif ConfigEditing and 
		(
			keyEvent == EVT_ROT_LEFT or keyEvent == EVT_ROT_RIGHT 
		)
	then
		config_cycle_editing_value(keyEvent)
	
	elseif keyEvent == EVT_ROT_LEFT  then
		ConfigCurrentField = ConfigCurrentField - 1
		
		if ConfigCurrentField < CONFIG_FIELD_THROTTLE then
			ConfigCurrentField = CONFIG_FIELD_CSV_SEPARATOR
		end

	elseif keyEvent == EVT_ROT_RIGHT  then
		ConfigCurrentField = ConfigCurrentField + 1
		
		if ConfigCurrentField > CONFIG_FIELD_CSV_SEPARATOR then
			ConfigCurrentField = CONFIG_FIELD_THROTTLE
		end
	
	elseif keyEvent == EVT_VIRTUAL_NEXT_PAGE or  keyEvent == EVT_VIRTUAL_PREV_PAGE then
		config_write()
		
		currentScreen = SCREEN_RACE_SETUP

		return
	end
	
	lcd.clear()

	--lcd.drawScreenTitle('Configuration', 2, 2)
	lcd.drawFilledRectangle(0, 0, 80, 11, BLACK)	
	lcd.drawText(2, 2, 'Configuration:',INVERS)
	lcd.drawText(2, 12, 'Throttle Channel:', SMLSIZE)
	lcd.drawText(lcd.getLastPos() + 2, 12, ConfigThrottleChannelNumber, 
		iif(ConfigCurrentField == CONFIG_FIELD_THROTTLE, 
			iif(ConfigEditing, INVERS+BLINK, INVERS), 0) + SMLSIZE)

	lcd.drawText(2, 19, 'Lap Switch:', SMLSIZE)
	lcd.drawText(lcd.getLastPos() + 2, 19, ConfigLapSwitch,
		iif(ConfigCurrentField == CONFIG_FIELD_ConfigLapSwitch,
			iif(ConfigEditing, INVERS+BLINK, INVERS), 0) + SMLSIZE)

	lcd.drawText(2, 26, 'Speak Better/Worse:', SMLSIZE)
	lcd.drawText(lcd.getLastPos() + 2, 26, iif(ConfigSpeakGoodBad, 'Yes', 'No'),
		iif(ConfigCurrentField == CONFIG_FIELD_SPEAK_BETTER_WORSE,
			iif(ConfigEditing, INVERS+BLINK, INVERS), 0) + SMLSIZE)

	lcd.drawText(2, 33, 'Speak Lap Number:', SMLSIZE)
	lcd.drawText(lcd.getLastPos() + 2, 33, iif(ConfigSpeakLapNumber, 'Yes', 'No'),
		iif(ConfigCurrentField == CONFIG_FIELD_SPEAK_LAP,
			iif(ConfigEditing, INVERS+BLINK, INVERS), 0) + SMLSIZE)

	lcd.drawText(2, 40, 'Speak Lap Time:', SMLSIZE)
	lcd.drawText(lcd.getLastPos() + 2, 40, iif(ConfigSpeakLapTime, 'Yes', 'No'),
		iif(ConfigCurrentField == CONFIG_FIELD_SPEAK_LAP_TIME,
			iif(ConfigEditing, INVERS+BLINK, INVERS), 0) + SMLSIZE)

	lcd.drawText(2, 47, 'Beep At Half Lap:', SMLSIZE)
	lcd.drawText(lcd.getLastPos() + 2, 47, iif(ConfigBeepOnMidLap, 'Yes', 'No'),
		iif(ConfigCurrentField == CONFIG_FIELD_BEEP_AT_HALF,
			iif(ConfigEditing, INVERS+BLINK, INVERS), 0) + SMLSIZE)

	lcd.drawText(2, 54, 'CSV Separator:', SMLSIZE)
	lcd.drawText(lcd.getLastPos() + 2, 54, ConfigCsvSeparator,
		iif(ConfigCurrentField == CONFIG_FIELD_CSV_SEPARATOR,
			iif(ConfigEditing, INVERS+BLINK, INVERS), 0) + SMLSIZE)
end

-----------------------------------------------------------------------
--
-- ???
--
-----------------------------------------------------------------------

local function laps_compute_stats()
	local stats = {}
	local lc = #laps
	local realLapCount = math.max(lc - 1, 0)

	-- laps[1] is the holeshot (launch to first gate crossing), not a real lap.
	-- Real laps are laps[2] .. laps[lc].

	stats.raceLapCount = lapCount
	stats.lapCount = realLapCount
	stats.best = 999999999
	stats.averageLap = 0.0
	stats.totalTime = 0.0
	stats.avgThrottle = 0.0
	stats.fullThrottleCount = raceFullThrottleCount
	stats.holeshot = 0.0

	if lc > 0 then
		stats.holeshot = laps[1][2]
	end

	for i = 2, lc do
		stats.totalTime = stats.totalTime + laps[i][2]
	end

	for i = 2, lc do
		stats.best = iif(stats.best > laps[i][2], laps[i][2], stats.best)
	end

	if realLapCount > 0 then
		stats.averageLap = stats.totalTime / realLapCount
	end

	stats.avgThrottle = throttlePercent(raceThrottleSum, raceThrottleSamples)

	return stats
end

local function laps_show(x, y, max, ascending)
	local lc = #laps

	-- laps[1] is the holeshot, not a real lap, so it is never listed here.
	if lc < 2 then
		return
	end

	local lcStart = math.max(lc - max + 1, 2)
	local row = 0

	if ascending then
		for i = lcStart, lc do
			local lap = laps[i]

			lcd.drawText(x, (row * 10) + y,
				string.format('%d', i - 1) .. ': ' ..
				string.format('%0.2f', lap[2] / 100.0))
			row = row + 1
		end
	else
		for i = lc, lcStart, -1 do
			local lap = laps[i]

			lcd.drawText(x, (row * 10) + y,
				string.format('%d', i - 1) .. ': ' ..
				string.format('%0.2f', lap[2] / 100.0))
			row = row + 1
		end
	end
end

-----------------------------------------------------------------------
--
-- Setup Portion of the program
--
-----------------------------------------------------------------------

local setup_did_initial_draw = false
--local BitmapP = null

local function race_setup_draw()
	if setup_did_initial_draw == false then
		setup_did_initial_draw = true
		
		lcd.clear()
	   
		--lcd.drawScreenTitle('Configuration', 1, 2)
		--BitmapP = Bitmap.open('/BMP/LAPTIME/S_SWHAND.bmp');
		--lcd.drawBitmap(Bitmap.open('/BMP/LAPTIME/S_SWHAND.bmp') , 5, 11)
		--lcd.drawPixmap(2, 14, '/BMP/LAPTIME/S_TITLE.bmp')
	end
	
	-- Clear the lap counter (if you go from 10 down to 9, for example, it displays as 90
	--lcd.drawText(63, 47, '     ', MIDSIZE)
	lcd.clear()
	lcd.drawText(70, 0, 'Config:Page >', SMLSIZE)
    lcd.drawText(25, 20, 'LAPTIMER', DBLSIZE)
	lcd.drawText(0, 55, 'Lap Count:')
	--lcd.drawText(63, 55, ' ' .. lapCount .. ' ', INVERS)
	lcd.drawText(lcd.getLastPos() + 5, 55, lapCount, INVERS)
end

local function race_setup_func(keyEvent)
	if keyEvent == EVT_ROT_RIGHT  then
		lapCount = lapCount + 1

	elseif keyEvent == EVT_ROT_LEFT then
		lapCount = lapCount - 1

	elseif keyEvent == EVT_VIRTUAL_NEXT_PAGE or  keyEvent == EVT_VIRTUAL_PREV_PAGE  then
		currentScreen = SCREEN_CONFIGURATION
		setup_did_initial_draw = false
		return

	elseif keyEvent == EVT_ENTER_BREAK then
		currentScreen = SCREEN_TIMER
		setup_did_initial_draw = false
		return
	end
	
	if lapCount < 1 then
		lapCount = 1
	elseif lapCount > MAXLAP then
		lapCount = MAXLAP
	end
	
	race_setup_draw()
end

-----------------------------------------------------------------------
--
-- Timer Portion of the program
--
-----------------------------------------------------------------------

local function timerReset()
	isTiming = false
	lapStartTicks = 0
	lapStartDateTime = {}
	lapSpokeMid = false
end

local function timerStart()
	isTiming = true
	lapStartTicks = getTime()
	lapStartDateTime = getDateTime()
	lapSpokeMid = false
	spokeGoodBad = false
	lapThrottleSum = 0
	lapThrottleSamples = 0
	lapFullThrottleCount = 0
	lapWasFullThrottle = false
end

local function timerDraw()
	local tickNow = getTime()
	local tickDiff = tickNow - lapStartTicks
	
	lcd.drawNumber(0, 11, tickDiff, PREC2 + DBLSIZE)
	
	if ConfigBeepOnMidLap and lapSpokeMid == false then
		local lastIndex = #laps

		if lastIndex >= 2 then
			local mid = laps[lastIndex][2] / 2
			if mid < tickDiff then
				playTone(700, 300, 5, PLAY_BACKGROUND, 1000)
				lapSpokeMid = true
			end
		end
	end
end

local function lapsReset()
	laps = {}
	lapNumber = 0
	raceThrottleSum = 0
	raceThrottleSamples = 0
	raceFullThrottleCount = 0
	wasFullThrottle = false

	timerReset()
end

local function csv_write_datetime(f, dt)
	io.write(f,
		string.format('%02d', dt.year), '-',
		string.format('%02d', dt.mon), '-',
		string.format('%02d', dt.day), ' ',
		string.format('%02d', dt.hour), ':',
		string.format('%02d', dt.min), ':',
		string.format('%02d', dt.sec))
end

local function lapsSave()
	local needsHeader = true
	local existing = io.open(CSV_FILENAME, 'r')

	if existing ~= nil then
		local content = io.read(existing, 1)
		io.close(existing)

		if content ~= nil and content ~= '' then
			needsHeader = false
		end
	end

	local f = io.open(CSV_FILENAME, 'a')

	local sep = ConfigCsvSeparator

	if needsHeader then
		io.write(f, 'Date' .. sep .. 'Lap' .. sep .. 'LapCount' .. sep .. 'Time' .. sep .. 'ThrottleAvg' .. sep .. 'Throttle100Count', "\r\n")
	end

	for i = 1, #laps do
		local lap = laps[i]

		csv_write_datetime(f, lap[1])
		io.write(f,
			sep, i - 1, sep, lapCount, sep, -- lap 0 is the holeshot
			formatLapTime(lap[2]), sep,
			string.format('%0.1f', lap[3]), sep,
			lap[4],
			"\r\n")
	end

	-- Race summary row -- Lap and LapCount are left blank
	if #laps > 0 then
		local stats = laps_compute_stats()

		csv_write_datetime(f, laps[1][1])
		io.write(f,
			sep, sep, sep, -- Lap and LapCount are blank on the summary row
			formatLapTime(stats.totalTime), sep,
			string.format('%0.1f', stats.avgThrottle), sep,
			stats.fullThrottleCount,
			"\r\n")
	end

	io.close(f)

	lapsReset()
end

local function lapsSpeakProgress()
	-- laps[1] is the holeshot, not a real lap, so it stays silent here.
	if #laps > 1 then
		local thisLapTime = laps[#laps][2]

		if ConfigSpeakLapNumber then
			playFile(SOUND_LAP)
			playNumber(#laps - 1, 0)
		end

		if ConfigSpeakLapTime then
			playNumber(thisLapTime, 0, PREC2)
		end

		if #laps > 2 then
			local lastLapTime = laps[#laps - 1][2]

			if ConfigSpeakGoodBad and spokeGoodBad == false then
				spokeGoodBad = true

				if thisLapTime < lastLapTime then
					playFile(SOUND_GOOD_LAP)
				else
					playFile(SOUND_BAD_LAP)
				end
			end
		end
	end
end

local function timer_func(keyEvent)
	local showTiming = isTiming
	
    if keyEvent == EVT_EXIT_BREAK then
		lapsReset()		
		currentScreen = SCREEN_RACE_SETUP
		return
	end

	lcd.clear()
	
	if isTiming then
		-- Average (real laps only -- laps[1] is the holeshot)
		local avg = 0.0
		local diff = 0.0
		local realLapCount = #laps - 1

		if realLapCount > 0 then
			local sum = 0
			for i = 2, #laps do
				sum = sum + laps[i][2]
			end

			avg = sum / realLapCount
		end

		if realLapCount > 1 then
			local lastLapTime = laps[#laps - 1][2]
			local thisLapTime = laps[#laps][2]

			diff = thisLapTime - lastLapTime
		end

		--
		-- Sample the throttle for the final race statistics
		--

		local throttleVal = getValue(ConfigThrottleChannel)
		raceThrottleSum = raceThrottleSum + throttleVal
		raceThrottleSamples = raceThrottleSamples + 1
		lapThrottleSum = lapThrottleSum + throttleVal
		lapThrottleSamples = lapThrottleSamples + 1

		local isFullThrottle = (throttleVal >= ON_MS)

		if isFullThrottle and wasFullThrottle == false then
			raceFullThrottleCount = raceFullThrottleCount + 1
		end
		wasFullThrottle = isFullThrottle

		if isFullThrottle and lapWasFullThrottle == false then
			lapFullThrottleCount = lapFullThrottleCount + 1
		end
		lapWasFullThrottle = isFullThrottle

		-- Column 1
		lcd.drawFilledRectangle(0, 0, 70, 11, BLACK)
		lcd.drawText(0, 2, 'CUR', INVERS)

		lcd.drawFilledRectangle(0, 31, 70, 11, BLACK)
		lcd.drawText(0, 33, 'AVG', INVERS)
		lcd.drawNumber(0, 42, avg, PREC2 + MIDSIZE)

		-- Column 2
		lcd.drawFilledRectangle(70, 0, 70, 11, BLACK)
		lcd.drawText(65, 2, 'DIFF', INVERS)
		lcd.drawNumber(65, 11, diff, PREC2 + MIDSIZE)

		lcd.drawFilledRectangle(70, 31, 70, 11, BLACK)
		lcd.drawText(65, 33, 'LAP', INVERS)
		lcd.drawNumber(65, 42, math.max(lapNumber - 1, 0), MIDSIZE)

		lcd.drawLine(63, 0, 63, 63, SOLID, FORCE)
		--lcd.drawLine(140, 0, 140, 63, SOLID, FORCE)
		--lcd.drawNumber(135, 35, lapCount, MIDSIZE)
		--lcd.drawText(102, 42, 'of')

		-- Outline
		--lcd.drawRectangle(0, 0, 212, 64, SOLID)
	
	else
		lcd.drawText(0, 15, 'Waiting for', MIDSIZE)
		lcd.drawText(0, 35, 'Race Start', MIDSIZE)
	end


	--
	-- Check to see if we should do anything with the lap switch
	--
	
	local lapSwVal = getValue(ConfigLapSwitch)
	local lapSwChanged = (lastLapSw ~= lapSwVal)
	
	--
	-- Trick our system into thinking it should start the
	-- timer if our throttle goes high
	--
	
	if isTiming == false and getValue(ConfigThrottleChannel) >= OFF_MS then
		lapSwChanged = true
		lapSwVal = ON_MS
	end
	
	--
	-- Start a new lap
	--
	
	if lapSwChanged and lapSwVal >= ON_MS then
		if isTiming then
			--
			-- We already have a lap going, save the timer data
			--
			
			local lapTicks = (getTime() - lapStartTicks)
			local lapAvgThrottle = throttlePercent(lapThrottleSum, lapThrottleSamples)

			laps[lapNumber] = { lapStartDateTime, lapTicks, lapAvgThrottle, lapFullThrottleCount }
		end
		
		lapsSpeakProgress()
		
		lapNumber = lapNumber + 1
		
		if lapNumber > lapCount + 1 then
			timerReset()
			
			lapNumber = 0
			
			currentScreen = SCREEN_POST_RACE
		else
			timerStart()
		end
	end
	
	lastLapSw = lapSwVal

	if showTiming then
		timerDraw()

		laps_show(170, 3, 6, true)
	end
end

-----------------------------------------------------------------------
--
-- Post Race Portion of the program
--
-----------------------------------------------------------------------

local PR_SAVE = 1
local PR_DISCARD = 2

local post_race_option = PR_SAVE

local function post_race_func(keyEvent)
	local stats = laps_compute_stats()

	if keyEvent == EVT_ROT_LEFT or keyEvent == EVT_ROT_RIGHT 
	then
		if post_race_option == PR_SAVE then
			post_race_option = PR_DISCARD
		elseif post_race_option == PR_DISCARD then
			post_race_option = PR_SAVE
		end
	end

	local saveFlag = 0
	local discardFlag = 0
	
	if post_race_option == PR_SAVE then
		saveFlag = INVERS
	elseif post_race_option == PR_DISCARD then
		discardFlag = INVERS
	end

	lcd.clear()
	lcd.drawFilledRectangle(0, 0, 87, 11, BLACK)	
	lcd.drawText(2, 2, 'Post Race Stats', INVERS)
	lcd.drawText(2, 55, ' Save ', saveFlag)
	lcd.drawText(35, 55, ' Discard ', discardFlag)
	
	laps_show(90, 3, 6, true)

	lcd.drawText(0, 13, 'Done: ' .. stats.lapCount .. ' of ' .. stats.raceLapCount .. '  ')
	lcd.drawText(0, 23, 'Best: ' .. string.format('%0.2f', stats.best / 100.0) .. ' S')
	lcd.drawText(0, 33, 'Avg: ' .. string.format('%0.2f', stats.averageLap / 100.0) .. ' S')
	lcd.drawText(0, 43, 'Tot: ' .. string.format('%0.2f', stats.totalTime / 100.0) .. ' S')

	-- Column 3
	lcd.drawText(150, 13, 'HS: ' .. string.format('%0.2f', stats.holeshot / 100.0) .. ' S')
	lcd.drawText(150, 23, 'Thr Avg: ' .. string.format('%0.0f', stats.avgThrottle) .. '%')
	lcd.drawText(150, 33, 'Thr 100: x' .. stats.fullThrottleCount)

	if keyEvent == EVT_ENTER_BREAK then
		if post_race_option == PR_SAVE then
			lapsSave()
		
			playFile(SOUND_RACE_SAVE)
		
			currentScreen = SCREEN_TIMER
		elseif post_race_option == PR_DISCARD then
			lapsReset()
		
			playFile(SOUND_RACE_DISCARD)
		
			currentScreen = SCREEN_TIMER
		end
	
	end
end



-----------------------------------------------------------------------
--
-- EdgeTx Entry Points
--
-----------------------------------------------------------------------

local function init_func()
	lcd.clear()
	
	if config_read() == false then
		--
		-- A configuration file did not exist, so let's drop the user off a the lap timer
		-- configuration screen. Let them setup some basic preferences for all races.
		--
		
		currentScreen = SCREEN_CONFIGURATION
	end
end

local function run_func(keyEvent)
	if currentScreen == SCREEN_CONFIGURATION then
		configuration_func(keyEvent)
	elseif currentScreen == SCREEN_RACE_SETUP then
		race_setup_func(keyEvent)
	elseif currentScreen == SCREEN_TIMER then
		timer_func(keyEvent)
	elseif currentScreen == SCREEN_POST_RACE then
		post_race_func(keyEvent)
	
	
	end
	
	return 0
	--lcd.drawText(2, 2, 'Post Race Stats', SMLSIZE)
end

return { init=init_func, run=run_func }
