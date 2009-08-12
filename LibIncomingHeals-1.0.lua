local major = "LibIncomingHeals-1.0"
local minor = 1
assert(LibStub, string.format("%s requires LibStub.", major))

local IncHeals = LibStub:NewLibrary(major, minor)
if( not IncHeals ) then return end

IncHeals.glyphCache = IncHeals.glyphCache or {}
IncHeals.callbacks = IncHeals.callbacks or LibStub:GetLibrary("CallbackHandler-1.0"):New(IncHeals)

-- Validation for passed arguments
if( not IncHeals.tooltip ) then
	local tooltip = CreateFrame("GameTooltip")
	tooltip:SetOwner(UIParent, "ANCHOR_NONE")
	for i=1, 8 do
		tooltip["TextLeft" .. i] = tooltip:CreateFontString()
		tooltip["TextRight" .. i] = tooltip:CreateFontString()
		tooltip:AddFontStrings(tooltip["TextLeft" .. i], tooltip["TextRight" .. i])
	end
	
	IncHeals.tooltip = tooltip
end

-- APIs
function IncHeals:GetModifier(guid)
	return IncHeals.activeModifiers[guid] or 1
end

-- Healing class data
local currentRelicID, spellData, talentData
local function loadDruidData()
	spellData = {}
	talentData = {}
	
	-- Spell data
	--[[
	-- Tranquility, have to decide how to handle this. It should likely be considered a hot instead of a "heal" every X seconds
	local Tranquility = GetSpellInfo(740)
	spellData[Tranquility] = {level = {30, 40, 50, 60, 70, 75, 80}, type = "hot"},
	-- Rejuvenation
	local Rejuvenation = GetSpellInfo(774)
	spellData[Rejuvenation] = {level = {4, 10, 16, 22, 28, 34, 40, 46, 52, 58, 60, 63, 69, 75, 80}, type = "hot"}
	-- Lifebloom, another fun spell. How do you consider the bloom, would that be considered a normal heal at the end? Maybe
	-- Blizzard should delete Druids and make this easier
	local Lifebloom = GetSpellInfo(33763)
	spellData[Lifebloom] = {level = {64, 72, 80}, type = "hot"}
	-- Wild Growth, another fun spell. The events will either need to support a list of hot ticks... or something like that
	local WildGrowth = GetSpellInfo(48438)
	spellData[WildGrowth] = {level = {60, 70, 75, 80}, type = "hot"}
	]]

	-- Regrowth, this will be a bit of an annoying spell to handle once HOT support is added
	local Regrowth = GetSpellInfo(8936)
	spellData[Regrowth] = {level = {12, 18, 24, 30, 36, 42, 48, 54, 60, 65, 71, 77}, type = "heal"}
	-- Heaing Touch
	local HealingTouch = GetSpellInfo(5185)
	spellData[HealingTouch] = {level = {1, 8, 14, 20, 26, 32, 38, 44, 50, 56, 60, 62, 69, 74, 79}, type = "heal"}
	-- Nourish
	local Nourish = GetSpellInfo(50464)
	spellData[Nourish] = {level = {80}, type = "heal"}
	
	-- Talent data, these are filled in later and modified on talent changes
	-- Master Shapeshifter
	talentData[GetSpellInfo(48411)] = {tree = 3, mod = 0.02}
	-- Gift of Nature
	talentData[GetSpellInfo(17104)] = {tree = 3, mod = 0.02}
end

-- Healing modifiers
IncHeals.activeModifiers = IncHeals.activeModifiers or {}

if( not IncHeals.activeAuras ) then
	IncHeals.activeAuras = setmetatable({}, {
		__index = function(tbl, index)
			tbl[index] = {}
			return tbl[index]
		end,
	})
end

-- These are fun spells, they are long term so we can't exactly rely on the combat log as much
-- UNIT_AURA has more info
IncHeals.longAuras = {
	-- Demon Armor
	[GetSpellInfo(687)] = function(name) return name and 1.20 end,
	-- Tenacity
	[GetSpellInfo(58549)] = function(name, rank, icon, stack) return name and stack ^ 1.18 end
}

