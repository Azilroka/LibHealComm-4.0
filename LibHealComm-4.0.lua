local major = "LibHealComm-4.0"
local minor = 6
assert(LibStub, string.format("%s requires LibStub.", major))

local HealComm = LibStub:NewLibrary(major, minor)
if( not HealComm ) then return end

-- This needs to be bumped if there is a major change that breaks the comm format
local COMM_PREFIX = "LHC40"
local playerGUID, playerName

HealComm.callbacks = HealComm.callbacks or LibStub:GetLibrary("CallbackHandler-1.0"):New(HealComm)

HealComm.glyphCache = HealComm.glyphCache or {}
HealComm.playerModifiers = HealComm.playerModifiers or {}
HealComm.guidToGroup = HealComm.guidToGroup or {}
HealComm.guidToUnit = HealComm.guidToUnit or {}
HealComm.spellToID = HealComm.spellToID or {}
HealComm.pendingHeals = HealComm.pendingHeals or {}

-- These shouldn't be persistant between versions because if healing data changes it should reload all the spells inside regardless
local spellData, hotData = {}, {}

-- Figure out what they are now since a few things change based off of this
local playerClass = select(2, UnitClass("player"))
local isHealerClass
if( playerClass == "DRUID" or playerClass == "PRIEST" or playerClass == "SHAMAN" or playerClass == "PALADIN" ) then
	isHealerClass = true
end

-- Stolen from Threat-2.0, compresses GUIDs from 18 characters -> 10 and uncompresses them to their original state
local map = {[254] = "\254\252", [61] = "\254\251", [58] = "\254\250", [255] = "\254\253", [0] = "\255"} 
local guidCompressHelper = function(x)
   local a = tonumber(x, 16) 
   return map[a] or string.char(a)
end

local dfmt = "0x%02X%02X%02X%02X%02X%02X%02X%02X"
local function unescape(str)
   str = string.gsub(str, "\255", "\000")
   str = string.gsub(str, "\254\253", "\255")
   str = string.gsub(str, "\254\251", "\061")
   str = string.gsub(str, "\254\250", "\058")
   return string.gsub(str, "\254\252", "\254")
end

local compressGUID = setmetatable({}, {
	__index = function(self, guid)
         local cguid = string.match(guid, "0x(.*)")
         local str = string.gsub(cguid, "(%x%x)", guidCompressHelper)
         self[guid] = str
         return str
end})

local decompressGUID = setmetatable({}, {
	__index = function(self, str)
		if( not str ) then return nil end
		local usc = unescape(str)
		local guid = string.format(dfmt, string.byte(usc, 1, 8))
		self[str] = guid
		return guid
end})

	
-- Validation for passed arguments
if( not HealComm.tooltip ) then
	local tooltip = CreateFrame("GameTooltip")
	tooltip:SetOwner(UIParent, "ANCHOR_NONE")
	for i=1, 8 do
		tooltip["TextLeft" .. i] = tooltip:CreateFontString()
		tooltip["TextRight" .. i] = tooltip:CreateFontString()
		tooltip:AddFontStrings(tooltip["TextLeft" .. i], tooltip["TextRight" .. i])
	end
	
	HealComm.tooltip = tooltip
end

-- So I don't have to keep matching the same numbers every time :<
if( not HealComm.rankNumbers ) then
	HealComm.rankNumbers = setmetatable({}, {
		__index = function(tbl, index)
			local number = tonumber(string.match(index, "(%d+)")) or 1
			rawset(tbl, index, number)
			
			return number
		end,
	})
end

-- Get the average heal amount and cache it
-- We don't need to reset this table on spell change
if( not HealComm.averageHeal ) then
	HealComm.averageHeal = setmetatable({}, {
		__index = function(tbl, index)
			-- Find the spell from the spell book and cache the results!
			local offset, numSpells = select(3, GetSpellTabInfo(GetNumSpellTabs()))
			for id=1, (offset + numSpells) do
				-- Match, yay!
				local spellName, spellRank = GetSpellName(id, BOOKTYPE_SPELL)
				local name = spellName .. spellRank
				if( index == name ) then
					HealComm.tooltip:SetSpell(id, BOOKTYPE_SPELL)
					
					-- Check last line for the spell info
					local text = HealComm.tooltip["TextLeft" .. HealComm.tooltip:NumLines()]
					if( text ) then
						-- The ..? is to match one to two characters between two numbers to be localization independant
						-- And the string.gmatch is to account for the fact that spells like Holy Shock or Penance will list the damage spell first
						-- then the healing spell last, so we do a string.gmatch to get the healing average not damage average
						local minHeal, maxHeal
						for min, max in string.gmatch(text:GetText(), "(%d+) ..? (%d+)") do
							minHeal, maxHeal = min, max
						end
						
						-- Some spells like Tranquility or hots in general don't have a range on them, match the first number it finds
						-- (and pray)
						if( not minHeal and not maxHeal and ( hotData[spellName] or spellData[spellName].noRange ) ) then
							local heal = string.match(text:GetText(), "(%d+)")
							minHeal, maxHeal = heal, heal
						end
						
						minHeal = tonumber(minHeal)
						maxHeal = tonumber(maxHeal)
						
						if( minHeal and maxHeal ) then
							-- Already scanning the tooltip, might as well pull the spellID for comm too
							HealComm.spellToID[name] = select(3, HealComm.tooltip:GetSpell())

							local average = (minHeal + maxHeal) / 2
							tbl[index] = average
							return tbl[index]
						else
							tbl[index] = false
							return tbl[index]
						end
					end
					
					break
				end
			end
			
			tbl[index] = false
			return false
		end,
	})
end

-- APIs
local pendingHeals = HealComm.pendingHeals
local ALL_DATA = 0x0f
local DIRECT_HEALS = 0x01
local CHANNEL_HEALS = 0x02
local HOT_HEALS = 0x04
local ABSORB_SHIELDS = 0x08
local ALL_HEALS = bit.bor(DIRECT_HEALS, CHANNEL_HEALS, HOT_HEALS)
local CASTED_HEALS = bit.bor(DIRECT_HEALS, CHANNEL_HEALS)

HealComm.ALL_HEALS, HealComm.CHANNEL_HEALS, HealComm.DIRECT_HEALS, HealComm.HOT_HEALS, HealComm.CASTED_HEALS, HealComm.ABSORB_SHIELDS, HealComm.ALL_DATA = ALL_HEALS, CHANNEL_HEALS, DIRECT_HEALS, HOT_HEALS, CASTED_HEALS, ABSORB_SHIELDS, ALL_DATA

-- Returns the current healing modifier for the GUID
function HealComm:GetHealModifier(guid)
	return HealComm.currentModifiers[guid] or 1
end

-- Returns whether or not the GUID has casted a heal
function HealComm:GUIDHasHealed(guid)
	return pendingHeals[guid] and true or nil
end

-- Returns the guid to unit table
local protectedMap = setmetatable({}, {
	__index = function(tbl, key) return HealComm.guidToUnit[key] end,
	__newindex = function() error("This is a read only table and cannot be modified.", 2) end,
	__metatable = false
})

function HealComm:GetGuidUnitMapTable()
	return protectedMap
end

-- Get the healing amount that matches the passed filters
local function filterData(spells, filterGUID, bitFlag, time)
	local healAmount = 0
	local currentTime = GetTime()
	
	for _, pending in pairs(spells) do
		if( pending.bitType and bit.band(pending.bitType, bitFlag) > 0 ) then
			for i=1, #(pending), 3 do
				local guid = pending[i]
				if( guid == filterGUID ) then
					local amount = pending[i + 1]
					local endTime = pending[i + 2]
					endTime = endTime > 0 and endTime or pending.endTime

					-- Direct heals are easy, if they match the filter then return them
					if( pending.bitType == DIRECT_HEALS and ( not time or endTime <= time ) ) then
						healAmount = healAmount + amount
					-- Channeled heals and hots, have to figure out how many times it'll tick within the given time band
					-- this logic works well for the time being, but it needs to be changed to specifically calculate at what GetTime()
					-- each tick happens, because if the next tick is in 0.50s and we want the next 0.75s, then it will be wrong
					elseif( pending.bitType == CHANNEL_HEALS or pending.bitType == HOT_HEALS ) then
						local timeBand = math.min(time and time - currentTime or math.huge, endTime - GetTime())
						if( timeBand > 0 and timeBand >= pending.tickInterval ) then
							local ticks = math.floor((timeBand / pending.tickInterval) + 0.5)
							healAmount = healAmount + (amount * ticks)
						end
					end
				end
			end
		end
	end
	
	return healAmount
end

-- Gets healing amount using the passed filters
function HealComm:GetHealAmount(guid, bitFlag, time, casterGUID)
	local amount = 0
	if( casterGUID and pendingHeals[casterGUID] ) then
		amount = filterData(pendingHeals[casterGUID], guid, bitFlag, time)
	elseif( not casterGUID ) then
		for _, spells in pairs(pendingHeals) do
			amount = amount + filterData(spells, guid, bitFlag, time)
		end
	end
	
	return amount > 0 and amount or nil
end

-- Gets healing amounts for everyone except the player using the passed filters
function HealComm:GetOthersHealAmount(guid, bitFlag, time)
	local amount = 0
	for casterGUID, spells in pairs(pendingHeals) do
		if( casterGUID ~= playerGUID ) then
			amount = amount + filterData(spells, guid, bitFlag, time)
		end
	end
	
	return amount > 0 and amount or nil
end

-- Healing class data
-- Thanks to Gagorian (DrDamage) for letting me steal his formulas and such
local playerHealModifier, playerCurrentRelic = 1

local playerModifiers, averageHeal, rankNumbers = HealComm.playerModifiers, HealComm.averageHeal, HealComm.rankNumbers
local guidToUnit, guidToGroup, glyphCache = HealComm.guidToUnit, HealComm.guidToGroup, HealComm.glyphCache
local talentData, baseHealingRelics = {}, {}
local equippedSetPieces, itemSetsData = {}, {}

-- Function calls for class data
local CalculateHealing, GetHealTargets, AuraHandler, CalculateHotHealing, ResetChargeData

-- UnitBuff priortizes our buffs over everyone elses when there is a name conflict, so yay for that
local function unitHasAura(unit, name)
	return select(8, UnitBuff(unit, name)) == "player"
end

-- Note because I always forget:
-- Multiplictive modifiers are applied to base heal + spell power after all other calculations
-- Additive modifiers are applied to the end amount after all calculations
-- Penalty modifiers are applied directly to the spell power
-- Crit modifiers are applied after all of those calculations
-- Self modifiers such as MS or Avenging Wrath should be applied after the crit calculations
local function calculateGeneralAmount(level, amount, spellPower, multiModifier, addModifier)
	-- Apply downranking penalities for spells below 20
	local penalty = 1
	if( level < 20 ) then
		penalty = penalty * (1 - ((20 - level) * 0.0375))
	end

	-- Apply further downranking penalities
	penalty = penalty * math.min(1, math.max(0, 1 - (UnitLevel("player") - level - 11) * 0.05))
				
	-- Do the general factoring
	spellPower = spellPower * penalty
	return addModifier * (amount + (spellPower * multiModifier))
end

