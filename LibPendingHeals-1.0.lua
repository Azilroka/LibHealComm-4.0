local major = "LibPendingHeals-1.0"
local minor = 1
assert(LibStub, string.format("%s requires LibStub.", major))

local PendHeals = LibStub:NewLibrary(major, minor)
if( not PendHeals ) then return end

-- This needs to be bumped if there is a major change that breaks the comm format
local COMM_PREFIX = "LPH10"
local playerGUID, playerName

PendHeals.callbacks = PendHeals.callbacks or LibStub:GetLibrary("CallbackHandler-1.0"):New(PendHeals)

PendHeals.glyphCache = PendHeals.glyphCache or {}
PendHeals.playerModifiers = PendHeals.playerModifiers or {}
PendHeals.guidToGroup = PendHeals.guidToGroup or {}
PendHeals.guidToUnit = PendHeals.guidToUnit or {}
PendHeals.spellData = PendHeals.spellData or {}
PendHeals.spellToID = PendHeals.spellToID or {}
PendHeals.pendingHeals = PendHeals.pendingHeals or {}

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
if( not PendHeals.tooltip ) then
	local tooltip = CreateFrame("GameTooltip")
	tooltip:SetOwner(UIParent, "ANCHOR_NONE")
	for i=1, 8 do
		tooltip["TextLeft" .. i] = tooltip:CreateFontString()
		tooltip["TextRight" .. i] = tooltip:CreateFontString()
		tooltip:AddFontStrings(tooltip["TextLeft" .. i], tooltip["TextRight" .. i])
	end
	
	PendHeals.tooltip = tooltip
end

-- So I don't have to keep matching the same numbers every time :<
if( not PendHeals.rankNumbers ) then
	PendHeals.rankNumbers = setmetatable({}, {
		__index = function(tbl, index)
			local number = tonumber(string.match(index, "(%d+)")) or 1
			rawset(tbl, index, number)
			
			return number
		end,
	})
end