-- Grace: 47930, 3% * stack

IncHeals.selfModifiers = IncHeals.selfModifiers or {
	[64849] = 0.75, -- Unrelenting Assault
	[64850] = 0.50, -- Unrelenting Assault
	[65925] = 0.50, -- Unrelenting Assault
	[66011] = 1.20, -- Avenging Wrath
}

IncHeals.healingModifiers = IncHeals.healingModifiers or {
	[30843] = 0.00, -- Enfeeble
	[41292] = 0.00, -- Aura of Suffering
	[59513] = 0.00, -- Embrace of the Vampyr
	[55593] = 0.00, -- Necrotic Aura
	[28776] = 0.10, -- Necrotic Poison (Heroic)
	[34625] = 0.25, -- Demolish
	[34366] = 0.25, -- Ebon Poison
	[19716] = 0.25, -- Gehennas' Curse
	[24674] = 0.25, -- Veil of Shadow
	[54121] = 0.25, -- Necrotic Poison (Non heroic)
	[GetSpellInfo(13218)] = 0.50, -- Wound Poison
	[GetSpellInfo(20900)] = 0.50, -- Aimed Shot
	[GetSpellInfo(21551)] = 0.50, -- Mortal Strike
	[40599] = 0.50, -- Arcing Smash
	[36917] = 0.50, -- Magma-Throwser's Curse
	[23169] = 0.50, -- Brood Affliction: Green
	[GetSpellInfo(22859)] = 0.50, -- Mortal Cleave
	[36023] = 0.50, -- Deathblow
	[36054] = 0.50, -- Deathblow
	[13583] = 0.50, -- Curse of the Deadwood
	[32378] = 0.50, -- Filet
	[35189] = 0.50, -- Solar Strike
	[32315] = 0.50, -- Soul Strike
	[60084] = 0.50, -- The Veil of Shadow
	[45885] = 0.50, -- Shadow Spike
	[63038] = 0.75, -- Dark Volley
	[52771] = 0.75, -- Wounding Strike
	[59525] = 0.85, -- Ray of Pain
	[54525] = 0.80, -- Shroud of Darkness (This might be wrong)
	[48301] = 0.80, -- Mind Trauma (Improved Mind Blast)
	[68391] = 0.80, -- Permafrost, the debuff is generic no way of seeing 7/13/20, go with 20
	[34073] = 0.85, -- Curse of the Bleeding Hollow
	[43410] = 0.90, -- Chop
	[34123] = 1.06, -- Tree of Life
	[64844] = 1.10, -- Divine Hymn
	[38387] = 1.50, -- Bane of Infinity
	[31977] = 1.50, -- Curse of Infinity
	[41350] = 2.00, -- Aura of Desire
}

IncHeals.healingStacks = IncHeals.healingStacks or {
	[45237] = 0.03, -- Focused Will (Rank 1)
	[45241] = 0.04, -- Focused Will (Rank 2)
	[45242] = 0.05, -- Focused Will (Rank 3)
}

IncHeals.debuffStacks = IncHeals.debuffStacks or {
	[60626] = 0.10, -- Necrotic Strike
	[28467] = 0.10, -- Mortal Wound
	[45347] = 0.04, -- Dark Touched
	[30423] = 0.01, -- Nether Portal - Dominance
}
		