--[[
	What the different callbacks do:
	
	AuraHandler: Specific aura tracking needed for this class, who has Beacon up on them and such
	
	ResetChargeData: Due to spell "queuing" you can't always rely on aura data for buffs that last one or two casts, for example take Divine Favor (+100% crit, one spell)
	if you cast Holy Light and queue Flash of Light the library would still see they have Divine Favor and give them crits on both spells. The reset means that the flag that indicates
	they have the aura can be killed and if they interrupt the cast then it will call this and let you reset the flags.
	
	The order is something like this:
	
	UNIT_SPELLCAST_START, Holy Light -> Divine Favor up
	UNIT_SPELLCAST_SUCCEEDED, Holy Light -> Divine Favor up
	UNIT_SPELLCAST_START, Flash of Light -> Divine Favor up
	UNIT_AURA -> Divine Favor up
	UNIT_AURA -> Divine Favor faded
	
	CalculateHealing: Calculates the healing value, does all the formula calculations talent modifiers and such
	
	CalculateHotHealing: Is used specifically for calculating the heals of hots
	
	GetHealTargets: Who this heal is going to hit, used for setting which targes to hit for Heal of Light, can also be used
	as an override for things like Glyph of Healing Wave which is a 100% heal on target and 20% heal on yourself
	when the 2nd return is amount, it will use that amount for all targets otherwise it will use whatever is passed for each GUID
	
	**NOTE** Any GUID returned from GetHealTargets must be compressed through a call to compressGUID[guid]
]]
	
-- DRUIDS
-- All data is accurate as of 3.2.2 (build 10257)
-- The hot glyphs that factor in +sp per tick need to be improved to actually work
local function loadDruidData()
	-- Spell data
	local WildGrowth = GetSpellInfo(48438)
	local TreeofLife = GetSpellInfo(5420)
	local Innervate = GetSpellInfo(29166)
	
	-- Rejuvenation
	local Rejuvenation = GetSpellInfo(774)
	hotData[Rejuvenation] = {4, 10, 16, 22, 28, 34, 40, 46, 52, 58, 60, 63, 69, 75, 80, interval = 3}
	-- Lifebloom, fun spell. How do you consider the bloom, would that be considered a normal heal at the end? Maybe
	local Lifebloom = GetSpellInfo(33763)
	hotData[Lifebloom] = {64, 72, 80, coeff = 0.66626, interval = 1}
	
	--[[
	-- Wild Growth, another fun spell. The events will either need to support a list of hot ticks... or something like that
	spellData[WildGrowth] = {level = {60, 70, 75, 80}, type = "hot"}
	]]

	-- Regrowth, this will be a bit of an annoying spell to handle once HOT support is added
	local Regrowth = GetSpellInfo(8936)
	spellData[Regrowth] = {12, 18, 24, 30, 36, 42, 48, 54, 60, 65, 71, 77, coeff = 0.2867}
	-- Heaing Touch
	local HealingTouch = GetSpellInfo(5185)
	spellData[HealingTouch] = {1, 8, 14, 20, 26, 32, 38, 44, 50, 56, 60, 62, 69, 74, 79}
	-- Nourish
	local Nourish = GetSpellInfo(50464)
	spellData[Nourish] = {80, coeff = 0.358005}
	-- Tranquility
	local Tranquility = GetSpellInfo(740)
	spellData[Tranquility] = {30, 40, 50, 60, 70, 75, 80, coeff = 1.144681, noRange = true, ticks = 4}

	-- Talent data, these are filled in later and modified on talent changes
	-- Master Shapeshifter (Multi)
	local MasterShapeshifter = GetSpellInfo(48411)
	talentData[MasterShapeshifter] = {mod = 0.02, current = 0}
	-- Gift of Nature (Add)
	local GiftofNature = GetSpellInfo(17104)
	talentData[GiftofNature] = {mod = 0.02, current = 0}
	-- Empowered Touch (Add, increases spell power HT/Nourish gains)
	local EmpoweredTouch = GetSpellInfo(33879)
	talentData[EmpoweredTouch] = {mod = 0.2, current = 0}
	-- Empowered Rejuvenation (Multi, this ups both the direct heal and the hot)
	local EmpoweredRejuv = GetSpellInfo(33886)
	talentData[EmpoweredRejuv] = {mod = 0.04, current = 0}
	-- Genesis (Add)
	local Genesis = GetSpellInfo(57810)
	talentData[Genesis] = {mod = 0.01, current = 0}
	-- Improved Rejuvenation (Add)
	local ImprovedRejuv = GetSpellInfo(17111)
	talentData[ImprovedRejuv] = {mod = 0.05, current = 0}
	
	baseHealingRelics = {[28568] = HealingTouch, [22399] = HealingTouch}
	
	-- Set data
	itemSetsData["T7 Resto"] = {40460, 40461, 40462, 40463, 40465, 39531, 39538, 39539, 39542, 39543}
	--itemSetsData["T8 Resto"] = {46183, 46184, 46185, 46186, 46187, 45345, 45346, 45347, 45348, 45349} 
	--itemSetsData["T9 Resto"] = {48102, 48129, 48130, 48131, 48132, 48153, 48154, 48155, 48156, 48157, 48133, 48134, 48135, 48136, 48137, 48142, 48141, 48140, 48139, 48138, 48152, 48151, 48150, 48149, 48148, 48143, 48144, 48145, 48146, 48147}
	
	local hotTotals, auraData = {}, {}
	AuraHandler = function(guid, unit)
		hotTotals[guid] = 0
		if( unitHasAura(unit, Rejuvenation) ) then hotTotals[guid] = hotTotals[guid] + 1 end
		if( unitHasAura(unit, Lifebloom) ) then hotTotals[guid] = hotTotals[guid] + 1 end
		if( unitHasAura(unit, WildGrowth) ) then hotTotals[guid] = hotTotals[guid] + 1 end
		if( unitHasAura(unit, Regrowth) ) then
			auraData[guid] = true
			hotTotals[guid] = hotTotals[guid] + 1
		else
			auraData[guid] = nil
		end
	end

	GetHealTargets = function(guid, healAmount, spellName, spellRank)
		-- Tranquility pulses on everyone within 30 yards, if they are in range of Innervate they'll get Tranquility
		if( spellName == Tranquility ) then
			local list = compressGUID[guid]
			
			local group = guidToGroup[guid]
			for groupGUID, id in pairs(guidToGroup) do
				if( guid ~= groupGUID and IsSpellInRange(Innervate, guidToUnit[groupGUID]) == 1 ) then
					list = list .. "," .. compressGUID[groupGUID]
				end
			end
			
			return list, healAmount
		end
		
		return compressGUID[guid], healAmount
	end
	
	-- Calculate hot heals
	CalculateHotHealing = function(guid, spellID)
		local spellName, spellRank = GetSpellInfo(spellID)
		local healAmount = HealComm.averageHeal[spellName .. spellRank]
		local spellPower = GetSpellBonusHealing()
		local multiModifier, addModifier = 1, 1
		local rank = HealComm.rankNumbers[spellRank]
		local ticks = 1
		
		addModifier = addModifier + talentData[GiftofNature].current
		multiModifier = multiModifier * (1 + talentData[Genesis].current)
				
		-- Master Shapeshifter does not apply directly when using Lifeblo	om
		if( unitHasAura("player", TreeofLife) ) then
			multiModifier = multiModifier * (1 + talentData[MasterShapeshifter].current)
			
			-- 32387 - Idol of the Raven Godess, +44 SP while in TOL
			if( playerCurrentRelic == 32387 ) then
				spellPower = spellPower + 44
			end
		end

		if( spellName == Rejuvenation ) then
			addModifier = addModifier + talentData[ImprovedRejuv].current

			-- 25643 - Harold's Rejuvenation Broach, +86 Rejuv SP
			if( playerCurrentRelic == 25643 ) then
				spellPower = spellPower + 86
			-- 22398 - Idol of Rejuvenation, +50 SP to Rejuv
			elseif( playerCurrentRelic == 22398 ) then
				spellPower = spellPower + 50
			end
			
			local duration = rank > 14 and 15 or 12
			ticks = duration / hotData[spellName].interval
			
			spellPower = spellPower * (((duration / 15) * 1.88) * (1 + (talentData[EmpoweredRejuv].current)))
			spellPower = spellPower / ticks
			healAmount = healAmount / ticks
			
			--38366 - Idol of Pure Thoughts, +33 SP base per tick
			if( playerCurrentRelic == 38366 ) then
				spellPower = spellPower + 33
			end
		elseif( spellName == Lifebloom ) then
			-- 7 second base duration, 1 second ticks
			ticks = 7
			
			local coeff = (hotData[spellName].coeff * (1 + (talentData[EmpoweredRejuv].current)))
			spellPower = spellPower * coeff
			
			spellPower = spellPower / ticks
			healAmount = healAmount / ticks
			
			-- Idol of Lush Moss, +125 SP per tick
			if( playerCurrentRelic == 40711 ) then
				spellPower = spellPower + 125
			-- Idol of the Emerald Queen, +47 SP per tick
			elseif( playerCurrentRelic == 27886 ) then
				spellPower = spellPower + 47
			end
		end

		healAmount = calculateGeneralAmount(hotData[spellName][rank], healAmount, spellPower, multiModifier, addModifier)
		return HOT_HEALS, healAmount, hotData[spellName].interval
	end
		
	-- Calcualte direct and channeled heals
	CalculateHealing = function(guid, spellName, spellRank)
		local healAmount = HealComm.averageHeal[spellName .. spellRank]
		local spellPower = GetSpellBonusHealing()
		local multiModifier, addModifier = 1, 1
		local rank = HealComm.rankNumbers[spellRank]
		
		-- Gift of Nature
		multiModifier = multiModifier * (1 + talentData[GiftofNature].current)
		
		-- Master Shapeshifter does not apply directly when using Lifebloom
		if( unitHasAura("player", TreeofLife) ) then
			multiModifier = multiModifier * (1 + talentData[MasterShapeshifter].current)
			
			-- 32387 - Idol of the Raven Godess, +44 SP while in TOL
			if( playerCurrentRelic == 32387 ) then
				spellPower = spellPower + 44
			end
		end
		
		-- Regrowth
		if( spellName == Regrowth ) then
			-- Glyph of Regrowth - +20% if target has Regrowth
			if( glyphCache[54743] and auraData[guid] ) then
				multiModifier = multiModifier * 1.20
			end
			
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) * (1 + talentData[EmpoweredRejuv].current))
		-- Nourish
		elseif( spellName == Nourish ) then
			-- 46138 - Idol of Flourishing Life, +187 Nourish SP
			if( playerCurrentRelic == 46138 ) then
				spellPower = spellPower + 187
			end
			
			-- Apply any hot specific bonuses
			local hots = hotTotals[guid] or 0
			if( hots > 0 ) then
				local bonus = 1.20
				
				-- T7 Resto, +5% healing for each of our hots on them
				if( equippedSetPieces["T7 Resto"] >= 2 ) then
					bonus = bonus + 0.05 * hots
				end
				
				-- Glyph of Nourish - 6% per HoT
				if( glyphCache[62971] ) then
					bonus = bonus + 0.06 * hots
				end
				
				multiModifier = multiModifier * bonus
			end
			
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) + talentData[EmpoweredTouch].spent * 0.10)
		-- Healing Touch
		elseif( spellName == HealingTouch ) then
			-- Glyph of Healing Touch, -50% healing
			if( glyphCache[54825] ) then
				multiModifier = multiModifier * 0.50
			end

			-- Rank 1 - 3: 1.5/2/2.5 cast time, Rank 4+: 3 cast time
			local castTime = rank > 3 and 3 or rank == 3 and 2.5 or rank == 2 and 2 or rank == 1 and 1.5
			spellPower = spellPower * (((castTime / 3.5) * 1.88) + talentData[EmpoweredTouch].current)
		-- Tranquility
		elseif( spellName == Tranquility ) then
			addModifier = addModifier + talentData[Genesis].current
			multiModifier = multiModifier + talentData[Genesis].current
			
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) * (1 + talentData[EmpoweredRejuv].current))
			spellPower = spellPower / spellData[spellName].ticks
		end
		
		healAmount = calculateGeneralAmount(spellData[spellName][rank], healAmount, spellPower, multiModifier, addModifier)
		
		-- 100% chance to crit with Nature, this mostly just covers fights like Loatheb where you will basically have 100% crit
		if( GetSpellCritChance(4) >= 100 ) then
			healAmount = healAmount * 1.50
		end
		
		if( spellData[spellName].ticks ) then
			return CHANNEL_HEALS, math.ceil(healAmount * playerHealModifier), spellData[spellName].ticks
		end
		
		return DIRECT_HEALS, math.ceil(healAmount * playerHealModifier)
	end