-- Get the average heal amount and cache it
-- We don't need to reset this table on spell change
if( not PendHeals.averageHeal ) then
	PendHeals.averageHeal = setmetatable({}, {
		__index = function(tbl, index)
			-- Find the spell from the spell book and cache the results!
			local offset, numSpells = select(3, GetSpellTabInfo(GetNumSpellTabs()))
			for id=1, (offset + numSpells) do
				-- Match, yay!
				local spellName, spellRank = GetSpellName(id, BOOKTYPE_SPELL)
				local name = spellName .. spellRank
				if( index == name ) then
					PendHeals.tooltip:SetSpell(id, BOOKTYPE_SPELL)
					
					-- Check last line for the spell info
					local text = PendHeals.tooltip["TextLeft" .. PendHeals.tooltip:NumLines()]
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
						if( not minHeal and not maxHeal and PendHeals.spellData[spellName].noRange ) then
							local heal = string.match(text:GetText(), "(%d+)")
							minHeal, maxHeal = heal, heal
						end
						
						minHeal = tonumber(minHeal)
						maxHeal = tonumber(maxHeal)
						
						if( minHeal and maxHeal ) then
							-- Already scanning the tooltip, might as well pull the spellID for comm too
							PendHeals.spellToID[name] = select(3, PendHeals.tooltip:GetSpell())

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
function PendHeals:GetHealModifier(guid)
	return PendHeals.currentModifiers[guid] or 1
end

--[[
- PendingHeals:GetGuidUnitMapTable
Returns a protected table that can't be modified, but returns a list of GUID -> Units.

- PendingHeals:GetCasterTable()
Returns a protected table that can't be modified, but can be used if you want to get a list of who currently has an active heal. If you use it with the GUID -> Unit map you can do things like pull all Druids using LibPendingHeals-1.0 without having to save your own mappings.

- PendingHeals:GetHealModifier(guid)
Gets the healing modifier for the GUID, defaults to 1 if no modifier was found.

- PendingHeals:GetHealAmount(guid, bitType[, time[, casterGUID])
bitType will be a bit field for what kind of combination of heals to get, it will have constants and such as well in case something changes later on.

Gets all pending heals of the passed type (all if nil) within the period of time (if passed) and matches the casterGUID (if true), returns nil if no heals are found.
Returns the total healing using the passed filters within the time period, or overall if no time is passed. For example, if there is a Greater Heal coming in 2 seconds for 5,000, a Rejuvenation coming in for 2,000 in 1s and 2,000s in 4s then looking at the healing incoming in the next 2s will give you 7,000.]]


-- Healing class data
-- Thanks to Gagorian (DrDamage) for letting me steal his formulas and such
local playerModifiers, averageHeal, rankNumbers, glyphCache = PendHeals.playerModifiers, PendHeals.averageHeal, PendHeals.rankNumbers, PendHeals.glyphCache
local guidToUnit, guidToGroup = PendHeals.guidToUnit, PendHeals.guidToGroup
local currentRelicID, CalculateHealing, GetHealTargets, AuraHandler, ResetChargeData
local spellData, talentData, equippedSetPieces, itemSetsData, baseHealingRelics = PendHeals.spellData, {}, {}, {}
local playerHealModifier = 1

-- UnitBuff priortizes our buffs over everyone elses when there is a name conflict, so yay for that
local function unitHasAura(unit, name)
	-- Does caster ever return anything but player? Pretty sure it won't in this case
	-- not like we can get heals while in an active vehicle
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
	
	GetHealTargets: Who this heal is going to hit, used for setting which targes to hit for Heal of Light, can also be used
	as an override for things like Glyph of Healing Wave which is a 100% heal on target and 20% heal on yourself
	when the 2nd return is amount, it will use that amount for all targets otherwise it will use whatever is passed for each GUID
	
	**NOTE** Any GUID returned from GetHealTargets must be compressed through a call to compressGUID[guid]
]]
	
-- DRUIDS
-- All data is accurate as of 3.2.2 (build 10257)
local function loadDruidData()
	-- Spell data
	local Rejuvenation = GetSpellInfo(774)
	local Lifebloom = GetSpellInfo(33763)
	local WildGrowth = GetSpellInfo(48438)
	local TreeofLife = GetSpellInfo(5420)
	local Innervate = GetSpellInfo(29166)
	
	--[[
	-- Rejuvenation
	spellData[Rejuvenation] = {level = {4, 10, 16, 22, 28, 34, 40, 46, 52, 58, 60, 63, 69, 75, 80}, type = "hot"}
	-- Lifebloom, another fun spell. How do you consider the bloom, would that be considered a normal heal at the end? Maybe
	-- Blizzard should delete Druids and make this easier
	spellData[Lifebloom] = {level = {64, 72, 80}, type = "hot"}
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
	
	--[[
		Idols
		
		40711 - Idol of Lush Moss, 125 LB per tick SP
		36366 - Idol of Pure Thoughts, +33 SP per Rejuv tick
		27886 - Idol of the Emerald Queen, +47 per LB Tick
		25643 - Harold's Rejuvenation Broach, +86 Rejuv total
		22398 - Idol of rejuvenation, +50 SP to Rejuv
	]]
	
	baseHealingRelics = {[28568] = HealingTouch, [22399] = HeaingTouch}
	
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
	
	CalculateHealing = function(guid, spellName, spellRank)
		local healAmount = PendHeals.averageHeal[spellName .. spellRank]
		local spellPower = GetSpellBonusHealing()
		local multiModifier, addModifier = 1, 1
		local rank = PendHeals.rankNumbers[spellRank]
		
		-- Gift of Nature
		multiModifier = multiModifier * (1 + talentData[GiftofNature].current)
		
		-- Master Shapeshifter does not apply directly when using Lifebloom
		if( unitHasAura("player", TreeofLife) ) then
			multiModifier = multiModifier * (1 + talentData[MasterShapeshifter].current)
			
			-- 32387 - Idol of the Raven Godess, +44 SP while in TOL
			if( currentRelicID == 32387 ) then
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
			if( currentRelicID == 46138 ) then
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
			return "channel", math.ceil(healAmount * playerHealModifier), spellData[spellName].ticks
		end
		
		return "heal", math.ceil(healAmount * playerHealModifier)
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
	-- 100% of your heal on someone within range of your beacon heals the beacon target too
	local BeaconofLight = GetSpellInfo(53563)
	-- 100% chance to crit
	local DivineFavor = GetSpellInfo(20216)
	-- Seal of Light + Glyph = 5% healing
	local SealofLight = GetSpellInfo(20165)
	
	-- Am I slightly crazy for adding level <40 glyphs? Yes!
	local flashLibrams = {[42615] = 375, [42614] = 331, [42613] = 293, [42612] = 204, [25644] = 79, [23006] = 43, [23201] = 28}
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
		local healAmount = PendHeals.averageHeal[spellName .. spellRank]
		local spellPower = GetSpellBonusHealing()
		local multiModifier, addModifier = 1, 1
		local rank = PendHeals.rankNumbers[spellRank]
		
		-- Glyph of Seal of Light, +5% healing if the player has Seal of Light up
		if( glyphCache[54943] and unitHasAura("player", SealofLight) ) then
			multiModifier = multiModifier * 1.05
		end
		
		addModifier = addModifier + talentData[Divinity].current
		multiModifier = multiModifier * (1 + talentData[Divinity].current)
		
		multiModifier = multiModifier * (1 + talentData[HealingLight].current)
		
		-- Apply extra spell power based on libram
		if( currentRelicID ) then
			if( spellName == HolyLight and holyLibrams[currentRelicID] ) then
				spellPower = spellPower + holyLibrams[currentRelicID]
			elseif( spellName == FlashofLight and flashLibrams[currentRelicID] ) then
				spellPower = spellPower + flashLibrams[currentRelicID]
			end
		end
		
		-- Normal calculations
		spellPower = spellPower * (spellData[spellName].coeff * 1.88)
		
		healAmount = calculateGeneralAmount(spellData[spellName][rank], healAmount, spellPower, multiModifier, addModifier)

		-- Divine Favor, 100% chance to crit
		if( hasDivineFavor ) then
			hasDivineFavor = nil
			healAmount = healAmount * 1.50
		-- Or the player has over a 95% chance to crit with Holy spells
		elseif( GetSpellCritChance(2) >= 100 ) then
			healAmount = healAmount * 1.50
		end
	
		return "heal", math.ceil(healAmount * playerHealModifier)
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
		local healAmount = PendHeals.averageHeal[spellName .. spellRank]
		local rank = PendHeals.rankNumbers[spellRank]
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
		
		-- As Penance doesn't actually heal for it's amount instantly, send it as a channel heal
		-- even thought Penance ticks 3 times, the first one is instant and will heal before the comm message gets there, so pretend it's two heals
		if( spellName == Penance ) then
			return "channel", healAmount, 2
		end
				
		return "heal", healAmount
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
		
		if( unitHasAura(unit, EarthShield) ) then
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
			return string.format("%s,%d,%s,%d", compressGUID[guid], healAmount, compressGUID[guid], healAmount *  0.20)
		end
	
		return compressGUID[guid], healAmount
	end
	
	-- If only every other class was as easy as Paladins
	CalculateHealing = function(guid, spellName, spellRank)
		local healAmount = PendHeals.averageHeal[spellName .. spellRank]
		local rank = PendHeals.rankNumbers[spellRank]
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
			if( currentRelicID == 27544 ) then
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
			if( currentRelicID and lhwTotems[currentRelicID] ) then
				spellPower = spellPower + lhwTotems[currentRelicID]
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
		return "heal", healAmount
	end
end

-- Healing modifiers
PendHeals.currentModifiers = PendHeals.currentModifiers or {}

PendHeals.selfModifiers = PendHeals.selfModifiers or {
	[64850] = 0.50, -- Unrelenting Assault
	[65925] = 0.50, -- Unrelenting Assault
	[54428] = 0.50, -- Divine Plea
	[64849] = 0.75, -- Unrelenting Assault
	[31884] = 1.20, -- Avenging Wrath
}

-- There is one spell currently that has a name conflict, which is ray of Pain from the Void Walkers in Nagrand
-- if it turns out there are more later on (which is doubtful) I'll change it
PendHeals.healingModifiers = PendHeals.healingModifiers or {
	[GetSpellInfo(30843)] = 0.00, -- Enfeeble
	[GetSpellInfo(41292)] = 0.00, -- Aura of Suffering
	[GetSpellInfo(59513)] = 0.00, -- Embrace of the Vampyr
	[GetSpellInfo(55593)] = 0.00, -- Necrotic Aura
	[GetSpellInfo(34625)] = 0.25, -- Demolish
	[GetSpellInfo(34366)] = 0.25, -- Ebon Poison
	[GetSpellInfo(19716)] = 0.25, -- Gehennas' Curse
	[GetSpellInfo(24674)] = 0.25, -- Veil of Shadow
	-- Despite the fact that Wound Poison uses the same 50% now, it's a unique spellID and buff name for each rank
	[GetSpellInfo(13218)] = 0.50, -- 1
	[GetSpellInfo(13222)] = 0.50, -- 2
	[GetSpellInfo(13223)] = 0.50, -- 3
	[GetSpellInfo(13224)] = 0.50, -- 4
	[GetSpellInfo(27189)] = 0.50, -- 5
	[GetSpellInfo(57974)] = 0.50, -- 6
	[GetSpellInfo(57975)] = 0.50, -- 7
	[GetSpellInfo(20900)] = 0.50, -- Aimed Shot
	[GetSpellInfo(21551)] = 0.50, -- Mortal Strike
	[GetSpellInfo(40599)] = 0.50, -- Arcing Smash
	[GetSpellInfo(36917)] = 0.50, -- Magma-Throwser's Curse
	[GetSpellInfo(23169)] = 0.50, -- Brood Affliction: Green
	[GetSpellInfo(22859)] = 0.50, -- Mortal Cleave
	[GetSpellInfo(36023)] = 0.50, -- Deathblow
	[GetSpellInfo(13583)] = 0.50, -- Curse of the Deadwood
	[GetSpellInfo(32378)] = 0.50, -- Filet
	[GetSpellInfo(35189)] = 0.50, -- Solar Strike
	[GetSpellInfo(32315)] = 0.50, -- Soul Strike
	[GetSpellInfo(60084)] = 0.50, -- The Veil of Shadow
	[GetSpellInfo(45885)] = 0.50, -- Shadow Spike
	[GetSpellInfo(63038)] = 0.75, -- Dark Volley
	[GetSpellInfo(52771)] = 0.75, -- Wounding Strike
	[GetSpellInfo(48291)] = 0.75, -- Fetid Healing
	[GetSpellInfo(54525)] = 0.80, -- Shroud of Darkness (This might be wrong)
	[GetSpellInfo(48301)] = 0.80, -- Mind Trauma (Improved Mind Blast)
	[GetSpellInfo(68391)] = 0.80, -- Permafrost, the debuff is generic no way of seeing 7/13/20, go with 20
	[GetSpellInfo(34073)] = 0.85, -- Curse of the Bleeding Hollow
	[GetSpellInfo(43410)] = 0.90, -- Chop
	[GetSpellInfo(34123)] = 1.06, -- Tree of Life
	[GetSpellInfo(64844)] = 1.10, -- Divine Hymn
	[GetSpellInfo(47788)] = 1.40, -- Guardian Spirit
	[GetSpellInfo(38387)] = 1.50, -- Bane of Infinity
	[GetSpellInfo(31977)] = 1.50, -- Curse of Infinity
	[GetSpellInfo(41350)] = 2.00, -- Aura of Desire
}

-- Easier to toss functions on 4 extra functions than add extra checks
PendHeals.healingStackMods = PendHeals.healingStackMods or {
	-- Tenacity
	[GetSpellInfo(58549)] = function(name, rank, icon, stacks) return icon == "Interface\\Icons\\Ability_Warrior_StrengthOfArms" and stacks ^ 1.18 or 1 end,
	-- Focused Will
	[GetSpellInfo(45242)] = function(name, rank, icon, stacks) return 1 + (stacks * (0.02 + rankNumbers[rank])) end,
	-- Nether Portal - Dominance
	[GetSpellInfo(30423)] = function(name, rank, icon, stacks) return 1 + stacks * 0.01 end,
	-- Dark Touched
	[GetSpellInfo(45347)] = function(name, rank, icon, stacks) return 1 - stacks * 0.04 end, 
	-- Necrotic Strike
	[GetSpellInfo(60626)] = function(name, rank, icon, stacks) return 1 - stacks * 0.10 end, 
	-- Mortal Wound
	[GetSpellInfo(28467)] = function(name, rank, icon, stacks) return 1 - stacks * 0.10 end, 
}

local healingStackMods, selfModifiers = PendHeals.healingStackMods, PendHeals.selfModifiers
local healingModifiers, longAuras = PendHeals.healingModifiers, PendHeals.longAuras
local currentModifiers = PendHeals.currentModifiers

-- DEBUG
local debugGUIDMap = {}

local distribution
local function sendMessage(msg)
	if( distribution ) then
		--SendAddonMessage(COMM_PREFIX, msg, distribution)
	end
end

-- Keep track of where all the data should be going
local instanceType
local function updateDistributionChannel()
	if( instanceType == "pvp" or instanceType == "arena" ) then
		distribution = "BATTLEGROUND"
	elseif( GetNumRaidMembers() > 0 ) then
		distribution = "RAID"
	elseif( GetNumPartyMembers() > 0 ) then
		distribution = "PARTY"
	else
		distribution = nil
	end
end

-- Figure out where we should be sending messages and wipe some caches
function PendHeals:ZONE_CHANGED_NEW_AREA()
	local type = select(2, IsInInstance())
	if( type ~= instanceType ) then
		instanceType = type
		
		updateDistributionChannel()
		distribution = ( type == "pvp" or type == "arena" ) and "BATTLEGROUND" or "RAID"
		
		-- DEBUG
		table.wipe(debugGUIDMap)
		
		-- Sanity checking will ensure that people who leave the group have their data wiped, this just makes sure
		-- that we don't need up with pending data between zone ins. Might need to fire callbacks if we did clear something I suppose? Hrm
		--for _, spells in pairs(self.pendingHeals) do
		--	for _, spell in pairs(spells) do
		--		table.wipe(spells)
		--	end
		--end
		
		-- Changes the value of Necrotic Poison based on zone type, if there are more difficulty type MS's I'll support those too
		-- Heroic = 90%, Non-Heroic = 75%
		if( GetRaidDifficulty() == 2 or GetRaidDifficulty() == 4 ) then
			healingModifiers[GetSpellInfo(53121)] = 0.95
		else
			healingModifiers[GetSpellInfo(53121)] = 0.10
		end
	else
		instanceType = type
	end
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
function PendHeals:UNIT_AURA(unit)
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
			self.callbacks:Fire("PendingHeals_ModifierChanged", guid, modifier)
		end
		
		currentModifiers[guid] = modifier
	end

	table.wipe(alreadyAdded)
	
	-- Class has a specific monitor it needs for auras
	AuraHandler(guid, unit)
end

-- Monitor aura changes
local COMBATLOG_OBJECT_AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE
local eventRegistered = {["SPELL_AURA_REMOVED"] = true, ["SPELL_AURA_APPLIED"] = true}
function PendHeals:COMBAT_LOG_EVENT_UNFILTERED(timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, ...)
	if( not eventRegistered[eventType] or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) ~= COMBATLOG_OBJECT_AFFILIATION_MINE ) then return end
	
	if( eventType == "SPELL_AURA_APPLIED" ) then
		local spellID, spellName, spellSchool, auraType = ...
		if( selfModifiers[spellID] ) then
			playerModifiers[spellID] = selfModifiers[spellID]
			recalculatePlayerModifiers()
		end
				
	elseif( eventType == "SPELL_AURA_REMOVED" ) then
		local spellID, spellName, spellSchool, auraType = ...
		if( playerModifiers[spellID] ) then
			playerModifiers[spellID] = nil
			recalculatePlayerModifiers()
		end
	end
end

-- Monitor glyph changes
function PendHeals:GlyphsUpdated(id)
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
function PendHeals:SPELLS_CHANGED()
	if( changedThrottle < GetTime() ) then
		changedThrottle = GetTime() + 2
		table.wipe(averageHeal)
	end
end

-- Cache player talent data for spells we need
function PendHeals:PLAYER_TALENT_UPDATE()
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
function PendHeals:PLAYER_EQUIPMENT_CHANGED()
	-- Figure out our set bonus info
	for name, items in pairs(itemSetsData) do
		equippedSetPieces[name] = 0
		for _, itemID in pairs(items) do
			if( IsEquippedItem(itemID) ) then
				equippedSetPieces[name] = equippedSetPieces[name] + 1
			end
		end
	end
	
	-- Check relic
	local previousRelic = currentRelicID
	
	currentRelicID = GetInventoryItemLink("player", RANGED_SLOT)
	if( currentRelicID ) then
		currentRelicID = tonumber(string.match(currentRelicID, "item:(%d+):"))
	end
	
	-- Relics that modify the base healing of a spell modify the tooltip with the new base amount, we can't assume that the tooltip that was cached
	-- is the one with the modified (or unmodified) version so reset the cache and it will get whatever the newest version is.
	if( previousRelic ~= currentRelicID and baseHealingRelics ) then
		local resetSpell = previousRelic and baseHealingRelics[previousRelic] or currentRelicID and baseHealingRelics[currentRelicID]
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
local pendingHeals = PendHeals.pendingHeals
local tempPlayerList = {}

-- Direct heal started
local function loadHealList(pending, amount, endTime, ...)
	table.wipe(tempPlayerList)
	
	-- For the sake of consistency, even a heal doesn't have multiple end times like a hot, it'll be treated as such in the DB
	if( amount > 0 ) then
		for i=1, select("#", ...) do
			local guid = decompressGUID[select(i, ...)]
			table.insert(pending, guid)
			table.insert(pending, amount)
			table.insert(pending, endTime)
			table.insert(tempPlayerList, guid)
		end
	elseif( amount == -1 ) then
		for i=1, select("#", ...), 2 do
			local guid = decompressGUID[select(i, ...)]
			local amount = tonumber((select(i + 1, ...)))
			if( amount ) then
				table.insert(pending, guid)
				table.insert(pending, amount)
				table.insert(pending, endTime)
				table.insert(tempPlayerList, guid)
			end
		end
	end
end

local function parseDirectHeal(sender, spellID, amount, ...)
	local casterGUID = UnitGUID(sender)
	local spellName = GetSpellInfo(spellID)
	if( not casterGUID or not spellName or not amount or select("#", ...) == 0 ) then return end
	
	local endTime = select(6, UnitCastingInfo(sender))
	if( not endTime ) then return end
	

	pendingHeals[casterGUID] = pendingHeals[casterGUID] or {}
	pendingHeals[casterGUID][spellName] = pendingHeals[casterGUID][spellName] or {}

	local pending = pendingHeals[casterGUID][spellName]
	table.wipe(pending)
	pending.endTime = endTime / 1000
	pending.type = "cast"

	loadHealList(pending, amount, 0, ...)
	PendHeals.callbacks:Fire("PendingHeals_HealStarted", casterGUID, spellID, pending.endTime, unpack(tempPlayerList))
end

-- Channeled heal started
local function parseChannelHeal(sender, spellID, amount, totalTicks, ...)
	local casterGUID = UnitGUID(sender)
	local spellName = GetSpellInfo(spellID)
	if( not casterGUID or not spellName or not totalTicks or not amount or select("#", ...) == 0 ) then return end

	local startTime, endTime = select(5, UnitChannelInfo(sender))
	if( not startTime or not endTime ) then return end

	pendingHeals[casterGUID] = pendingHeals[casterGUID] or {}
	pendingHeals[casterGUID][spellName] = pendingHeals[casterGUID][spellName] or {}

	local pending = pendingHeals[casterGUID][spellName]
	table.wipe(pending)
	pending.startTime = startTime / 1000
	pending.endTime = endTime / 1000
	pending.totalTicks = totalTicks
	pending.tickInterval = (pending.endTime - pending.startTime) / totalTicks
	pending.type = "channel"
	
	loadHealList(pending, amount, 0, ...)

	PendHeals.callbacks:Fire("PendingHeals_HealStarted", casterGUID, spellID, pending.endTime, unpack(tempPlayerList))
end

-- Hot heal started
local function parseHotHeal(sender, spellID, amount, totalTicks, ...)
	if( not amount or not totalTicks or select("#", ...) == 0 ) then return end

end

-- Heal finished
local function parseHealEnd(sender, spellID, ...)
	local casterGUID = UnitGUID(sender)
	local spellName = GetSpellInfo(spellID)
	if( not casterGUID or not spellName or not pendingHeals[casterGUID] ) then return end
	
	-- Hots should use spellIDs, casts should use spell names. This will keep everything happy for things like Regrowth with a heal and a hot
	local pending = pendingHeals[casterGUID][spellID] or pendingHeals[casterGUID][spellName]
	if( not pending ) then return end
		
	table.wipe(tempPlayerList)
	
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
				if( pending[i - 2][guid] ) then
					table.remove(pending, i)
					table.remove(pending, i - 1)
					table.remove(pending, i - 2)
				end
			end
		end
	end
		
	-- Double check and make sure we actually removed at least one person
	if( #(tempPlayerList) > 0 ) then
		PendHeals.callbacks:Fire("PendingHeals_HealStopped", casterGUID, spellID, unpack(tempPlayerList))
	end
end

-- Heal delayed
local function parseHealDelayed(sender, spellID, ...)
	local casterGUID = UnitGUID(sender)
	local spellName = GetSpellInfo(spellID)
	if( not casterGUID or not spellName or not pendingHeals[casterGUID] or not pendingHeals[casterGUID][spellName] ) then return end

	local pending = pendingHeals[casterGUID][spellName]
	if( pending.type == "cast" ) then
		local endTime = select(6, UnitCastingInfo(sender))
		if( not endTime ) then return end
		pending.endTime = endTime / 1000

	elseif( pending.type == "channel" ) then
		local startTime, endTime = select(5, UnitChannelInfo(sender))
		if( not startTime or not endTime ) then return end
		pending.startTime = startTime / 1000
		pending.endTime = endTime / 1000
		pending.tickInterval = (pending.endTime - pending.startTime)
	end

	table.wipe(tempPlayerList)

	for i=1, select("#", ...) do
		table.insert(tempPlayerList, decompressGUID[select(i, ...)])
	end

	PendHeals.callbacks:Fire("PendingHeals_HealDelayed", casterGUID, spellID, pending.endTime, unpack(tempPlayerList))
end

-- DEBUG
--[[
local Test = {}
function Test:Dump(...)
	table.insert(TestLog, {GetTime(), ...})
	print(...)
end

PendHeals.RegisterCallback(Test, "PendingHeals_HealStarted", "Dump")
PendHeals.RegisterCallback(Test, "PendingHeals_HealDelayed", "Dump")
PendHeals.RegisterCallback(Test, "PendingHeals_HealStopped", "Dump")
PendHeals.RegisterCallback(Test, "PendingHeals_ModifierChanged", "Dump")
]]

-- After checking around 150-200 messages in battlegrounds, server seems to always be passed (if they are from another server)
-- so the casterGUID isn't needed to be sent, I'll keep it around in case it does, but it also gives expansion potentional without breaking compatibility
function PendHeals:CHAT_MSG_ADDON(prefix, message, channel, sender)
	-- Reject any comm in a distribution we aren't watching
	if( prefix ~= COMM_PREFIX --[[or channel ~= distribution or sender == playerName]] ) then return end
	
	local commType, _, spellID, arg1, arg2, arg3, arg4 = string.split(":", message)
	spellID = tonumber(spellID)
	if( not commType or not spellID ) then return end
	
	--- New direct heal - D:<casterID>:<extra>:<spellID>:<amount>:target1,target2,target3,target4,etc
	if( commType == "D" and arg1 and arg2 ) then
		parseDirectHeal(sender, spellID, tonumber(arg1), string.split(",", arg2))
	--- New channel heal - C:<casterID>:<extra>:<spellID>:<amount>:<tickTotal>:target1,target2,target3,target4,etc
	elseif( commType == "C" and arg1 and arg2 and arg3 ) then
		parseChannelHeal(sender, spellID, tonumber(arg1), tonumber(arg2), string.split(",", arg3))
	--- New hot - H:<casterID>:<extra>:<spellID>:<amount>:<tickTotal>:<stack>:target1,target2,target3,target4,etc
	elseif( commType == "H" and arg1 and arg2 ) then
		parseHotHeal(sender, spellID, tonumber(arg1), tonumber(arg2), tonumber(arg3), string.split(",", arg4))
	--- Heal stopped - S:<casterID>:<extra>:<spellID>:target1,target2,target3,target4,etc
	elseif( commType == "S" ) then
		if( arg1 and arg1 ~= "" ) then
			parseHealEnd(sender, spellID, string.split(",", arg1))
		else
			parseHealEnd(sender, spellID)
		end
	--- Heal interrupted - P:<casterID>:<extra>:<spellID>:target1,target2,target3,target4,etc
	elseif( commType == "P" ) then
		if( arg1 and arg1 ~= "" ) then
			parseHealDelayed(sender, spellID, string.split(",", arg1))
		else
			parseHealDelayed(sender, spellID)
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
local castList = {}
function PendHeals:UNIT_SPELLCAST_SENT(unit, spellName, spellRank, castOn)
	if( unit ~= "player" or not spellData[spellName] or not averageHeal[spellName .. spellRank] ) then return end
	
	castTarget = stripServer(castOn)
	lastSentID = spellName .. spellRank
	
	-- DEBUG
	castList[lastSentID] = stripServer(castOn)
	
	-- Self cast is off which means it's possible to have a spell waiting for a target.
	-- It's possible that it's the mouseover unit, but if we see a *TargetUnit call then we know it's that unit for sure
	if( hadTargetingCursor ) then
		hadTargetingCursor = nil
		self.resetFrame:Show()
		
		-- Debug, swap me back to the original method later
		guidPriorities[lastSentID] = nil
		setCastData(5, mouseoverName, mouseoverGUID)
	else
		guidPriorities[lastSentID] = nil
		setCastData(0, nil, UnitGUID(castOn))
	end
end

--[[
[03:04:42] <Arrowmaster> no you create one empty table with a metatable of {__index=realtable,__newindex=function() end } or so
[03:04:53] <Arrowmaster> __newindex=false might work i dont know
[03:07:06] <Arrowmaster> make sure you set __metatable on that table too
]]

local timeThrottle
local function dataFailed(priority, spell, actual, target)
	if( not timeThrottle or timeThrottle < GetTime() ) then
		DEFAULT_CHAT_FRAME:AddMessage(string.format("WARNING! LibPendingHeals-1.0 GUID failure for %s. Target was %s (#%d), actual one was %s. Self cast %s, Class %s.", spell or "nil", target or "nil", priority or -1, actual or "nil", GetCVar("autoSelfCast") or "nil", (select(2, UnitClass("player")))))
		timeThrottle = GetTime() + 300
	end
end

function PendHeals:UNIT_SPELLCAST_START(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or not averageHeal[spellName .. spellRank] ) then return end
	local nameID = spellName .. spellRank
	local castGUID = castGUIDs[nameID]
	
	-- DEBUG
	local name
	if( castGUID ) then
		name = stripServer(debugGUIDMap[castGUID] or UnitName(guidToUnit[castGUID]) or castGUID or "")
	end
	
	if( ( not castGUID or name ~= castList[nameID] or guidPriorities[nameID] == 0 ) and spellName ~= "Tranquility" ) then
		dataFailed(guidPriorities[nameID], spellName, castList[nameID], name or castGUID)
	end

	-- Figure out who we are healing and for how much
	local type, amount, ticks = CalculateHealing(castGUID, spellName, spellRank)
	local targets, amount = GetHealTargets(castGUID, math.max(amount, 0), spellName, spellRank)

	--- D:<casterID>:<spellID>:<amount>:target1,target2,target3,target4,etc
	if( type == "heal" ) then
		sendMessage(string.format("D::%d:%d:%s", self.spellToID[nameID] or 0, amount or "", targets))
	--- C:<casterID>:<spellID>:<amount>:<tickTotal>:target1,target2,target3,target4,etc
	elseif( type == "channel" ) then
		sendMessage(string.format("C::%d:%d:%s:%s", self.spellToID[nameID] or 0, amount or "", ticks, targets))
	--- H:<casterID>:<spellID>:<amount>:<tickTotal>:<stack>:target1,target2,target3,target4,etc
	elseif( type == "hot" ) then
		sendMessage(string.format("H::%d:%d:%s:%s", self.spellToID[nameID] or 0, amount or "", ticks, targets))
	end
	
	castID = id
end

function PendHeals:UNIT_SPELLCAST_CHANNEL_START(...)
	self:UNIT_SPELLCAST_START(...)
end

function PendHeals:UNIT_SPELLCAST_STOP(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or id ~= castID ) then return end

	sendMessage(string.format("S::%d", self.spellToID[spellName .. spellRank] or 0))
end

function PendHeals:UNIT_SPELLCAST_CHANNEL_STOP(...)
	self:UNIT_SPELLCAST_STOP(...)
end

-- Cast didn't go through, recheck any charge data if necessary
function PendHeals:UNIT_SPELLCAST_INTERRUPTED(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or castID ~= id ) then return end
	
	ResetChargeData(castGUIDs[spellName .. spellRank], spellName, spellRank)
end

function PendHeals:UNIT_SPELLCAST_DELAYED(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or id ~= castID ) then return end
	
	sendMessage(string.format("P::%d", self.spellToID[spellName .. spellRank] or 0))
end

function PendHeals:UNIT_SPELLCAST_CHANNEL_UPDATE(...)
	self:UNIT_SPELLCAST_DELAYED(...)
end

-- Need to keep track of mouseover as it can change in the split second after/before casts
function PendHeals:UPDATE_MOUSEOVER_UNIT()
	mouseoverGUID = UnitCanAssist("player", "mouseover") and UnitGUID("mouseover")
	mouseoverName = UnitCanAssist("player", "mouseover") and UnitName("mouseover")
	
	-- DEBUG
	debugGUIDMap[UnitGUID("mouseover")] = UnitName("mouseover")
end

-- Keep track of our last target/friendly target for the sake of /targetlast and /targetlastfriend
function PendHeals:PLAYER_TARGET_CHANGED()
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
	
	if( lastGUID ) then
		debugGUIDMap[lastGUID] = lastName
	end
end

-- Unit was targeted through a function
function PendHeals:Target(unit)
	if( self.resetFrame:IsShown() and UnitCanAssist("player", unit) ) then
		setCastData(6, UnitName(unit), UnitGUID(unit))
	end

	self.resetFrame:Hide()
	hadTargetingCursor = nil
end

-- This is only needed when auto self cast is off, in which case this is called right after UNIT_SPELLCAST_SENT
-- because the player got a waiting-for-cast icon up and they pressed a key binding to target someone
PendHeals.TargetUnit = PendHeals.Target

-- Works the same as the above except it's called when you have a cursor icon and you click on a secure frame with a target attribute set
PendHeals.SpellTargetUnit = PendHeals.Target

-- Used in /assist macros
-- The client should only be able to assist someone if it has data on them, which means the UI has data on them
function PendHeals:AssistUnit(unit)
	if( self.resetFrame:IsShown() and UnitCanAssist("player", unit .. "target") ) then
		setCastData(6, UnitName(unit .. "target"), UnitGUID(unit .. "target"))
	end
	
	self.resetFrame:Hide()
	hadTargetingCursor = nil
end

-- Target last was used, the only reason this is called with reset frame being shown is we're casting on a valid unit
-- don't have to worry about the GUID no longer being invalid etc
function PendHeals:TargetLast(guid, name)
	if( name and guid and self.resetFrame:IsShown() ) then
		setCastData(5, name, guid) 
	end
	
	self.resetFrame:Hide()
	hadTargetingCursor = nil
end

function PendHeals:TargetLastFriend()
	self:TargetLast(lastFriendlyGUID, lastFriendlyName)
end

function PendHeals:TargetLastTarget()
	self:TargetLast(lastTargetGUID, lastTargetName)
end

-- Spell was cast somehow
function PendHeals:CastSpell(arg, unit)
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

PendHeals.CastSpellByName = PendHeals.CastSpell
PendHeals.CastSpellByID = PendHeals.CastSpell
PendHeals.UseAction = PendHeals.CastSpell

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
	self.guidToUnit, self.guidToGroup = {[playerGUID] = "player"}, {}
	guidToUnit, guidToGroup = self.guidToUnit, self.guidToGroup
	
	-- And also reset all pending data
	self.pendingHeals = {}
	pendingHeals = self.pendingHeals
	
	wasInParty, wasInRaid = nil, nil
end

-- Keeps track of pet GUIDs, as pets are considered vehicles this will also map vehicle GUIDs to unit
function PendHeals:UNIT_PET(unit)
	unit = unit == "player" and "pet" or unit .. "pet"
	
	local guid = UnitGUID(unit)
	if( guid ) then
		guidToUnit[guid] = unit
	end
end

-- Keep track of party GUIDs, ignored in raids as RRU will handle that mapping
function PendHeals:PARTY_MEMBERS_CHANGED()
	if( GetNumRaidMembers() > 0 ) then return end
	updateDistributionChannel()
	
	if( GetNumPartyMembers() == 0 ) then
		clearGUIDData()
		return
	end
	
	-- Because parties do not have "real" groups, we will simply pretend they are all in group 0
	guidToGroup[playerGUID] = 0
	
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
function PendHeals:RAID_ROSTER_UPDATE()
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
function PendHeals:PLAYER_ALIVE()
	self:PLAYER_TALENT_UPDATE()
	self.frame:UnregisterEvent("PLAYER_ALIVE")
end

-- Initialize the library
function PendHeals:OnInitialize()
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
	
	debugGUIDMap[playerGUID] = playerName
	
	guidToUnit[playerGUID] = "player"
	
	-- Figure out the initial relic
	self:PLAYER_EQUIPMENT_CHANGED()
	
	-- ZCNE is not called when you first login/reload, so call it once more to be safe
	self:ZONE_CHANGED_NEW_AREA()
	
	-- When first logging in talent data isn't available until at least PLAYER_ALIVE, so if we don't have data
	-- will wait for that event otherwise will just cache it right now
	if( GetNumTalentTabs() == 0 ) then
		self.frame:RegisterEvent("PLAYER_ALIVE")
	else
		self:PLAYER_TALENT_UPDATE()
	end
	
	if( ResetChargeData ) then
		PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
	end

	-- This resets the target timer next OnUpdate, the user would basically have to press the target button twice within
	-- <0.10 seconds, more like <0.05 to be able to bug it out
	self.resetFrame = self.resetFrame or CreateFrame("Frame")
	self.resetFrame:Hide()
	self.resetFrame:SetScript("OnUpdate", function(self)
		self:Hide()
	end)
	
	-- You can't unhook secure hooks after they are done, so will hook once and the PendHeals table will update with the latest functions
	-- automagically. If a new function is ever used it'll need a specific variable to indicate those set of hooks.
	-- By default most of these are mapped to a more generic function, but I call separate ones so I don't have to rehook
	-- if it turns out I need to know something specific
	hooksecurefunc("TargetUnit", function(...) PendHeals:TargetUnit(...) end)
	hooksecurefunc("SpellTargetUnit", function(...) PendHeals:SpellTargetUnit(...) end)
	hooksecurefunc("AssistUnit", function(...) PendHeals:AssistUnit(...) end)
	hooksecurefunc("UseAction", function(...) PendHeals:UseAction(...) end)
	hooksecurefunc("CastSpellByID", function(...) PendHeals:CastSpellByID(...) end)
	hooksecurefunc("CastSpellByName", function(...) PendHeals:CastSpellByName(...) end)
	hooksecurefunc("TargetLastFriend", function(...) PendHeals:TargetLastFriend(...) end)
	hooksecurefunc("TargetLastTarget", function(...) PendHeals:TargetLastTarget(...) end)
end

-- General event handler
local function OnEvent(self, event, ...)
	if( event == "GLYPH_ADDED" or event == "GLYPH_REMOVED" or event == "GLYPH_UPDATED" ) then
		PendHeals:GlyphsUpdated(...)
	else
		PendHeals[event](PendHeals, ...)
	end
end

-- Event handler
PendHeals.frame = PendHeals.frame or CreateFrame("Frame")
PendHeals.frame:UnregisterAllEvents()
PendHeals.frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
PendHeals.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
PendHeals.frame:RegisterEvent("CHAT_MSG_ADDON")
PendHeals.frame:RegisterEvent("UNIT_AURA")
PendHeals.frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
PendHeals.frame:RegisterEvent("RAID_ROSTER_UPDATE")
PendHeals.frame:SetScript("OnEvent", OnEvent)

-- If they aren't a healer, all they need to know about are modifier changes
local playerClass = select(2, UnitClass("player"))
if( playerClass ~= "DRUID" and playerClass ~= "PRIEST" and playerClass ~= "SHAMAN" and playerClass ~= "PALADIN" ) then
	return
end

PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_SENT")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_START")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_STOP")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_DELAYED")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
PendHeals.frame:RegisterEvent("PLAYER_TALENT_UPDATE")
PendHeals.frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
PendHeals.frame:RegisterEvent("PLAYER_TARGET_CHANGED")
PendHeals.frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
PendHeals.frame:RegisterEvent("SPELLS_CHANGED")
PendHeals.frame:RegisterEvent("GLYPH_ADDED")
PendHeals.frame:RegisterEvent("GLYPH_REMOVED")
PendHeals.frame:RegisterEvent("GLYPH_UPDATED")
PendHeals.frame:RegisterEvent("UNIT_PET")

-- If the player is not logged in yet, then we're still loading and will watch for PLAYER_LOGIN to assume everything is initialized
-- if we're already logged in then it was probably LOD loaded
function PendHeals:PLAYER_LOGIN()
	self:OnInitialize()
	self.frame:UnregisterEvent("PLAYER_LOGIN")
end

if( not IsLoggedIn() ) then
	PendHeals.frame:RegisterEvent("PLAYER_LOGIN")
else
	PendHeals:OnInitialize()
end