-- Get the average heal amount and cache it
-- We don't need to reset this table on spell change
if( not IncHeals.healAverage ) then
	IncHeals.healAverage = setmetatable({}, {
		__index = function(tbl, index)
			-- Find the spell from the spell book and cache the results!
			local offset, numSpells = select(3, GetSpellTabInfo(GetNumSpellTabs()))
			for id=1, (offset + numSpells) do
				-- Match, yay!
				local spellName, spellRank = GetSpellName(id, BOOKTYPE_SPELL)
				local name = spellName .. spellRank
				if( index == name ) then
					IncHeals.tooltip:SetSpell(id, BOOKTYPE_SPELL)
					
					-- Check last line for the spell info
					local text = IncHeals.tooltip["TextLeft" .. IncHeals.tooltip:NumLines()]
					if( text ) then
						-- The ..? is to match one to two characters between two numbers to be localization independant
						local minHeal, maxHeal = string.match(text:GetText(), "(%d+) ..? (%d+)")
						minHeal = tonumber(minHeal) or 0
						maxHeal = tonumber(maxHeal) or 0
						
						local average = (minHeal + maxHeal) / 2
						
						tbl[index] = average
						return tbl[index]
					end
				end
			end
			
			tbl[index] = false
			return false
		end,
	})
end

local glyphCache = IncHeals.glyphCache
local healingModifiers, longAuras = IncHeals.healingModifiers, IncHeals.longAuras
local activeAuras, activeModifiers = IncHeals.activeAuras, IncHeals.activeModifiers
local healingStacks, debuffStacks = IncHeals.healingStacks, IncHeals.debuffStacks
local distribution, instanceType

local function sendMessage(msg)
	SendAddonMessage(COMM_PREFIX, msg, distribution)
end

-- Figure out where we should be sending messages and wipe some caches
function IncHeals:ZONE_CHANGED_NEW_AREA()
	local type = select(2, IsInInstance())
	if( type ~= instanceType ) then
		distribution = ( type == "pvp" or type == "arena" ) and "BATTLEGROUND" or "RAID"
				
		for _, auras in pairs(activeAuras) do
			for k in pairs(auras) do auras[k] = nil end
		end
	end
	
	instanceType = type
end

-- Calculate the healing modifier
local function recalculateModifiers(guid)
	local increase, decrease = 1, 1
	for _, modifier in pairs(activeAuras[guid]) do
		if( modifier >= 1 ) then
			increase = increase * modifier
		else
			decrease = math.min(decrease, modifier)
		end
	end
		
	-- Check if modifier changed, send it off if so
	local modifier = increase * decrease
	if( activeModifiers[guid] ~= modifier ) then
		print("Modifier changed", guid, modifier, increase, decrease)
		IncHeals.callbacks:Fire("IncHeal_ModifierChanged", guid, modifier)
		activeModifiers[guid] = modifier
	end
end

-- This is hackish, the problem is some spells last too long to be something done while in combat, so instead I have to check certain auras
-- in UNIT_AURA because that way it's known for sure it's accurate. Every other debuff is something that 99% of the time is something we have
-- to be in range for.
function IncHeals:UNIT_AURA(unit)
	if( not UnitIsPlayer(unit) or ( not UnitPlayerOrPetInParty(unit) and not UnitPlayerOrPetInRaid(unit) ) ) then return end
	
	local guid = UnitGUID(unit)
	for name, func in pairs(longAuras) do
		local modifier = func(UnitBuff(unit, name))
		if( ( modifier and not activeAuras[guid][name] ) or ( modifier and not activeAuras[guid][name] ) ) then
			activeAuras[guid][name] = modifier
			recalculateModifiers(guid)
		end
	end
end