end

-- PALADINS
-- All data is accurate as of 3.2.2 (build 10257)
local function loadPaladinData()
	-- Spell data
	local HolyLight = GetSpellInfo(635)
	spellData[HolyLight] = {1, 6, 14, 22, 30, 38, 46, 54, 60, 62, 70, 75, 80, coeff = 1.66 / 1.88}
	local FlashofLight = GetSpellInfo(19750)
	spellData[FlashofLight] = {20, 26, 34, 42, 50, 58, 66, 74, 79, coeff = 1.009 / 1.88}
	
	-- Talent data
	-- Need to figure out a way of supporting +6% healing from imp devo aura, might not be able to
	-- Healing Light (Add)
	local HealingLight = GetSpellInfo(20237)
	talentData[HealingLight] = {mod = 0.04, current = 0}
	-- Divinity (Add)
	local Divinity = GetSpellInfo(63646)
	talentData[Divinity] = {mod = 0.01, current = 0}
	-- Touched by the Light (Add?)
	local TouchedbytheLight = GetSpellInfo(53592)
	talentData[TouchedbytheLight] = {mod = 0.10, current = 0}
	-- 100% of your heal on someone within range of your beacon heals the beacon target too
	local BeaconofLight = GetSpellInfo(53563)
	-- 100% chance to crit
	local DivineFavor = GetSpellInfo(20216)
	-- Seal of Light + Glyph = 5% healing
	local SealofLight = GetSpellInfo(20165)
	
	-- Am I slightly crazy for adding level <40 relics? Yes!
	local flashLibrams = {[42615] = 375, [42614] = 331, [42613] = 293, [42612] = 204, [28592] = 89, [25644] = 79, [23006] = 43, [23201] = 28}
	local holyLibrams = {[45436] = 160, [40268] = 141, [28296] = 47}
			
	-- Need the GUID of whoever has beacon on them so we can make sure they are visible to us and so we can check the mapping
	local activeBeaconGUID, hasDivineFavor
	AuraHandler = function(guid, unit)
		if( unitHasAura(unit, BeaconofLight) ) then
			activeBeaconGUID = guid
		elseif( activeBeaconGUID == guid ) then
			activeBeaconGUID = nil
		end
		
		-- Check Divine Favor
		if( unit == "player" ) then
			hasDivineFavor = unitHasAura("player", DivineFavor)
		end
	end
	
	ResetChargeData = function(guid)
		hasDivineFavor = unitHasAura("player", DivineFavor)
	end

	-- Check for beacon when figuring out who to heal
	GetHealTargets = function(guid, healAmount, spellName, spellRank)
		if( activeBeaconGUID and activeBeaconGUID ~= guid and guidToUnit[activeBeaconGUID] and UnitIsVisible(guidToUnit[activeBeaconGUID]) ) then
			return string.format("%s,%s", compressGUID[guid], compressGUID[activeBeaconGUID]), healAmount
		end
		
		return compressGUID[guid], healAmount
	end

	-- If only every other class was as easy as Paladins
	CalculateHealing = function(guid, spellName, spellRank)
		local healAmount = HealComm.averageHeal[spellName .. spellRank]
		local spellPower = GetSpellBonusHealing()
		local multiModifier, addModifier = 1, 1
		local rank = HealComm.rankNumbers[spellRank]
		
		-- Glyph of Seal of Light, +5% healing if the player has Seal of Light up
		if( glyphCache[54943] and unitHasAura("player", SealofLight) ) then
			multiModifier = multiModifier * 1.05
		end
		
		addModifier = addModifier + talentData[Divinity].current
		multiModifier = multiModifier * (1 + talentData[Divinity].current)
		
		multiModifier = multiModifier * (1 + talentData[HealingLight].current)
		
		-- Apply extra spell power based on libram
		if( playerCurrentRelic ) then
			if( spellName == HolyLight and holyLibrams[playerCurrentRelic] ) then
				spellPower = spellPower + holyLibrams[playerCurrentRelic]
			elseif( spellName == FlashofLight and flashLibrams[playerCurrentRelic] ) then
				spellPower = spellPower + flashLibrams[playerCurrentRelic]
			end
		end
		
		-- Normal calculations
		spellPower = spellPower * (spellData[spellName].coeff * 1.88)
		
		healAmount = calculateGeneralAmount(spellData[spellName][rank], healAmount, spellPower, multiModifier, addModifier)

		-- Divine Favor, 100% chance to crit
		if( hasDivineFavor ) then
			hasDivineFavor = nil
			healAmount = healAmount * (1.50 + talentData[TouchedbytheLight].current)
		-- Or the player has over a 100% chance to crit with Holy spells
		elseif( GetSpellCritChance(2) >= 100 ) then
			healAmount = healAmount * (1.50 + talentData[TouchedbytheLight].current)
		end
		
		return DIRECT_HEALS, math.ceil(healAmount * playerHealModifier)
	end
end

-- PRIESTS
-- Accurate as of 3.2.2 (build 10257)
local function loadPriestData()
	-- Spell data
	local GreaterHeal = GetSpellInfo(2060)
	spellData[GreaterHeal] = {40, 46, 52, 58, 60, 63, 68, 73, 78, coeff = 3 / 3.5}
	local PrayerofHealing = GetSpellInfo(596)
	spellData[PrayerofHealing] = {30, 40, 50, 60, 60, 68, 76, coeff = 0.2798}
	local FlashHeal = GetSpellInfo(2061)
	spellData[FlashHeal] = {20, 26, 32, 38, 44, 52, 58, 61, 67, 73, 79, coeff = 1.5 / 3.5}
	local BindingHeal = GetSpellInfo(32546)
	spellData[BindingHeal] = {64, 72, 78, coeff = 1.5 / 3.5}
	local Penance = GetSpellInfo(53007)
	spellData[Penance] = {60, 70, 75, 80, coeff = 0.857, ticks = 3}
	local Heal = GetSpellInfo(2054)
	spellData[Heal] = {16, 22, 28, 34, coeff = 3 / 3.5}
	local LesserHeal = GetSpellInfo(2050)
	spellData[LesserHeal] = {1, 4, 20}
	
	-- Talent data
	local Grace = GetSpellInfo(47517)
	-- Spiritual Healing (Add)
	local SpiritualHealing = GetSpellInfo(14898)
	talentData[SpiritualHealing] = {mod = 0.02, current = 0}
	-- Empowered Healing (Add, also 0.04 for FH/BH)
	local EmpoweredHealing = GetSpellInfo(33158)
	talentData[EmpoweredHealing] = {mod = 0.08, current = 0}
	-- Blessed Resilience (Add)
	local BlessedResilience = GetSpellInfo(33142)
	talentData[BlessedResilience] = {mod = 0.01, current = 0}
	-- Focused Power (Add)
	local FocusedPower = GetSpellInfo(33190)
	talentData[FocusedPower] = {mod = 0.02, current = 0}
	-- Divine Providence (Add)
	local DivineProvidence = GetSpellInfo(47567)
	talentData[DivineProvidence] = {mod = 0.02, current = 0}
	
	-- Keep track of who has grace on them
	local activeGraceGUID, activeGraceModifier
	AuraHandler = function(guid, unit)
		local stack, _, _, _, caster = select(4, UnitBuff(unit, Grace))
		if( caster == "player" ) then
			activeGraceModifier = stack * 0.03
			activeGraceGUID = guid
		elseif( activeGraceGUID == guid ) then
			activeGraceGUID = nil
		end
	end
	
	-- Check for beacon when figuring out who to heal
	GetHealTargets = function(guid, healAmount, spellName, spellRank)
		if( spellName == BindingHeal ) then
			return string.format("%s,%s", compressGUID[guid], compressGUID[playerGUID]), healAmount
		elseif( spellName == PrayerofHealing ) then
			local list = compressGUID[guid]
			
			local group = guidToGroup[guid]
			for groupGUID, id in pairs(guidToGroup) do
				if( guid ~= groupGUID and UnitIsVisible(guidToUnit[groupGUID]) ) then
					list = list .. "," .. compressGUID[groupGUID]
				end
			end
			
			return list, healAmount
		end
		
		return compressGUID[guid], healAmount
	end
	
	-- If only every other class was as easy as Paladins
	CalculateHealing = function(guid, spellName, spellRank)
		local healAmount = HealComm.averageHeal[spellName .. spellRank]
		local rank = HealComm.rankNumbers[spellRank]
		local spellPower = GetSpellBonusHealing()
		local multiModifier, addModifier = 1, 1
		
		-- Add grace if it's active on them
		if( activeGraceGUID == guid ) then
			addModifier = addModifier + activeGraceModifier
		end
		
		addModifier = addModifier + talentData[FocusedPower].current
		addModifier = addModifier + talentData[BlessedResilience].current
		multiModifier = multiModifier * (1 + talentData[SpiritualHealing].current)
		
		-- Greater Heal
		if( spellName == GreaterHeal ) then
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) * (1 + talentData[EmpoweredHealing].current))
		-- Flash Heal
		elseif( spellName == FlashHeal ) then
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) * (1 + talentData[EmpoweredHealing].spent * 0.04))
		-- Binding Heal
		elseif( spellName == BindingHeal ) then
			multiModifier = multiModifier * (1 + talentData[DivineProvidence].current)
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) * (1 + talentData[EmpoweredHealing].spent * 0.04))
		-- Penance
		elseif( spellName == Penance ) then
			spellPower = spellPower * (spellData[spellName].coeff * 1.88)
			spellPower = spellPower / spellData[spellName].ticks
		-- Prayer of Heaing
		elseif( spellName == PrayerofHealing ) then
			multiModifier = multiModifier * (1 + talentData[DivineProvidence].current)
			spellPower = spellPower * (spellData[spellName].coeff * 1.88)
		-- Heal
		elseif( spellName == Heal ) then
			spellPower = spellPower * (spellData[spellName].coeff * 1.88)
		-- Lesser Heal
		elseif( spellName == LesserHeal ) then
			local castTime = rank > 3 and 2.5 or rank == 2 and 2 or 1.5
			spellPower = spellPower * ((castTime / 3.5) * 1.88)
		end
		
		healAmount = calculateGeneralAmount(spellData[spellName][rank], healAmount, spellPower, multiModifier, addModifier)

		-- Player has over a 100% chance to crit with Holy spells
		if( GetSpellCritChance(2) >= 100 ) then
			healAmount = healAmount * 1.50
		end
		
		-- Apply the final modifier of any MS or self heal increasing effects
		healAmount = math.ceil(healAmount * playerHealModifier)
		
		-- Penance ticks 3 times, but the first one is instant and as it will land before the comm get there, pretend that
		-- it only has two ticks.
		if( spellName == Penance ) then
			return CHANNEL_HEALS, healAmount, 2
		end
				
		return DIRECT_HEALS, healAmount
	end
end

-- SHAMANS
-- All spells accurate as of 3.2.2 (build 10257)
-- Chain Heal with Riptide is about ~300 off though, everything else is spot on.
local function loadShamanData()
	-- Spell data
	local ChainHeal = GetSpellInfo(1064)
	spellData[ChainHeal] = {40, 46, 54, 61, 68, 74, 80, coeff = 2.5 / 3.5}
	local HealingWave = GetSpellInfo(331)
	spellData[HealingWave] = {1, 6, 12, 18, 24, 32, 40, 48, 56, 60, 63, 70, 75, 80}
	local LesserHealingWave = GetSpellInfo(8004)
	spellData[LesserHealingWave] = {20, 28, 36, 44, 52, 60, 66, 72, 77, coeff = 1.5 / 3.5}
	
	-- Talent data
	local Riptide = GetSpellInfo(61295)
	local EarthShield = GetSpellInfo(49284)
	-- Improved Chain Heal (Multi)
	local ImpChainHeal = GetSpellInfo(30872)
	talentData[ImpChainHeal] = {mod = 0.10, current = 0}
	-- Tidal Waves (Add, this is a buff)
	local TidalWaves = GetSpellInfo(51566)
	talentData[TidalWaves] = {mod = 0.04, current = 0}
	-- Healing Way (Multi, this goes from 8 -> 16 -> 25 so have to manually do the conversion)
	local HealingWay = GetSpellInfo(29206)
	talentData[HealingWay] = {mod = 0, current = 0}
	-- Purification (Add/Multi)
	local Purification = GetSpellInfo(16178)
	talentData[Purification] = {mod = 0.02, current = 0}
	
	-- Set bonuses
	-- T7 Resto 4 piece, +5% healing on Chain Heal and Healing Wave
	itemSetsData["T7 Resto"] = {40508, 40509, 40510, 40512, 40513, 39583, 39588, 39589, 39590, 39591}
	
	-- Totems
	local lhwTotems = {[42598] = 320, [42597] = 267, [42596] = 236, [42595] = 204, [25645] = 79, [22396] = 80, [23200] = 53}	
	baseHealingRelics = {[45114] = ChainHeal, [38368] = ChainHeal, [28523] = ChainHeal}
	
	-- Keep track of who has riptide on them
	local riptideData, earthshieldGUID = {}
	AuraHandler = function(guid, unit)
		riptideData[guid] = unitHasAura(unit, Riptide) and true or nil
		
		-- Currently, Glyph of Lesser Healing Wave + Any Earth Shield increase the healing
		-- not just the players
		--if( unitHasAura(unit, EarthShield) ) then
		if( UnitBuff(unit, EarthShield) ) then
			earthshieldGUID = guid
		elseif( earthshieldGUID ) then
			earthshieldGUID = nil
		end
	end
	
	-- Cast was interrupted, recheck if we still have the auras up
	ResetChargeData = function(guid)
		riptideData[guid] = unitHasAura(guidToUnit[guid], Riptide) and true or nil
	end
	
	-- Lets a specific override on how many people this will hit
	GetHealTargets = function(guid, healAmount, spellName, spellRank)
		-- Glyph of Healing Wave, heals you for 20% of your heal when you heal someone else
		if( glyphCache[55551] and guid ~= playerGUID and spellName == HealingWave ) then
			return string.format("%s,%d,%s,%d", compressGUID[guid], healAmount, compressGUID[playerGUID], healAmount *  0.20)
		end
	
		return compressGUID[guid], healAmount
	end
	
	-- If only every other class was as easy as Paladins
	CalculateHealing = function(guid, spellName, spellRank)
		local healAmount = HealComm.averageHeal[spellName .. spellRank]
		local rank = HealComm.rankNumbers[spellRank]
		local spellPower = GetSpellBonusHealing()
		local multiModifier, addModifier = 1, 1
		
		addModifier = addModifier + talentData[Purification].current
		
		-- Chain Heal
		if( spellName == ChainHeal ) then
			multiModifier = multiModifier * (1 + talentData[ImpChainHeal].current)
			
			if( equippedSetPieces["T7 Resto"] >= 4 ) then
				multiModifier = multiModifier * 1.05
			end

			-- Add +25% from Riptide being up and reset the flag
			if( riptideData[guid] ) then
				multiModifier = multiModifier * 1.25
				riptideData[guid] = nil
			end
			
			spellPower = spellPower * (spellData[spellName].coeff * 1.88)
		-- Heaing Wave
		elseif( spellName == HealingWave ) then
			multiModifier = multiModifier * (talentData[HealingWay].spent == 3 and 1.25 or talentData[HealingWay].spent == 2 and 1.16 or talentData[HealingWay].spent == 1 and 1.08 or 1)
			
			--/dump 1.10 * 4062.5 + ((2178 * 1.8114) * 1) * 1.375
			if( equippedSetPieces["T7 Resto"] >= 4 ) then
				multiModifier = multiModifier * 1.05
			end
						
			-- Totem of Spontaneous Regrowth, +88 Spell Power to Healing Wave
			if( playerCurrentRelic == 27544 ) then
				spellPower = spellPower + 88
			end
			
			local castTime = rank > 3 and 3 or rank == 3 and 2.5 or rank == 2 and 2 or 1.5
			spellPower = spellPower * (((castTime / 3.5) * 1.88) + talentData[TidalWaves].current)
						
		-- Lesser Healing Wave
		elseif( spellName == LesserHealingWave ) then
			-- Glyph of Lesser Healing Wave, +20% healing on LHW if target has ES up
			if( glyphCache[55438] and earthshieldGUID == guid ) then
				multiModifier = multiModifier * 1.20
			end
			
			-- Lesser Healing Wave spell power modifing totems
			if( playerCurrentRelic and lhwTotems[playerCurrentRelic] ) then
				spellPower = spellPower + lhwTotems[playerCurrentRelic]
			end
			
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) + talentData[TidalWaves].spent * 0.02)
		end
		
		healAmount = calculateGeneralAmount(spellData[spellName][rank], healAmount, spellPower, multiModifier, addModifier)

		-- Player has over a 100% chance to crit with Nature spells
		if( GetSpellCritChance(4) >= 100 ) then
			healAmount = healAmount * 1.50
		end
		
		-- Apply the final modifier of any MS or self heal increasing effects
		healAmount = math.ceil(healAmount * playerHealModifier)
		return DIRECT_HEALS, healAmount
	end
end

-- Healing modifiers
HealComm.currentModifiers = HealComm.currentModifiers or {}

HealComm.selfModifiers = HealComm.selfModifiers or {
	[64850] = 0.50, -- Unrelenting Assault
	[65925] = 0.50, -- Unrelenting Assault
	[54428] = 0.50, -- Divine Plea
	[64849] = 0.75, -- Unrelenting Assault
	[31884] = 1.20, -- Avenging Wrath
}

local function getName(spellID)
	local name = GetSpellInfo(spellID)
	--@debug@
	if( not name ) then
		print(string.format("%s-r%s: Failed to find spellID %d", major, minor, spellID))
	end
	--@end-debug@
	return name or ""
end

-- There is one spell currently that has a name conflict, which is ray of Pain from the Void Walkers in Nagrand
-- if it turns out there are more later on (which is doubtful) I'll change it
HealComm.healingModifiers = HealComm.healingModifiers or {
	[getName(30843)] = 0.00, -- Enfeeble
	[getName(41292)] = 0.00, -- Aura of Suffering
	[getName(59513)] = 0.00, -- Embrace of the Vampyr
	[getName(55593)] = 0.00, -- Necrotic Aura
	[getName(34625)] = 0.25, -- Demolish
	[getName(34366)] = 0.25, -- Ebon Poison
	[getName(19716)] = 0.25, -- Gehennas' Curse
	[getName(24674)] = 0.25, -- Veil of Shadow
	-- Despite the fact that Wound Poison uses the same 50% now, it's a unique spellID and buff name for each rank
	[getName(13218)] = 0.50, -- 1
	[getName(13222)] = 0.50, -- 2
	[getName(13223)] = 0.50, -- 3
	[getName(13224)] = 0.50, -- 4
	[getName(27189)] = 0.50, -- 5
	[getName(57974)] = 0.50, -- 6
	[getName(57975)] = 0.50, -- 7
	[getName(20900)] = 0.50, -- Aimed Shot
	[getName(21551)] = 0.50, -- Mortal Strike
	[getName(40599)] = 0.50, -- Arcing Smash
	[getName(36917)] = 0.50, -- Magma-Throwser's Curse
	[getName(23169)] = 0.50, -- Brood Affliction: Green
	[getName(22859)] = 0.50, -- Mortal Cleave
	[getName(36023)] = 0.50, -- Deathblow
	[getName(13583)] = 0.50, -- Curse of the Deadwood
	[getName(32378)] = 0.50, -- Filet
	[getName(35189)] = 0.50, -- Solar Strike
	[getName(32315)] = 0.50, -- Soul Strike
	[getName(60084)] = 0.50, -- The Veil of Shadow
	[getName(45885)] = 0.50, -- Shadow Spike
	[getName(63038)] = 0.75, -- Dark Volley
	[getName(52771)] = 0.75, -- Wounding Strike
	[getName(48291)] = 0.75, -- Fetid Healing
	[getName(54525)] = 0.80, -- Shroud of Darkness (This might be wrong)
	[getName(48301)] = 0.80, -- Mind Trauma (Improved Mind Blast)
	[getName(68391)] = 0.80, -- Permafrost, the debuff is generic no way of seeing 7/13/20, go with 20
	[getName(34073)] = 0.85, -- Curse of the Bleeding Hollow
	[getName(43410)] = 0.90, -- Chop
	[getName(34123)] = 1.06, -- Tree of Life
	[getName(64844)] = 1.10, -- Divine Hymn
	[getName(47788)] = 1.40, -- Guardian Spirit
	[getName(38387)] = 1.50, -- Bane of Infinity
	[getName(31977)] = 1.50, -- Curse of Infinity
	[getName(41350)] = 2.00, -- Aura of Desire
}