-- Monitor aura changes
local GROUPED_FILTER = bit.bor(COMBATLOG_OBJECT_AFFILIATION_PARTY, COMBATLOG_OBJECT_AFFILIATION_RAID, COMBATLOG_OBJECT_AFFILIATION_MINE)
local eventRegistered = {["SPELL_AURA_APPLIED_DOSE"] = true, ["SPELL_AURA_REMOVED"] = true, ["SPELL_AURA_APPLIED"] = true}
function IncHeals:COMBAT_LOG_EVENT_UNFILTERED(timestamp, eventType, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, ...)
	if( not eventRegistered[eventType] or bit.band(sourceFlags, GROUPED_FILTER) == 0 ) then return end
				
	-- Enemy buff faded
	if( eventType == "SPELL_AURA_APPLIED" ) then
		local spellID, spellName, spellSchool, auraType = ...
		local modifier = healingModifiers[spellID] or healingModifiers[spellName]
		if( modifier ) then
			activeAuras[sourceGUID][spellID] = modifier
			recalculateModifiers(sourceGUID)
		end
			
	-- Spell stacked
	elseif( ( eventType == "SPELL_AURA_APPLIED_DOSE" or eventType == "SPELL_AURA_REMOVED_DOSE" ) ) then
		local spellID, spellName, spellSchool, auraType, stackCount = ...
		if( healingStacks[spellID] ) then
			activeAuras[sourceGUID][spellID] = 1.0 + (healingStacks[spellID] * 2)
		elseif( debuffStacks[spellID] ) then
			activeAuras[sourceGUID][spellID] = 1.0 - (debuffStacks[spellID] * 2)
		end
		
	-- Spell casted succesfully
	elseif( eventType == "SPELL_AURA_REMOVED" ) then
		local spellID, spellName, spellSchool, auraType = ...
		if( healingModifiers[spellID] or healingModifiers[spellName] ) then
			activeAuras[sourceGUID][spellID] = nil
			recalculateModifiers(sourceGUID)
		end
	end
end


function IncHeals:GlyphsUpdated(id)
	local spellID = glyphCache[id]
	
	-- Invalidate the old cache value
	if( spellID ) then
		glyphCache[spellID] = nil
		glyphCache[id] = nil
	end
	
	-- Cache the new one if any
	local enabled, _, glyphID = GetGlyphSocketInfo(id)
	if( enabled ) then
		glyphCache[glyphID] = true
		glyphCache[id] = glyphID
	end
end

-- As spell tooltips don't seem to change with talents, when our spells change all we have to do is invalidate the false ones
-- This fires for each spell and each rank that is trained, although you only really notice it if you're using a mod like Talented or dual specs
function IncHeals:LEARNED_SPELL_IN_TAB()
	for spell, amount in pairs(self.healAverage) do
		if( amount == false ) then
			self.healAverage[spell] = nil
		end
	end
end

-- Cache player talent data for spells we need
function IncHeals:PLAYER_TALENT_UPDATE()
	for tabIndex=1, GetNumTalentTabs() do
		for i=1, GetNumTalents(tabIndex) do
			local name, _, _, _, spent = GetTalentInfo(tabIndex, i)
			if( name and talentData[name] ) then
				talentData[name].current = talentData[name].mod * spent
			end
		end
	end
end

-- Save the currently equipped range weapon
local RANGED_SLOT = GetInventorySlotInfo("RangedSlot")
function IncHeals:UNIT_RANGEDDAMAGE(unit)
	if( unit ~= "player" ) then return end
	
	currentRelicID = GetInventoryItemLink("player", RANGED_SLOT)
	if( currentRelicID ) then
		currentRelicID = tonumber(string.match(currentRelicID, "item:(%d+):"))
	end
end

-- Spell cast magic
local castStart, castUnit, castGUID, castID, checkUnitID, targetUnit, actionUnit
function IncHeals:UNIT_SPELLCAST_SENT(unit, spellName, rank, castOn)
	if( unit ~= "player" or not self.healAverage[spellName .. rank] ) then return end
	targetUnit = nil
	
	-- Might be able to use castOn and UnitName as long as a UnitIsPlayer check is used
	-- it seems that in battlegrounds it uses the person with the lowest health with that name
	-- if it prioritizes players over non-players then it works fine as an accurate GUID detector 95% of the time
	if( checkUnitID ) then
		if( checkUnitID == spellName ) then
			castGUID = UnitCanAssist("player", "target") and UnitGUID("target") or mouseoverGUID
			targetUnit = GetTime() + 0.01
		end
		
		checkUnitID = nil
	end
end