-- Easier to toss functions on 4 extra functions than add extra checks
HealComm.healingStackMods = HealComm.healingStackMods or {
	-- Tenacity
	[getName(58549)] = function(name, rank, icon, stacks) return icon == "Interface\\Icons\\Ability_Warrior_StrengthOfArms" and stacks ^ 1.18 or 1 end,
	-- Focused Will
	[getName(45242)] = function(name, rank, icon, stacks) return 1 + (stacks * (0.02 + rankNumbers[rank])) end,
	-- Nether Portal - Dominance
	[getName(30423)] = function(name, rank, icon, stacks) return 1 + stacks * 0.01 end,
	-- Dark Touched
	[getName(45347)] = function(name, rank, icon, stacks) return 1 - stacks * 0.04 end, 
	-- Necrotic Strike
	[getName(60626)] = function(name, rank, icon, stacks) return 1 - stacks * 0.10 end, 
	-- Mortal Wound
	[getName(28467)] = function(name, rank, icon, stacks) return 1 - stacks * 0.10 end, 
}

local healingStackMods, selfModifiers = HealComm.healingStackMods, HealComm.selfModifiers
local healingModifiers, currentModifiers = HealComm.healingModifiers, HealComm.currentModifiers

local distribution
local function sendMessage(msg)
	if( distribution ) then
		SendAddonMessage(COMM_PREFIX, msg, distribution)
	end
end

-- Keep track of where all the data should be going
local instanceType
local function updateDistributionChannel()
	local lastChannel = distribution
	if( instanceType == "pvp" or instanceType == "arena" ) then
		distribution = "BATTLEGROUND"
	elseif( GetNumRaidMembers() > 0 ) then
		distribution = "RAID"
	elseif( GetNumPartyMembers() > 0 ) then
		distribution = "PARTY"
	else
		distribution = nil
	end
	
	-- If they aren't a healer we don't need to listen to these events all the time
	if( not isHealerClass and distribution ~= lastChannel ) then
		if( distribution ) then
			HealComm.frame:RegisterEvent("CHAT_MSG_ADDON")
			HealComm.frame:RegisterEvent("UNIT_AURA")
			HealComm.frame:RegisterEvent("UNIT_SPELLCAST_DELAYED")
			HealComm.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
			HealComm.frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
		else
			HealComm.frame:UnregisterEvent("CHAT_MSG_ADDON")
			HealComm.frame:UnregisterEvent("UNIT_AURA")
			HealComm.frame:UnregisterEvent("UNIT_SPELLCAST_DELAYED")
			HealComm.frame:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
			HealComm.frame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
		end
	end
end

-- Figure out where we should be sending messages and wipe some caches
function HealComm:ZONE_CHANGED_NEW_AREA()
	local type = select(2, IsInInstance())
	if( type ~= instanceType ) then
		instanceType = type
		
		updateDistributionChannel()
		
		-- Check and remove any expired events, in reality I should start to fire a "player healing might have updated" event too
		local time = GetTime()
		for _, spellList in pairs(self.pendingHeals) do
			for _, spell in pairs(spellList) do
				for i=#(spell), 1, -3 do
					if( spell[i] <= time ) then
						table.remove(spell, i)
						table.remove(spell, i - 1)
						table.remove(spell, i - 2)
					end
				end
			end
		end
		
		-- Changes the value of Necrotic Poison based on zone type, if there are more difficulty type MS's I'll support those too
		-- Heroic = 90%, Non-Heroic = 75%
		if( GetRaidDifficulty() == 2 or GetRaidDifficulty() == 4 ) then
			healingModifiers[GetSpellInfo(53121)] = 0.25
		else
			healingModifiers[GetSpellInfo(53121)] = 0.10
		end
	end

	instanceType = type
end

-- Figure out the modifier for the players healing in general
-- Because Unrelenting Assault can be applied while casting, it should probably fire a heal changed if modifier changes
-- while a cast is going on
local function recalculatePlayerModifiers()
	local increase, decrease = 1, 1
	for _, modifier in pairs(playerModifiers) do
		if( modifier >= 1 ) then
			increase = increase * modifier
		else
			decrease = math.min(decrease, modifier)
		end
	end
	
	playerHealModifier = increase * decrease
end

-- This solution bugs me a ton, I don't like having to do aura checks in UNIT_AURA it's rather wasteful
-- pure CLEU isn't a good solution due to ranged issues, going to have to come a hybrid system I think. But as modifiers are local
-- it's not something that will hugely affect the library either way as any change won't cause compatibility issues.
-- on the other hand, I hate having to keep a table for every single GUID we are tracking.
local alreadyAdded = {}
function HealComm:UNIT_AURA(unit)
	if( not UnitIsPlayer(unit) or ( unit ~= "player" and not UnitPlayerOrPetInParty(unit) and not UnitPlayerOrPetInRaid(unit) ) ) then return end
	local guid = UnitGUID(unit)
	local increase, decrease = 1, 1
	
	-- Scan buffs
	local id = 1
	while( true ) do
		local name, rank, icon, stack = UnitAura(unit, id, "HELPFUL")
		if( not name ) then break end
		-- Don't want to calculate a modifier twice, like ToL will show be extra 1.06 for Druids in TOL
		if( not alreadyAdded[name] ) then
			if( healingModifiers[name] ) then
				increase = increase * healingModifiers[name]
			elseif( healingStackMods[name] ) then
				increase = increase * healingStackMods[name](name, rank, icon, stack)
			end
			
			alreadyAdded[name] = true
		end
		
		id = id + 1
	end

	-- Scan debuffs
	id = 1
	while( true ) do
		local name, rank, icon, stack = UnitAura(unit, id, "HARMFUL")
		if( not name ) then break end
		if( healingModifiers[name] ) then
			decrease = math.min(decrease, healingModifiers[name])
		elseif( healingStackMods[name] ) then
			decrease = math.min(decrease, healingStackMods[name](name, rank, icon, stack))
		end
		
		id = id + 1
	end
	
	-- Check if modifier changed
	local modifier = increase * decrease
	if( modifier ~= currentModifiers[guid] ) then
		if( currentModifiers[guid] or modifier ~= 1 ) then
			currentModifiers[guid] = modifier
			self.callbacks:Fire("HealComm_ModifierChanged", guid, modifier)
		else
			currentModifiers[guid] = modifier
		end
	end

	table.wipe(alreadyAdded)
	
	-- Class has a specific monitor it needs for auras
	if( AuraHandler ) then
		AuraHandler(guid, unit)
	end
end

-- Monitor glyph changes
function HealComm:GlyphsUpdated(id)
	local spellID = glyphCache[id]
	
	-- Invalidate the old cache value
	if( spellID ) then
		glyphCache[spellID] = nil
		glyphCache[id] = nil
	end
	
	-- Cache the new one if any
	local enabled, _, glyphID = GetGlyphSocketInfo(id)
	if( enabled and glyphID ) then
		glyphCache[glyphID] = true
		glyphCache[id] = glyphID
	end
end

-- Unfortunately, the healing numbers are generally modified based off of spell power and such
-- so any respec and they have to all be wiped and recached. There also seems to be some consistency issues
-- with when LEARNED_SPELL_IN_TAB or the other events fire at that, so go with SPELLS_CHANGED but throttle it.
local changedThrottle = 0
function HealComm:SPELLS_CHANGED()
	if( changedThrottle < GetTime() ) then
		changedThrottle = GetTime() + 2
		table.wipe(averageHeal)
	end
end

-- Cache player talent data for spells we need
function HealComm:PLAYER_TALENT_UPDATE()
	for tabIndex=1, GetNumTalentTabs() do
		for i=1, GetNumTalents(tabIndex) do
			local name, _, _, _, spent = GetTalentInfo(tabIndex, i)
			if( name and talentData[name] ) then
				talentData[name].current = talentData[name].mod * spent
				talentData[name].spent = spent
			end
		end
	end
end

-- Save the currently equipped range weapon
local RANGED_SLOT = GetInventorySlotInfo("RangedSlot")
function HealComm:PLAYER_EQUIPMENT_CHANGED()
	-- Figure out our set bonus info
	-- As you can't change set bonus data while in combat, don't even do the check
	if( not InCombatLockdown() ) then
		for name, items in pairs(itemSetsData) do
			equippedSetPieces[name] = 0
			for _, itemID in pairs(items) do
				if( IsEquippedItem(itemID) ) then
					equippedSetPieces[name] = equippedSetPieces[name] + 1
				end
			end
		end
	end
	
	-- Check relic
	local previousRelic = playerCurrentRelic
	
	playerCurrentRelic = GetInventoryItemLink("player", RANGED_SLOT)
	if( playerCurrentRelic ) then
		playerCurrentRelic = tonumber(string.match(playerCurrentRelic, "item:(%d+):"))
	end
	
	-- Relics that modify the base healing of a spell modify the tooltip with the new base amount, we can't assume that the tooltip that was cached
	-- is the one with the modified (or unmodified) version so reset the cache and it will get whatever the newest version is.
	if( previousRelic ~= playerCurrentRelic and baseHealingRelics ) then
		local resetSpell = previousRelic and baseHealingRelics[previousRelic] or playerCurrentRelic and baseHealingRelics[playerCurrentRelic]
		if( resetSpell ) then
			for spellName, average in pairs(averageHeal) do
				if( average and string.match(spellName, resetSpell) ) then
					averageHeal[spellName] = nil
				end	
			end
		end
	end
end

-- COMM CODE
local tempPlayerList = {}

-- Direct heal started
local function loadHealList(pending, amount, stack, endTime, ...)
	table.wipe(tempPlayerList)
	
	-- For the sake of consistency, even a heal doesn't have multiple end times like a hot, it'll be treated as such in the DB
	-- The GUID -> time hash map is meant as a way of speeding up "Does this person have this heal on them" checks, so you don't
	-- have to do a loop to find it first, mostly for CLEU
	if( amount > 0 ) then
		amount = amount * stack
		
		for i=1, select("#", ...) do
			local guid = decompressGUID[select(i, ...)]
			table.insert(pending, guid)
			table.insert(pending, amount)
			table.insert(pending, endTime)
			table.insert(tempPlayerList, guid)
			
			pending[guid] = endTime
		end
	elseif( amount == -1 ) then
		for i=1, select("#", ...), 2 do
			local guid = decompressGUID[select(i, ...)]
			local amount = tonumber((select(i + 1, ...)))
			if( amount ) then
				table.insert(pending, guid)
				table.insert(pending, amount * stack)
				table.insert(pending, endTime)
				table.insert(tempPlayerList, guid)

				pending[guid] = endTime
			end
		end
	end
end

local function parseDirectHeal(casterGUID, sender, spellID, amount, ...)
	local spellName = GetSpellInfo(spellID)
	if( not casterGUID or not spellName or not amount or select("#", ...) == 0 ) then return end
	
	local endTime = select(6, UnitCastingInfo(sender))
	if( not endTime ) then return end

	pendingHeals[casterGUID] = pendingHeals[casterGUID] or {}
	pendingHeals[casterGUID][spellName] = pendingHeals[casterGUID][spellName] or {}

	local pending = pendingHeals[casterGUID][spellName]
	table.wipe(pending)
	pending.endTime = endTime / 1000
	pending.spellID = spellID
	pending.bitType = DIRECT_HEALS

	loadHealList(pending, amount, 1, 0, ...)
	HealComm.callbacks:Fire("HealComm_HealStarted", casterGUID, spellID, pending.bitType, pending.endTime, unpack(tempPlayerList))
end

-- Channeled heal started
local function parseChannelHeal(casterGUID, sender, spellID, amount, totalTicks, ...)
	local spellName = GetSpellInfo(spellID)
	if( not casterGUID or not spellName or not totalTicks or not amount or select("#", ...) == 0 ) then return end

	local startTime, endTime = select(5, UnitChannelInfo(sender))
	if( not startTime or not endTime ) then return end

	pendingHeals[casterGUID] = pendingHeals[casterGUID] or {}
	pendingHeals[casterGUID][spellID] = pendingHeals[casterGUID][spellID] or {}

	local inc = amount == -1 and 2 or 1
	local pending = pendingHeals[casterGUID][spellID]
	table.wipe(pending)
	pending.startTime = startTime / 1000
	pending.endTime = endTime / 1000
	pending.totalTicks = totalTicks
	pending.tickInterval = (pending.endTime - pending.startTime) / totalTicks
	pending.spellID = spellID
	pending.isMutliTarget = (select("#", ...) / inc) > 1
	pending.bitType = CHANNEL_HEALS
	
	loadHealList(pending, amount, 1, 0, ...)
	
	HealComm.callbacks:Fire("HealComm_HealStarted", casterGUID, spellID, pending.bitType, pending.endTime, unpack(tempPlayerList))
end

-- Hot heal started
-- When the person is within visible range of us, the aura is available by the time the message reaches the target
-- as such, we can rely that at least one person is going to have the aura data on them (and that it won't be different, at least for this cast)
local function findAura(casterGUID, spellName, spellRank, inc, ...)
	for i=1, select("#", ...), inc do
		local guid = decompressGUID[select(i, ...)]
		local unit = guid and guidToUnit[guid]
		if( unit and UnitIsVisible(unit) ) then
			local id = 1
			while( true ) do
				local name, rank, _, stack, _, duration, endTime, caster = UnitBuff(unit, id)
				if( not name ) then break end
				
				if( name == spellName and spellRank == rank and caster and UnitGUID(caster) == casterGUID ) then
					return stack or 1, duration, endTime
				end

				id = id + 1
			end
		end
	end
end

local function parseHotHeal(casterGUID, sender, wasUpdated, spellID, tickAmount, tickInterval, ...)
	local spellName, spellRank = GetSpellInfo(spellID)
	if( not tickAmount or not tickInterval or not spellName or not casterGUID or select("#", ...) == 0 ) then return end
	spellRank = spellRank ~= "" and spellRank or nil
	
	-- Retrieve the hot information
	local inc = amount == -1 and 2 or 1
	local stack, duration, endTime = findAura(casterGUID, spellName, spellRank, inc, ...)
	if( not stack or not duration or not endTime ) then return end
	
	pendingHeals[casterGUID] = pendingHeals[casterGUID] or {}
	pendingHeals[casterGUID][spellID] = pendingHeals[casterGUID][spellID] or {}
	
	local pending = pendingHeals[casterGUID][spellID]
	pending.duration = duration
	pending.endTime = endTime
	pending.stacks = stack > 0 and stack or 1
	pending.totalTicks = duration / tickInterval
	pending.tickInterval = tickInterval
	pending.spellID = spellID
	pending.isMutliTarget = (select("#", ...) / inc) > 1
	pending.bitType = HOT_HEALS
	
	-- Hots will not always fade before being reapplied, and as you can't have the same buff from the same caster
	-- on the same target multiple times, kill any duplicates.
	table.wipe(tempPlayerList)
	
	for i=1, select("#", ...), inc do
		local guid = decompressGUID[select(i, ...)]
		if( pending[guid] ) then
			pending[guid] = nil
			
			for i=#(pending), 1, -3 do
				if( pending[i - 2] == guid ) then
					table.remove(pending, i)
					table.remove(pending, i - 1)
					table.remove(pending, i - 2)
				end
			end
				
			table.insert(tempPlayerList, guid)
		end
	end
	
	
	-- As you can't rely on a hot being the absolutely only one up, have to apply the total amount now :<
	loadHealList(pending, tickAmount, pending.stacks, pending.endTime, ...)
	
	if( not wasUpdated ) then
		HealComm.callbacks:Fire("HealComm_HealStarted", casterGUID, spellID, pending.bitType, pending.endTime, unpack(tempPlayerList))
	else
		HealComm.callbacks:Fire("HealComm_HealUpdated", casterGUID, spellID, pending.bitType, pending.endTime, unpack(tempPlayerList))
	end
end

-- Heal finished
local function parseHealEnd(casterGUID, sender, spellID, interrupted, ...)
	local spellName = GetSpellInfo(spellID)
	if( not casterGUID or not spellName or not pendingHeals[casterGUID] ) then return end
	
	-- Hots/channels should use spellIDs, casts should use spell names. This will keep everything happy for things like Regrowth with a heal and a hot
	local pending = pendingHeals[casterGUID][spellID] or pendingHeals[casterGUID][spellName]
	if( not pending ) then return end
		
	table.wipe(tempPlayerList)
	
	-- Remove all players associated with this
	if( select("#", ...) == 0 ) then
		for i=#(pending), 1, -3 do
			table.remove(pending, i)
			table.remove(pending, i - 1)
			local guid = table.remove(pending, i - 2)
			table.insert(tempPlayerList, guid)
		end
		
	-- Have to remove a specific list of people, only really necessary for hots which can have multiple entries, but different end times
	else
		for i=1, select("#", ...) do
			table.insert(tempPlayerList, decompressGUID[select(i, ...)])
		end
		
		for i=#(pending), 1, -3 do
			for _, guid in pairs(tempPlayerList) do
				if( pending[i - 2] == guid ) then
					table.remove(pending, i)
					table.remove(pending, i - 1)
					table.remove(pending, i - 2)
					
					pending[guid] = nil
				end
			end
		end
	end
		
	-- Double check and make sure we actually removed at least one person
	if( #(tempPlayerList) > 0 ) then
		HealComm.callbacks:Fire("HealComm_HealStopped", casterGUID, spellID, pending.bitType, interrupted, unpack(tempPlayerList))
		
		-- Remove excess data if we have nothing else here
		if( #(pending) == 0 ) then table.wipe(pending) end
	end
end

-- Heal delayed
local function parseHealDelayed(casterGUID, startTime, endTime, spellName)
	local pending = pendingHeals[casterGUID][spellName]
	-- It's possible to get duplicate interrupted due to raid1 = party1, player = raid# etc etc, just block it here
	if( pending.endTime == endTime and pending.startTime == startTime ) then return end
	
	-- Casted heal
	if( pending.bitType == DIRECT_HEALS ) then
		pending.startTime = startTime
		pending.endTime = endTime
	-- Channel heal
	elseif( pending.bitType == CHANNEL_HEALS ) then
		pending.startTime = startTime
		pending.endTime = endTime
		pending.tickInterval = (pending.endTime - pending.startTime)
	else
		return
	end

	table.wipe(tempPlayerList)

	for i=1, #(pending), 3 do
		table.insert(tempPlayerList, pending[i])
	end

	HealComm.callbacks:Fire("HealComm_HealDelayed", casterGUID, pending.spellID, pending.bitType, pending.endTime, unpack(tempPlayerList))
end

--[[
-- DEBUG
local Test = {}
function Test:Dump(...)
	print(...)
end

HealComm.RegisterCallback(Test, "HealComm_HealStarted", "Dump")
HealComm.RegisterCallback(Test, "HealComm_HealDelayed", "Dump")
HealComm.RegisterCallback(Test, "HealComm_HealUpdated", "Dump")
HealComm.RegisterCallback(Test, "HealComm_HealStopped", "Dump")
HealComm.RegisterCallback(Test, "HealComm_ModifierChanged", "Dump")
]]

-- After checking around 150-200 messages in battlegrounds, server seems to always be passed (if they are from another server)
-- so the casterGUID isn't needed to be sent, I'll keep it around in case it does, but it also gives expansion potentional without breaking compatibility
-- The reason channels use tick total and hots use tick interval, is because channels have their total channel time modified by haste but the ticks are not increased via talents
-- whereas hots have talents to modify duration but not tick frequency
function HealComm:CHAT_MSG_ADDON(prefix, message, channel, sender)
	-- Reject any comm in a distribution we aren't watching
	if( prefix ~= COMM_PREFIX or channel ~= distribution or sender == playerName ) then return end
	
	local commType, _, spellID, arg1, arg2, arg3, arg4, arg5 = string.split(":", message)
	spellID = tonumber(spellID)
	if( not commType or not spellID ) then return end
	
	--- New direct heal - D:<extra>:<spellID>:<amount>:target1,target2,target3,target4,etc
	if( commType == "D" and arg1 and arg2 ) then
		parseDirectHeal(UnitGUID(sender), sender, spellID, tonumber(arg1), string.split(",", arg2))
	--- New channel heal - C:<extra>:<spellID>:<amount>:<tickTotal>:target1,target2,target3,target4,etc
	elseif( commType == "C" and arg1 and arg3 ) then
		parseChannelHeal(UnitGUID(sender), sender, spellID, tonumber(arg1), tonumber(arg2), string.split(",", arg3))
	--- New hot - H:<extra>:<spellID>:<amount>:<isMulti>:<tickInterval>:target1,target2,target3,target4,etc
	elseif( commType == "H" and arg1 and arg5 ) then
		parseHotHeal(UnitGUID(sender), sender, false, spellID, tonumber(arg1), tonumber(arg3), tonumber(arg4), string.split(",", arg5))
	--- New updated heal somehow before ending - H:<extra>:<spellID>:<amount>:<tickInterval>:target1,target2,target3,target4,etc
	elseif( commtype == "U" and arg1 and arg4 ) then
		parseHotHeal(UnitGUID(sender), sender, true, spellID, tonumber(arg1), tonumber(arg2), tonumber(arg3), string.split(",", arg4))
	--- Heal stopped - S:<extra>:<spellID>:<ended early>:target1,target2,target3,target4,etc
	elseif( commType == "S" ) then
		local interrupted = arg1 == "1" and true or false
		if( arg2 and arg2 ~= "" ) then
			parseHealEnd(UnitGUID(sender), sender, spellID, interrupted, string.split(",", arg2))
		else
			parseHealEnd(UnitGUID(sender), sender, spellID, interrupted)
		end
	end
end


-- Monitor aura changes as well as new hots being cast
local COMBATLOG_OBJECT_AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE
local CAN_HEAL = bit.bor(COMBATLOG_OBJECT_REACTION_FRIENDLY, COMBATLOG_OBJECT_REACTION_NEUTRAL)

local eventRegistered = {["SPELL_HEAL"] = true, ["SPELL_PERIODIC_HEAL"] = true}
if( isHealerClass ) then
	eventRegistered["SPELL_AURA_REMOVED"] = true
	eventRegistered["SPELL_AURA_APPLIED"] = true
	eventRegistered["SPELL_CAST_SUCCESS"] = true
end

-- Some heals like Tranquility hit multiple people, and firing 5 events * ticks is inefficient, instead if we expect them
-- to be hitting multiple people they'll be saved until the next frame update
HealComm.bucketHeals = HealComm.bucketHeals or {}
local bucketHeals = HealComm.bucketHeals

HealComm.bucketFrame = HealComm.bucketFrame or CreateFrame("Frame")
HealComm.bucketFrame:SetScript("OnUpdate", function(self, elapsed)
	self:Hide()
	
	for casterGUID, spells in pairs(bucketHeals) do
		for spellID, targetGUIDs in pairs(spells) do
			if( #(targetGUIDs) > 0 ) then
				local pending = bucketHeals[sourceGUID][spellID]
				HealComm.callbacks:Fire("HealComm_HealUpdated", casterGUID, spellID, pending.bitType, pending[targetGUIDs[1]], unpack(targetGUIDs))
				
				table.wipe(targetGUIDs)
			end
		end
	end
end)	

function HealComm:COMBAT_LOG_EVENT_UNFILTERED(timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, ...)
	if( not eventRegistered[eventType] ) then return end
	
	-- Heal or hot ticked that we have data on
	if( eventType == "SPELL_HEAL" or eventType == "SPELL_PERIODIC_HEAL" ) then
		local spellID = ...
		local pending = sourceGUID and pendingHeals[sourceGUID] and pendingHeals[sourceGUID][spellID]
		if( pending and pending[destGUID] ) then
			if( pending.isMultiTarget ) then
				bucketHeals[sourceGUID] = bucketHeals[sourceGUID] or {}
				bucketHeals[sourceGUID][spellID] = bucketHeals[sourceGUID][spellID] or {}
				table.insert(bucketHeals[sourceGUID][spellID], destGUID)
				
				self.bucketFrame:Show()
			else
				HealComm.callbacks:Fire("HealComm_HealUpdated", sourceGUID, spellID, pending.bitType, pending[destGUID], destGUID)
			end
		end
	-- Cast succesful
	elseif( eventType == "SPELL_CAST_SUCCESS" and bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) == COMBATLOG_OBJECT_AFFILIATION_MINE and bit.band(destFlags, CAN_HEAL) > 0 ) then
		local spellID, spellName, spellSchool = ...
		if( hotData[spellName] ) then
			local type, amount, tickInterval = CalculateHotHealing(destGUID, spellID)
			local targets, amount = GetHealTargets(sourceGUID, math.max(amount, 0), spellName, spellRank)
			amount = amount or -1
			
			parseHotHeal(sourceGUID, sourceName, false, spellID, amount, tickInterval, string.split(",", targets))
			sendMessage(string.format("H::%d::%d:%d:%s", spellID, amount, tickInterval, targets))
		end
	-- Aura applied
	elseif( eventType == "SPELL_AURA_APPLIED" and bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) == COMBATLOG_OBJECT_AFFILIATION_MINE ) then
		local spellID, spellName, spellSchool, auraType = ...
		if( selfModifiers[spellID] ) then
			playerModifiers[spellID] = selfModifiers[spellID]
			recalculatePlayerModifiers()
		end
	-- Aura faded		
	elseif( eventType == "SPELL_AURA_REMOVED" ) then
		local spellID, spellName, spellSchool, auraType = ...
		
		-- It was applied to the player so it might be a modifierhopthal
		if( playerModifiers[spellID] and bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) == COMBATLOG_OBJECT_AFFILIATION_MINE ) then
			playerModifiers[spellID] = nil
			recalculatePlayerModifiers()
		end
		
		-- Hot faded that we cast 
		if( hotData[spellName] and bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) == COMBATLOG_OBJECT_AFFILIATION_MINE ) then
			parseHealEnd(sourceGUID, sourceName, spellID, false, compressGUID[destGUID])
			sendMessage(string.format("S::%d::%s", spellID, compressGUID[destGUID]))
		end
	end