function IncHeals:UNIT_SPELLCAST_START(unit, spellName, rank, id)
	if( unit ~= "player" or not self.healAverage[spellName .. rank] ) then return end
	if( castGUID ) then
		print("Casting", spellName, rank, castGUID)
	else
		print("Failed to find GUID", spellName, rank)
	end
	
	castID = id
	castGUID = nil
end

function IncHeals:UNIT_SPELLCAST_SUCCEEDED(unit, spellName, rank, id)
	if( unit ~= "player" or id ~= castID ) then return end
end

function IncHeals:UNIT_SPELLCAST_STOP(unit, spellName, rank, id)
	if( unit ~= "player" or id ~= castID ) then return end
	castGUID = nil
end

function IncHeals:UNIT_SPELLCAST_CHANNEL_STOP(unit, spellName, rank)
	if( unit ~= "player" ) then return end
	castGUID = nil
end

-- Need to keep track of mouseover as it can change in the split second after/before casts
function IncHeals:UPDATE_MOUSEOVER_UNIT()
	mouseoverGUID = UnitCanAssist("player", "mouseover") and UnitGUID("mouseover")
end

-- TargetUnit is used when a spell is waiting for a target and someone uses a key binding
function IncHeals:TargetUnit(unit)
	if( targetUnit and GetTime() < targetUnit ) then
		castGUID = UnitGUID(unit)
		targetUnit = nil	
	end
end

-- This is called by the secure code when you have a cursor waiting for a cast then click on a secure frame
-- with the "target" attribute set, but not when you use a target keybinding. Basically, if this is called
-- we know that this is the unit it's being cast on without a doubt
function IncHeals:SpellTargetUnit(unit)
	checkUnitID = nil
	castGUID = UnitGUID(unit)
end

-- This is called pretty much no matter what, the only time it's not for a click casting or buttons coded specifically
-- with a macro or spell cast into them instead of an action button
function IncHeals:UseAction(action, unit)
	-- If the spell is waiting for a target and it's a spell action button then we know
	-- that the GUID has to be mouseover or a key binding cast, macros and such call CastSpellBy*
	if( SpellIsTargeting() ) then
		local type, _, _, spellID = GetActionInfo(action)
		if( type == "spell" ) then
			checkUnitID = GetSpellInfo(spellID)
		end
	-- Specifically got a unit to cast this on, generally happens for things like binding self or focus casts
	elseif( unit ) then
		castGUID = UnitGUID(unit)
	-- Nothing else, meaning it pretty much has to be a target
	elseif( not castGUID ) then
		castGUID = UnitCanAssist("player", "target") and UnitGUID("target") or GetCVarBool("autoSelfCast") and UnitGUID("player")
	end
end

-- These are called by hardcoded casts in a button and by the macro system
function IncHeals:CastSpellByID(spellID, unit)
	if( not unit and not UnitExists("mouseover") ) then
		checkUnitID = GetSpellInfo(spellName)
	elseif( unit ) then
		checkUnitID = nil
		castGUID = UnitGUID(unit)
	end
end

function IncHeals:CastSpellByName(spellName, unit)
	-- If we don't know the unit, and mouseover doesn't exist then it's either being cast on the player through the 3D world
	-- or it's being cast through a key binding
	if( not unit and not UnitExists("mouseover") ) then
		checkUnitID = spellName
	elseif( unit ) then
		checkUnitID = nil
		castGUID = UnitGUID(unit)
	end
end

function IncHeals:PLAYER_ALIVE()
	self:PLAYER_TALENT_UPDATE()
	self.frame:UnregisterEvent("PLAYER_ALIVE")
end