end

-- Spell cast magic
-- When auto self cast is on, the UNIT_SPELLCAST_SENT event will always come first followed by the funciton calls
-- Otherwise either SENT comes first then function calls, or some function calls then SENT then more function calls
local castTarget, castID, mouseoverGUID, mouseoverName, hadTargetingCursor, lastSentID, lastTargetGUID, lastTargetName
local lastFriendlyGUID, lastFriendlyName, lastGUID, lastName, lastIsFriend
local castGUIDs, guidPriorities = {}, {}

local function stripServer(name)
	return string.gsub(name, "(.-)%-(.*)$", "%1")
end

-- Deals with the fact that functions are called differently
-- Why a table when you can only cast one spell at a time you ask? When you factor in lag and mash clicking it's possible to
-- cast A, interrupt it, cast B and have A fire SUCEEDED before B does, this prevents data from being messed up that way.
local function setCastData(priority, name, guid)
	if( not guid or not lastSentID ) then return end
	if( guidPriorities[lastSentID] and guidPriorities[lastSentID] >= priority ) then return end
	
	-- This is meant as a way of locking a cast in because which function has accurate data can be called into question at times, one of them always does though
	-- this means that as soon as it finds a name match it locks the GUID in until another SENT is fired. Technically it's possible to get a bad GUID but it first requires
	-- the functions to return different data and it requires the messed up call to be for another name conflict.
	if( castTarget and castTarget == name ) then priority = 99 end
	
	castGUIDs[lastSentID] = guid
	guidPriorities[lastSentID] = priority
end

-- When the game tries to figure out the UnitID from the name it will prioritize players over non-players
-- if there are conflicts in names it will pull the one with the least amount of current health

-- This would be another way of getting GUIDs, by keeping a map and marking conflicts due to pets (or vehicles)
-- we would know that you can't rely on the name exactly and that the other methods are needed. While they seem
-- to be accurate and not have any issues, it could be a good solution as a better safe than sorry option.
function HealComm:UNIT_SPELLCAST_SENT(unit, spellName, spellRank, castOn)
	if( unit ~= "player" or not spellData[spellName] or not averageHeal[spellName .. spellRank] ) then return end
	
	castTarget = stripServer(castOn)
	lastSentID = spellName .. spellRank
	
	-- Self cast is off which means it's possible to have a spell waiting for a target.
	-- It's possible that it's the mouseover unit, but if we see a *TargetUnit call then we know it's that unit for sure
	if( hadTargetingCursor ) then
		hadTargetingCursor = nil
		self.resetFrame:Show()
		
		guidPriorities[lastSentID] = nil
		setCastData(5, mouseoverName, mouseoverGUID)
	else
		guidPriorities[lastSentID] = nil
		setCastData(0, nil, UnitGUID(castOn))
	end
end

function HealComm:UNIT_SPELLCAST_START(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or not averageHeal[spellName .. spellRank] ) then return end
	local nameID = spellName .. spellRank
	local castGUID = castGUIDs[nameID]
	
	-- Figure out who we are healing and for how much
	local type, amount, ticks = CalculateHealing(castGUID, spellName, spellRank)
	local targets, amount = GetHealTargets(castGUID, math.max(amount, 0), spellName, spellRank)
	
	castID = id
	-- No amount provided means grab amount from the people being healed
	amount = amount or -1
	
	--- D:<casterID>:<spellID>:<amount>:target1,target2,target3,target4,etc
	if( type == DIRECT_HEALS ) then
		parseDirectHeal(playerGUID, playerName, self.spellToID[nameID], amount, string.split(",", targets))
		sendMessage(string.format("D::%d:%d:%s", self.spellToID[nameID] or 0, amount or "", targets))
	--- C:<casterID>:<spellID>:<amount>:<tickTotal>:target1,target2,target3,target4,etc
	elseif( type == CHANNEL_HEALS ) then
		parseChannelHeal(playerGUID, playerName, self.spellToID[nameID], amount, ticks, string.split(",", targets))
		sendMessage(string.format("C::%d:%d:%s:%s", self.spellToID[nameID] or 0, amount, ticks, targets))
	end
end

function HealComm:UNIT_SPELLCAST_CHANNEL_START(...)
	self:UNIT_SPELLCAST_START(...)
end

function HealComm:UNIT_SPELLCAST_SUCCEEDED(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or id ~= castID or id == 0 ) then return end
	local nameID = spellName .. spellRank

	castID = nil

	sendMessage(string.format("S::%d:0", self.spellToID[nameID] or 0))
	parseHealEnd(playerGUID, playerName, self.spellToID[nameID], false)
end

function HealComm:UNIT_SPELLCAST_STOP(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or id ~= castID ) then return end
	local nameID = spellName .. spellRank
	
	sendMessage(string.format("S::%d:1", self.spellToID[nameID] or 0))
	parseHealEnd(playerGUID, playerName, self.spellToID[nameID], true)
end

function HealComm:UNIT_SPELLCAST_CHANNEL_STOP(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or id ~= castID ) then return end
	local nameID = spellName .. spellRank

	sendMessage(string.format("S::%d:0", self.spellToID[nameID] or 0))
	parseHealEnd(playerGUID, playerName, self.spellToID[nameID], false)
end

-- Cast didn't go through, recheck any charge data if necessary
function HealComm:UNIT_SPELLCAST_INTERRUPTED(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or castID ~= id ) then return end
	
	ResetChargeData(castGUIDs[spellName .. spellRank], spellName, spellRank)
end

-- It's faster to do heal delays locally rather than through syncing, as it only has to go from WoW -> Player instead of Caster -> WoW -> Player
function HealComm:UNIT_SPELLCAST_DELAYED(unit, spellName, spellRank, id)
	local casterGUID = UnitGUID(unit)
	if( unit == "focus" or unit == "target" or not pendingHeals[casterGUID] or not pendingHeals[casterGUID][spellName] ) then return end
	
	-- Direct heal delayed
	if( pendingHeals[casterGUID][spellName].bitType == DIRECT_HEALS ) then
		local startTime, endTime = select(5, UnitCastingInfo(unit))
		if( startTime and endTime ) then
			parseHealDelayed(casterGUID, startTime / 1000, endTime / 1000, spellName)
		end
	-- Channel heal delayed
	elseif( pendingHeals[casterGUID][spellName].bitType == CHANNEL_HEALS ) then
		local startTime, endTime = select(5, UnitChannelInfo(unit))
		if( startTime and endTime ) then
			parseHealDelayed(casterGUID, startTime / 1000, endTime / 1000, spellName)
		end
	end
end

function HealComm:UNIT_SPELLCAST_CHANNEL_UPDATE(...)
	self:UNIT_SPELLCAST_DELAYED(...)
end

-- Need to keep track of mouseover as it can change in the split second after/before casts
function HealComm:UPDATE_MOUSEOVER_UNIT()
	mouseoverGUID = UnitCanAssist("player", "mouseover") and UnitGUID("mouseover")
	mouseoverName = UnitCanAssist("player", "mouseover") and UnitName("mouseover")
end

-- Keep track of our last target/friendly target for the sake of /targetlast and /targetlastfriend
function HealComm:PLAYER_TARGET_CHANGED()
	if( lastGUID and lastName ) then
		if( lastIsFriend ) then
			lastFriendlyGUID, lastFriendlyName = lastGUID, lastName
		end
		
		lastTargetGUID, lastTargetName = lastGUID, lastName
	end
	
	-- Despite the fact that it's called target last friend, UnitIsFriend won't actually work
	lastGUID = UnitGUID("target")
	lastName = UnitName("target")
	lastIsFriend = UnitCanAssist("player", "target")