-- Initialize the library
function IncHeals:OnInitialize()
	if( self.initialized ) then return end
	self.initialized = true
	
	-- Load class data
	local class = select(2, UnitClass("player"))
	if( class == "DRUID" ) then
		loadDruidData()
	elseif( class == "SHAMAN" ) then
	
	elseif( class == "PALADIN" ) then
	
	elseif( class == "PRIEST" ) then
	
	-- Have to be ready for the next expansion!
	--elseif( class == "DEATHKNIGHT" ) then
	end
	
	-- Cache glyphs initially
    for id=1, GetNumGlyphSockets() do
		local enabled, _, glyphID = GetGlyphSocketInfo(id)
		if( enabled ) then
			glyphCache[glyphID] = true
			glyphCache[id] = glyphID
		end
	end
	
	-- Figure out the initial relic
	self:UNIT_RANGEDDAMAGE("player")
	
	-- When first logging in talent data isn't available until at least PLAYER_ALIVE, so if we don't have data
	-- will wait for that event otherwise will just cache it right now
	if( GetNumTalentTabs() == 0 ) then
		self.frame:RegisterEvent("PLAYER_ALIVE")
	else
		self:PLAYER_TALENT_UPDATE()
	end
	
	-- You can't unhook secure hooks after they are done, so will hook once and the IncHeals table will update with the latest functions
	-- automagically. If a new function is ever used it'll need a specific variable to indicate those set of hooks.
	hooksecurefunc("TargetUnit", function(...)
		IncHeals:TargetUnit(...)
	end)

	hooksecurefunc("SpellTargetUnit", function(...)
		IncHeals:SpellTargetUnit(...)
	end)

	hooksecurefunc("UseAction", function(...)
		IncHeals:UseAction(...)
	end)

	hooksecurefunc("CastSpellByID", function(...)
		IncHeals:CastSpellByID(...)
	end)

	hooksecurefunc("CastSpellByName", function(...)
		IncHeals:CastSpellByName(...)
	end)
end

-- General event handler
local function OnEvent(self, event, ...)
	if( event == "GLYPH_ADDED" or event == "GLYPH_REMOVED" or event == "GLYPH_UPDATED" ) then
		IncHeals:GlyphsUpdated(...)
	else
		IncHeals[event](IncHeals, ...)
	end
end

-- Event handler
IncHeals.frame = IncHeals.frame or CreateFrame("Frame")
IncHeals.frame:UnregisterAllEvents()
IncHeals.frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
IncHeals.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
IncHeals.frame:RegisterEvent("UNIT_AURA")
IncHeals.frame:SetScript("OnEvent", OnEvent)

-- If they aren't a healer, all they need to know about are modifier changes
local playerClass = select(2, UnitClass("player"))
--if( playerClass ~= "DRUID" and playerClass ~= "PRIEST" and playerClass ~= "SHAMAN" and playerClass ~= "PALADIN" ) then
if( playerClass ~= "DRUID" ) then
	return
end

IncHeals.frame:RegisterEvent("UNIT_SPELLCAST_SENT")
IncHeals.frame:RegisterEvent("UNIT_SPELLCAST_START")
IncHeals.frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
IncHeals.frame:RegisterEvent("UNIT_SPELLCAST_STOP")
IncHeals.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
IncHeals.frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
IncHeals.frame:RegisterEvent("PLAYER_TALENT_UPDATE")
IncHeals.frame:RegisterEvent("LEARNED_SPELL_IN_TAB")
IncHeals.frame:RegisterEvent("GLYPH_ADDED")
IncHeals.frame:RegisterEvent("GLYPH_REMOVED")
IncHeals.frame:RegisterEvent("GLYPH_UPDATED")
IncHeals.frame:RegisterEvent("UNIT_RANGEDDAMAGE")

-- If the player is not logged in yet, then we're still loading and will watch for PLAYER_LOGIN to assume everything is initialized
-- if we're already logged in then it was probably LOD loaded
function IncHeals:PLAYER_LOGIN()
	self:OnInitialize()
	self.frame:UnregisterEvent("PLAYER_LOGIN")
end

if( not IsLoggedIn() ) then
	IncHeals.frame:RegisterEvent("PLAYER_LOGIN")
else
	IncHeals:OnInitialize()
end