end

-- Unit was targeted through a function
function HealComm:Target(unit)
	if( self.resetFrame:IsShown() and UnitCanAssist("player", unit) ) then
		setCastData(6, UnitName(unit), UnitGUID(unit))
	end

	self.resetFrame:Hide()
	hadTargetingCursor = nil
end

-- This is only needed when auto self cast is off, in which case this is called right after UNIT_SPELLCAST_SENT
-- because the player got a waiting-for-cast icon up and they pressed a key binding to target someone
HealComm.TargetUnit = HealComm.Target

-- Works the same as the above except it's called when you have a cursor icon and you click on a secure frame with a target attribute set
HealComm.SpellTargetUnit = HealComm.Target

-- Used in /assist macros
-- The client should only be able to assist someone if it has data on them, which means the UI has data on them
function HealComm:AssistUnit(unit)
	if( self.resetFrame:IsShown() and UnitCanAssist("player", unit .. "target") ) then
		setCastData(6, UnitName(unit .. "target"), UnitGUID(unit .. "target"))
	end
	
	self.resetFrame:Hide()
	hadTargetingCursor = nil
end

-- Target last was used, the only reason this is called with reset frame being shown is we're casting on a valid unit
-- don't have to worry about the GUID no longer being invalid etc
function HealComm:TargetLast(guid, name)
	if( name and guid and self.resetFrame:IsShown() ) then
		setCastData(5, name, guid) 
	end
	
	self.resetFrame:Hide()
	hadTargetingCursor = nil
end

function HealComm:TargetLastFriend()
	self:TargetLast(lastFriendlyGUID, lastFriendlyName)
end

function HealComm:TargetLastTarget()
	self:TargetLast(lastTargetGUID, lastTargetName)
end

-- Spell was cast somehow
function HealComm:CastSpell(arg, unit)
	-- If the spell is waiting for a target and it's a spell action button then we know that the GUID has to be mouseover or a key binding cast.
	if( unit and UnitCanAssist("player", unit)  ) then
		setCastData(4, UnitName(unit), UnitGUID(unit))
	-- No unit, or it's a unit we can't assist 
	elseif( not SpellIsTargeting() ) then
		if( UnitCanAssist("player", "target") ) then
			setCastData(4, UnitName("target"), UnitGUID("target"))
		else
			setCastData(4, playerName, playerGUID)
		end
		
		hadTargetingCursor = nil
	else
		hadTargetingCursor = true
	end
end

HealComm.CastSpellByName = HealComm.CastSpell
HealComm.CastSpellByID = HealComm.CastSpell
HealComm.UseAction = HealComm.CastSpell

-- Make sure we don't have invalid units in this
local function sanityCheckMapping()
	for guid, unit in pairs(guidToUnit) do
		if( not UnitExists(unit) or UnitGUID(unit) ~= guid ) then
			guidToUnit[guid] = nil
			guidToGroup[guid] = nil
			
			compressGUID[guid] = nil
			decompressGUID[guid] = nil
			
			pendingHeals[guid] = nil
		end
	end
end

-- Once we leave a group all of the table data we had should be reset completely to release the tables into memory
local wasInParty, wasInRaid
local function clearGUIDData()
	-- Clear all cached GUID compressers
	table.wipe(compressGUID)
	table.wipe(decompressGUID)
	
	-- Reset our mappings
	HealComm.guidToUnit, HealComm.guidToGroup = {[UnitGUID("player")] = "player"}, {}
	guidToUnit, guidToGroup = HealComm.guidToUnit, HealComm.guidToGroup
	
	-- And also reset all pending data
	HealComm.pendingHeals = {}
	pendingHeals = HealComm.pendingHeals
	
	HealComm.bucketHeals = {}
	bucketHeals = HealComm.bucketHeals
	
	wasInParty, wasInRaid = nil, nil
end

-- Keeps track of pet GUIDs, as pets are considered vehicles this will also map vehicle GUIDs to unit
function HealComm:UNIT_PET(unit)
	unit = unit == "player" and "pet" or unit .. "pet"
	
	local guid = UnitGUID(unit)
	if( guid ) then
		guidToUnit[guid] = unit
	end
end

-- Keep track of party GUIDs, ignored in raids as RRU will handle that mapping
function HealComm:PARTY_MEMBERS_CHANGED()
	if( GetNumRaidMembers() > 0 ) then return end
	updateDistributionChannel()
	
	if( GetNumPartyMembers() == 0 ) then
		clearGUIDData()
		return
	end
	
	-- Because parties do not have "real" groups, we will simply pretend they are all in group 0
	guidToGroup[UnitGUID("player")] = 0
	
	for i=1, MAX_PARTY_MEMBERS do
		local unit = "party" .. i
		if( UnitExists(unit) ) then
			local guid = UnitGUID(unit)
			guidToUnit[guid] = unit
			guidToGroup[guid] = 0
			
			if( not wasInParty ) then
				self:UNIT_PET(unit)
			end
		end
	end

	sanityCheckMapping()
	wasInParty = true
end

-- Keep track of raid GUIDs
function HealComm:RAID_ROSTER_UPDATE()
	updateDistributionChannel()

	-- Left raid, clear any cache we had
	if( GetNumRaidMembers() == 0 ) then
		clearGUIDData()
		return
	end
	
	-- Add new members
	for i=1, MAX_RAID_MEMBERS do
		local unit = "raid" .. i
		if( UnitExists(unit) ) then
			local guid = UnitGUID(unit)
			self.guidToUnit[guid] = unit
			self.guidToGroup[guid] = select(3, GetRaidRosterInfo(i))
			
			if( not wasInRaid ) then
				self:UNIT_PET(unit)
			end
		end
	end
	
	sanityCheckMapping()
	wasInRaid = true
end

-- PLAYER_ALIVE = got talent data
function HealComm:PLAYER_ALIVE()
	self:PLAYER_TALENT_UPDATE()
	self.frame:UnregisterEvent("PLAYER_ALIVE")
end

-- Initialize the library
function HealComm:OnInitialize()
	if( self.initialized ) then return end
	self.initialized = true
	
	-- Load class data
	local class = select(2, UnitClass("player"))
	if( class == "DRUID" ) then
		loadDruidData()
	elseif( class == "SHAMAN" ) then
		loadShamanData()
	elseif( class == "PALADIN" ) then
		loadPaladinData()
	elseif( class == "PRIEST" ) then
		loadPriestData()
	-- Have to be ready for the next expansion!
	--elseif( class == "DEATHKNIGHT" ) then
	end
	
	-- Cache glyphs initially
    for id=1, GetNumGlyphSockets() do
		local enabled, _, glyphID = GetGlyphSocketInfo(id)
		if( enabled and glyphID ) then
			glyphCache[glyphID] = true
			glyphCache[id] = glyphID
		end
	end

	-- Oddly enough player GUID is not available on file load, so keep the map of player GUID to themselves too
	playerGUID = UnitGUID("player")
	playerName = UnitName("player")
	
	guidToUnit[playerGUID] = "player"
	
	self:PLAYER_EQUIPMENT_CHANGED()
	self:ZONE_CHANGED_NEW_AREA()
	
	-- When first logging in talent data isn't available until at least PLAYER_ALIVE, so if we don't have data
	-- will wait for that event otherwise will just cache it right now
	if( GetNumTalentTabs() == 0 ) then
		self.frame:RegisterEvent("PLAYER_ALIVE")
	else
		self:PLAYER_TALENT_UPDATE()
	end
	
	if( ResetChargeData ) then
		HealComm.frame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
	end
	
	-- Finally, register it all
	self.frame:RegisterEvent("UNIT_SPELLCAST_SENT")
	self.frame:RegisterEvent("UNIT_SPELLCAST_START")
	self.frame:RegisterEvent("UNIT_SPELLCAST_STOP")
	self.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
	self.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
	self.frame:RegisterEvent("UNIT_SPELLCAST_DELAYED")
	self.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
	self.frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	self.frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	self.frame:RegisterEvent("CHAT_MSG_ADDON")
	self.frame:RegisterEvent("PLAYER_TALENT_UPDATE")
	self.frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
	self.frame:RegisterEvent("PLAYER_TARGET_CHANGED")
	self.frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
	self.frame:RegisterEvent("SPELLS_CHANGED")
	self.frame:RegisterEvent("GLYPH_ADDED")
	self.frame:RegisterEvent("GLYPH_REMOVED")
	self.frame:RegisterEvent("GLYPH_UPDATED")
	self.frame:RegisterEvent("UNIT_PET")
	self.frame:RegisterEvent("UNIT_AURA")

	self.resetFrame = self.resetFrame or CreateFrame("Frame")
	self.resetFrame:Hide()
	self.resetFrame:SetScript("OnUpdate", function(self)
		self:Hide()
	end)
	
	-- You can't unhook secure hooks after they are done, so will hook once and the HealComm table will update with the latest functions
	-- automagically. If a new function is ever used it'll need a specific variable to indicate those set of hooks.
	-- By default most of these are mapped to a more generic function, but I call separate ones so I don't have to rehook
	-- if it turns out I need to know something specific
	hooksecurefunc("TargetUnit", function(...) HealComm:TargetUnit(...) end)
	hooksecurefunc("SpellTargetUnit", function(...) HealComm:SpellTargetUnit(...) end)
	hooksecurefunc("AssistUnit", function(...) HealComm:AssistUnit(...) end)
	hooksecurefunc("UseAction", function(...) HealComm:UseAction(...) end)
	hooksecurefunc("CastSpellByID", function(...) HealComm:CastSpellByID(...) end)
	hooksecurefunc("CastSpellByName", function(...) HealComm:CastSpellByName(...) end)
	hooksecurefunc("TargetLastFriend", function(...) HealComm:TargetLastFriend(...) end)
	hooksecurefunc("TargetLastTarget", function(...) HealComm:TargetLastTarget(...) end)
end

-- General event handler
local function OnEvent(self, event, ...)
	if( event == "GLYPH_ADDED" or event == "GLYPH_REMOVED" or event == "GLYPH_UPDATED" ) then
		HealComm:GlyphsUpdated(...)
	else
		HealComm[event](HealComm, ...)
	end
end

-- Event handler
HealComm.frame = HealComm.frame or CreateFrame("Frame")
HealComm.frame:UnregisterAllEvents()
HealComm.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
HealComm.frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
HealComm.frame:RegisterEvent("RAID_ROSTER_UPDATE")
HealComm.frame:SetScript("OnEvent", OnEvent)

if( not isHealerClass ) then return end

-- If the player is not logged in yet, then we're still loading and will watch for PLAYER_LOGIN to assume everything is initialized
-- if we're already logged in then it was probably LOD loaded
function HealComm:PLAYER_LOGIN()
	self:OnInitialize()
	self.frame:UnregisterEvent("PLAYER_LOGIN")
end

if( not IsLoggedIn() ) then
	HealComm.frame:RegisterEvent("PLAYER_LOGIN")
else
	HealComm:OnInitialize()
end
