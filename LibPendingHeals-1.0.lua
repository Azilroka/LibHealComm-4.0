local major = "LibPendingHeals-1.0"
local minor = 1
assert(LibStub, string.format("%s requires LibStub.", major))

local PendHeals = LibStub:NewLibrary(major, minor)
if( not PendHeals ) then return end

-- This needs to be bumped if there is a major change that breaks the comm format
local COMM_PREFIX = "LPH10"
local playerGUID

PendHeals.callbacks = PendHeals.callbacks or LibStub:GetLibrary("CallbackHandler-1.0"):New(PendHeals)

PendHeals.glyphCache = PendHeals.glyphCache or {}
PendHeals.playerModifiers = PendHeals.playerModifiers or {}
PendHeals.guidToGroup = PendHeals.guidToGroup or {}
PendHeals.guidToUnit = PendHeals.guidToUnit or {}

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
						local minHeal, maxHeal = string.match(text:GetText(), "(%d+) ..? (%d+)")
						minHeal = tonumber(minHeal)
						maxHeal = tonumber(maxHeal)
						
						if( minHeal and maxHeal ) then
							local average = (minHeal + maxHeal) / 2
							
							tbl[index] = average
							return tbl[index]
						else
							tbl[index] = false
							return tbl[index]
						end
					end
				end
			end
			
			tbl[index] = false
			return false
		end,
	})
end

-- APIs
function PendHeals:GetModifier(guid)
	return PendHeals.currentModifiers[guid] or 1
end

-- Healing class data
-- Thanks to Gagorian (DrDamage) for letting me steal his formulas and such
local playerModifiers, averageHeal, rankNumbers, glyphCache = PendHeals.playerModifiers, PendHeals.averageHeal, PendHeals.rankNumbers, PendHeals.glyphCache
local guidToUnit, guidToGroup = PendHeals.guidToUnit, PendHeals.guidToGroup
local currentRelicID, CalculateHealing, GetHealTargets, AuraHandler
local spellData, talentData, equippedSetPieces, itemSetsData = {}, {}, {}, {}
local playerHealModifier = 1

-- UnitBuff priortizes our buffs over everyone elses when there is a name conflict, so yay for that
local function unitHasAura(unit, name)
	local caster = select(8, UnitBuff(unit, name))
	
	-- Does caster ever return anything but player? Pretty sure it won't in this case
	-- not like we can get heals while in an active vehicle
	return caster and UnitIsUnit(caster, "player")
end

-- This is slightly confusing. It seems that there are still two penalties, one for using spells below 20 and another for downranking
-- in general, as downranking in general isn't really an issue for now, I'll skip that check and keep the <20 one in until I know for sure
-- that they are both still active.
--local function calculateDownRank(spellName, rank)
--	local level = rank and spellData.level[rank]
--	return level and level < 20 and (1 - ((20 - level) * 0.375)) or 1
--end

-- DRUIDS
-- All data is accurate as of 3.2.0 (build 10192)
local function loadDruidData()
	-- Spell data
	local Rejuvenation = GetSpellInfo(774)
	local Lifebloom = GetSpellInfo(33763)
	local WildGrowth = GetSpellInfo(48438)
	local TreeofLife = GetSpellInfo(5420)

	--[[
	-- Tranquility, have to decide how to handle this. It should likely be considered a hot instead of a "heal" every X seconds
	local Tranquility = GetSpellInfo(740)
	spellData[Tranquility] = {level = {30, 40, 50, 60, 70, 75, 80}, type = "hot"},
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
	spellData[Regrowth] = {level = {12, 18, 24, 30, 36, 42, 48, 54, 60, 65, 71, 77}, coeff = 0.2867}
	-- Heaing Touch
	local HealingTouch = GetSpellInfo(5185)
	spellData[HealingTouch] = {level = {1, 8, 14, 20, 26, 32, 38, 44, 50, 56, 60, 62, 69, 74, 79}}
	-- Nourish
	local Nourish = GetSpellInfo(50464)
	spellData[Nourish] = {level = {80}, coeff = 0.358005}
	
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
	
	--[[
		Idols
		
		40711 - Idol of Lush Moss, 125 LB per tick SP
		36366 - Idol of Pure Thoughts, +33 SP per Rejuv tick
		27886 - Idol of the Emerald Queen, +47 per LB Tick
		25643 - Harold's Rejuvenation Broach, +86 Rejuv total
		22398 - Idol of rejuvenation, +50 SP to Rejuv
	]]
	
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
		return guid
	end
	
	CalculateHealing = function(guid, spellName, spellRank)
		local healAmount = PendHeals.averageHeal[spellName .. spellRank]
		local spellPower = GetSpellBonusHealing()
		local multiModifier, addModifier = 1, 1
		local rank = PendHeals.rankNumbers[spellRank]
		
		-- Gift of Nature
		addModifier = 1.0 + talentData[GiftofNature].current
		
		-- Master Shapeshifter does not apply directly when using Lifebloom
		if( unitHasAura("player", TreeofLife) ) then
			multiModifier = multiModifier * (1 + talentData[MasterShapeshifter].current)
			
			-- 32387 - Idol of the Raven Godess, +44 SP while in TOL
			if( currentRelicID == 32387 ) then
				spellPower = spellPower + 44
			end
		end
		
		if( spellName == Regrowth ) then
			-- Glyph of Regrowth - +20% if target has Regrowth
			if( glyphCache[54743] and auraData[guid] ) then
				multiModifier = multiModifier * 1.20
			end
			
			spellPower = spellPower * ((spellData[Regrowth].coeff * 1.88) * (1 + talentData[EmpoweredRejuv].current))
		
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
			
			spellPower = spellPower * ((spellData[Nourish].coeff * 1.88) + talentData[EmpoweredTouch].spent * 0.10)

		elseif( spellName == HealingTouch ) then
			-- 28568 - Idol of the Avian Heart, 136 base healing to Healing Touch
			if( currentRelicID == 28568 ) then
				healAmount = healAmount + 136
			-- 22399 - Idol of Health, 100 base healing to Healing Touch
			elseif( currentRelicID == 22399 ) then
				healAmount = healAmount + 100
			end
			
			-- Glyph of Healing Touch, -50% healing
			if( glyphCache[54825] ) then
				multiModifier = multiModifier * 0.50
			end

			-- Rank 1 - 3: 1.5/2/2.5 cast time, Rank 4+: 3 cast time
			local castTime = rank > 3 and 3 or rank == 3 and 2.5 or rank == 2 and 2 or rank == 1 and 1.5
			spellPower = spellPower * (((castTime / 3.5) * 1.88) + talentData[EmpoweredTouch].current)
		end

		-- Note because I always forget:
		-- Multiplictive modifiers are applied to the spell power after all other calculations
		-- Additive modifiers are applied to the end amount after all calculations
		if( spellData[spellName].level[rank] < 20 ) then
			multiModifier = multiModifier * (1 - ((20 - spellData[spellName].level[rank]) * 0.0375))
		end
		
		healAmount = addModifier * (healAmount + spellPower * multiModifier)
		
		-- 100% chance to crit with Nature, this mostly just covers fights like Loatheb where you will basically have 100% crit
		if( GetSpellCritChance(4) >= 100 ) then
			healAmount = healAmount * 1.50
		end
		
		return "heal", math.ceil(healAmount * playerHealModifier)
	end
end

-- PALADINS
-- All data is accurate as of 3.2.0 (build 10192)
local function loadPaladinData()
	-- Spell data
	local HolyLight = GetSpellInfo(635)
	spellData[HolyLight] = {level = {1, 6, 14, 22, 30, 38, 46, 54, 60, 62, 70, 75, 80}, coeff = 1.66 / 1.88}
	local FlashofLight = GetSpellInfo(19750)
	spellData[FlashofLight] = {level = {20, 26, 34, 42, 50, 58, 66, 74, 79}, coeff = 1.009/1.88}
	
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
	
	local favorThrottle = 0

	-- Am I slightly crazy for adding level <40 glyphs? Yes!
	local flashLibrams = {[42615] = 375, [42614] = 331, [42613] = 293, [42612] = 204, [25644] = 79, [23006] = 43, [23201] = 28}
	local holyLibrams = {[45436] = 160, [40268] = 141, [28296] = 47}
		
	-- Need the GUID of whoever has beacon on them so we can make sure they are visible to us and so we can check the mapping
	local activeBeaconGUID
	AuraHandler = function(guid, unit)
		if( unitHasAura(unit, BeaconofLight) ) then
			activeBeaconGUID = guid
		elseif( activeBeaconGUID == guid ) then
			activeBeaconGUID = nil
		end
	end
	
	-- Check for beacon when figuring out who to heal
	GetHealTargets = function(guid, healAmount, spellName, spellRank)
		if( activeBeaconGUID and activeBeaconGUID ~= guid and guidToUnit[activeBeaconGUID] and UnitExists(guidToUnit[activeBeaconGUID]) ) then
			return guid .. "," .. activeBeaconGUID
		end
		
		return guid
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
		addModifier = addModifier + talentData[HealingLight].current
		
		if( currentRelicID ) then
			if( spellName == HolyLight and holyLibrams[currentRelicID] ) then
				spellPower = spellPower + holyLibrams[currentRelicID]
			elseif( spellName == FlashofLight and flashLibrams[currentRelicID] ) then
				spellPower = spellPower + flashLibrams[currentRelicID]
			end
		end
		
		spellPower = spellPower * (spellData[spellName].coeff * 1.88)
		
		-- Note because I always forget:
		-- Multiplictive modifiers are applied to the spell power after all other calculations
		-- Additive modifiers are applied to the end amount after all calculations
		if( spellData[spellName].level[rank] < 20 ) then
			multiModifier = multiModifier * (1 - ((20 - spellData[spellName].level[rank]) * 0.0375))
		end
		
		healAmount = addModifier * (healAmount + spellPower * multiModifier)

		-- Divine Favor is 100% chance to crit, so assume they crit, if the user casts Divine Favor and 
		-- Going to add this in but need to solve a problem: If the player casts favor, casts a spell then "queue casts"
		-- another spell, it will think both of them are crits, it's probably going to have to flag a spell as having "used"
		-- favor until the spell is interrupted or it finishes.
		--if( unitHasAura("player", DivineFavor) and favorThrottle < GetTime() ) then
		--	healAmount = healAmount * 1.50
		
		-- Or the player has over a 95% chance to crit with Holy spells
		if( GetSpellCritChance(2) >= 100 ) then
			healAmount = healAmount * 1.50
		end
	
		return "heal", math.ceil(healAmount * playerHealModifier)
	end
end

-- PRIESTS
-- All data except Penance is accurate as of 3.2.0 (build 10192)
local function loadPriestData()
	-- Spell data
	local GreaterHeal = GetSpellInfo(2060)
	spellData[GreaterHeal] = {level = {40, 46, 52, 58, 60, 63, 68, 73, 78}, coeff = 3 / 3.5}
	local PrayerofHealing = GetSpellInfo(596)
	spellData[PrayerofHealing] = {level = {30, 40, 50, 60, 60, 68, 76}, coeff = 0.2798}
	local FlashHeal = GetSpellInfo(2061)
	spellData[FlashHeal] = {level = {20, 26, 32, 38, 44, 52, 58, 61, 67, 73, 79}, coeff = 1.5 / 3.5}
	local BindingHeal = GetSpellInfo(32546)
	spellData[BindingHeal] = {level = {64, 72, 78}, coeff = 1.5 / 3.5}
	local Penance = GetSpellInfo(53007)
	spellData[Penance] = {level = {60, 70, 75, 80}, coeff = 0.857}
	
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
		if( caster and UnitIsUnit(caster, "player") ) then
			activeGraceModifier = stack * 0.03
			activeGraceGUID = guid
		elseif( activeGraceGUID == guid ) then
			activeGraceGUID = nil
		end
	end
	
	-- Check for beacon when figuring out who to heal
	GetHealTargets = function(guid, healAmount, spellName, spellRank)
		if( spellName == BindingHeal ) then
			return guid .. "," .. playerGUID
		elseif( spellName == PrayerofHealing ) then
			local list = guid
			
			local group = PendHeals.guidToGroup[guid]
			for guid, id in pairs(PendHeals.guidToGroup) do
				if( UnitExists(PendHeals.guidToUnit[guid]) ) then
					list = list .. "," .. guid
				end
			end
			
			return list
		end
		
		return guid
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
		
		addModifier = addModifier + talentData[SpiritualHealing].current
		addModifier = addModifier + talentData[FocusedPower].current
		multiModifier = multiModifier * (1 + talentData[BlessedResilience].current)
		
		-- Greater Heal
		if( spellName == GreaterHeal ) then
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) + talentData[EmpoweredHealing].current)
		-- Flash Heal
		elseif( spellName == FlashHeal ) then
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) + talentData[EmpoweredHealing].spent * 0.04)
		-- Binding Heal
		elseif( spellName == BindingHeal ) then
			addModifier = addModifier + talentData[DivineProvidence].current
			spellPower = spellPower * ((spellData[spellName].coeff * 1.88) + talentData[EmpoweredHealing].spent * 0.04)
		-- Penance
		elseif( spellName == Penance ) then
			spellPower = spellPower * (spellData[spellName].coeff * 1.88)
		-- Prayer of Heaing
		elseif( spellName == PrayerofHealing ) then
			addModifier = addModifier + talentData[DivineProvidence].current
			spellPower = spellPower * (spellData[spellName].coeff * 1.88)
		end
		
		-- Note because I always forget:
		-- Multiplictive modifiers are applied to the spell power after all other calculations
		-- Additive modifiers are applied to the end amount after all calculations
		if( spellData[spellName].level[rank] < 20 ) then
			multiModifier = multiModifier * (1 - ((20 - spellData[spellName].level[rank]) * 0.0375))
		end
		
		healAmount = addModifier * (healAmount + spellPower * multiModifier)

		-- Player has over a 95% chance to crit with Holy spells
		if( GetSpellCritChance(2) >= 100 ) then
			healAmount = healAmount * 1.50
		end
		
		-- Apply the final modifier of any MS or self heal increasing effects
		healAmount = math.ceil(healAmount * playerHealModifier)
		
		-- As Penance doesn't actually heal for it's amount instantly, send it as a pulse heal
		-- even thought Penance ticks 3 times, the first one is instant and will heal before the comm message gets there, so pretend it's two heals
		if( spellName == Penance ) then
			return "pulse", healAmount, 2
		end
				
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
local distribution, instanceType

local function sendMessage(msg)
	SendAddonMessage(COMM_PREFIX, msg, distribution)
end

-- Figure out where we should be sending messages and wipe some caches
function PendHeals:ZONE_CHANGED_NEW_AREA()
	local type = select(2, IsInInstance())
	if( type ~= instanceType ) then
		distribution = ( type == "pvp" or type == "arena" ) and "BATTLEGROUND" or "RAID"
			
		-- Changes the value of Necrotic Poison based on zone type, if there are more difficulty type MS's I'll support those too
		-- Heroic = 90%, Non-Heroic = 75%
		if( GetRaidDifficulty() == 2 or GetRaidDifficulty() == 4 ) then
			healingModifiers[GetSpellInfo(53121)] = 0.95
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
-- on the other hand, I hate having to keep a table for every single GUID we are tracking. :|
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
	if( AuraHandler ) then
		AuraHandler(guid, unit)
	end
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

-- As spell tooltips don't seem to change with talents, when our spells change all we have to do is invalidate the false ones
-- This fires for each spell and each rank that is trained, although you only really notice it if you're using a mod like Talented or dual specs
function PendHeals:LEARNED_SPELL_IN_TAB()
	for spell, amount in pairs(self.averageHeal) do
		if( amount == false ) then
			self.averageHeal[spell] = nil
		end
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
	currentRelicID = GetInventoryItemLink("player", RANGED_SLOT)
	if( currentRelicID ) then
		currentRelicID = tonumber(string.match(currentRelicID, "item:(%d+):"))
	end
end

-- Spell cast magic
-- When auto self cast is on, the UNIT_SPELLCAST_SENT event will always come first followed by the funciton calls
-- Otherwise either SENT comes first then function calls, or some function calls then SENT then more function calls
local guidPriority, castGUID, castID, targetUnit, mouseoverGUID, castName, targetTimer, hadTargetingCursor

-- Deals with the fact that functions are called differently, priorities are basically:
-- 1 = might be it, 2 = should be it, 3 = definitely it
local function setCastData(priority, guid)
	if( not guid or ( guidPriority and guidPriority >= priority ) ) then return end
		
	castGUID = guid
	guidPriority = priority
end

-- When the game tries to figure out the UnitID from the name it will prioritize players over non-players
-- if there are conflicts in names it will pull the one with the least amount of current health

-- This would be another way of getting GUIDs, by keeping a map and marking conflicts due to pets (or vehicles)
-- we would know that you can't rely on the name exactly and that the other methods are needed. While they seem
-- to be accurate and not have any issues, it could be a good solution as a better safe than sorry option.
function PendHeals:UNIT_SPELLCAST_SENT(unit, spellName, spellRank, castOn)
	if( unit ~= "player" or not spellData[spellName] or not self.averageHeal[spellName .. spellRank] ) then return end

	-- Self cast is off which means it's possible to have a spell waiting for a target.
	-- It's possible that it's the mouseover unit, but if we see a *TargetUnit call then we know it's that unit for sure
	if( not GetCVarBool("autoSelfCast") or hadTargetingCursor ) then
		hadTargetingCursor = nil
		self.resetFrame:Show()
		
		setCastData(1, mouseoverGUID)
	end
	
	-- As per above, this is our last ditch effort to get a GUID
	setCastData(0, UnitGUID(castOn))
end

function PendHeals:UNIT_SPELLCAST_START(unit, spellName, spellRank, id)
	if( unit ~= "player" or not spellData[spellName] or not self.averageHeal[spellName .. spellRank] ) then return end

	-- CalculateHeaing figures out the actual heal amount
	local type, amount, ticks = CalculateHealing(castGUID, spellName, spellRank)
	-- GetHealTargets will figure out who the heal is supposed to land on
	print(spellName, spellRank, type, amount, ticks, GetHealTargets(castGUID, amount, spellName, spellRank))
	
	castID = id
	castGUID = nil
	guidPriority = nil
end

function PendHeals:UNIT_SPELLCAST_CHANNEL_START(...)
	self:UNIT_SPELLCAST_START(...)
end

function PendHeals:UNIT_SPELLCAST_STOP(unit, spellName, spellRank, id)
	if( unit ~= "player" or id ~= castID ) then return end
	
	-- Fire a comm message saying the spellcast stopped
	print("Spell cast done", spellName, spellRank)
end

function PendHeals:UNIT_SPELLCAST_CHANNEL_STOP(unit, spellName, spellRank)
	if( unit ~= "player" ) then return end
	print("Spell cast done", spellName, spellRank)
end

-- Need to keep track of mouseover as it can change in the split second after/before casts
function PendHeals:UPDATE_MOUSEOVER_UNIT()
	mouseoverGUID = UnitCanAssist("player", "mouseover") and UnitGUID("mouseover")
	
	-- This might be necessary if I want to account for the fact that some people do world PVP, but it only matters
	-- if the healing target is ungrouped
	--if( not UnitExists(UnitName("mouseover")) ) then
	--	self:UNIT_AURA("mouseover")
	--end
end


-- This is only needed when auto self cast is off, in which case this is called right after UNIT_SPELLCAST_SENT
-- because the player got a waiting-for-cast icon up and they pressed a key binding to target someone
function PendHeals:TargetUnit(unit)
	if( self.resetFrame:IsShown() and UnitCanAssist("player", unit) ) then
		setCastData(3, UnitGUID(unit))
	end

	self.resetFrame:Hide()
	hadTargetingCursor = nil
end

-- Works the same as the above except it's called when you have a cursor icon and you click on a secure frame with a target attribute set
function PendHeals:SpellTargetUnit(unit)
	if( self.resetFrame:IsShown() and UnitCanAssist("player", unit) ) then
		setCastData(3, UnitGUID(unit))
	end
	
	self.resetFrame:Hide()
	hadTargetingCursor = nil
end

-- Called whenever an action button is clicked, this is generally the last of a function chain, CastSpellBy* is called first.
function PendHeals:UseAction(action, unit)
	-- If the spell is waiting for a target and it's a spell action button then we know that the GUID has to be mouseover or a key binding cast.
	if( unit and UnitCanAssist("player", unit)  ) then
		setCastData(3, UnitGUID(unit))
	-- No unit, or it's a unit we can't assist 
	elseif( not SpellIsTargeting() ) then
		setCastData(2, UnitCanAssist("player", "target") and UnitGUID("target") or playerGUID)
		hadTargetingCursor = nil
	else
		hadTargetingCursor = true
	end
end

-- These are called by hardcoded casts in a button and by the macro system
function PendHeals:CastSpellByID(spellID, unit)
	if( unit and UnitCanAssist("player", unit)  ) then
		setCastData(3, UnitGUID(unit))
	elseif( not SpellIsTargeting() ) then
		setCastData(2, UnitCanAssist("player", "target") and UnitGUID("target") or playerGUID)
		hadTargetingCursor = nil
	else
		hadTargetingCursor = true
	end
end

function PendHeals:CastSpellByName(spellName, unit)
	if( unit and UnitCanAssist("player", unit) ) then
		setCastData(3, UnitGUID(unit))
	elseif( not SpellIsTargeting() ) then
		setCastData(2, UnitCanAssist("player", "target") and UnitGUID("target") or playerGUID)
		hadTargetingCursor = nil
	else
		hadTargetingCursor = true
	end
end

-- Make sure we don't have invalid units in this
local function sanityCheckMapping()
	for guid, unit in pairs(PendHeals.guidToUnit) do
		if( UnitGUID(unit) ~= guid ) then
			PendHeals.guidToUnit[guid] = nil
			PendHeals.guidToGroup[guid] = nil
		end
	end
end

-- Keeps track of pet GUIDs, pets are considered vehicles too so this lets us map a GUID to vehicles
function PendHeals:UNIT_PET(unit)
	unit = unit == "player" and "pet" or unit .. "pet"
	
	local guid = UnitGUID(unit)
	if( guid ) then
		self.guidToUnit[guid] = unit
	end
end

-- Keep track of party GUIDs, ignored in raids as RRU will handle that mapping
local wasInParty, wasInRaid
function PendHeals:PARTY_MEMBERS_CHANGED()
	if( GetNumRaidMembers() > 0 ) then return end
	
	if( GetNumPartyMembers() == 0 ) then
		table.wipe(self.guidToUnit)
		tablew.wipe(self.guidToGroup)
		
		self.guidToUnit[playerGUID] = "player"

		wasInParty = nil
		wasInRaid = nil
		return
	end
	
	-- Because parties do not have "real" groups, we will simply pretend they are all in group 0
	self.guidtoGroup[playerGUID] = 0
	
	for i=1, MAX_PARTY_MEMBERS do
		local unit = "party" .. i
		if( UnitExists(unit) ) then
			local guid = UnitGUID(unit)
			self.guidToUnit[guid] = unit
			self.guidToGroup[guid] = 0
			
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
	-- Left raid, clear any cache we had
	if( GetNumRaidMembers() == 0 ) then
		table.wipe(self.guidToUnit)
		table.wipe(self.guidToGroup)

		self.guidToUnit[playerGUID] = "player"
		wasInRaid = nil
		wasInParty = nil
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
	
	wasInRaid = true
	sanityCheckMapping()
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
	self.guidToUnit[playerGUID] = "player"
	
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
	
	-- This resets the target timer next OnUpdate, the user would basically have to press the target button twice within
	-- <0.10 seconds, more like <0.05 to be able to bug it out
	self.resetFrame = self.resetFrame or CreateFrame("Frame")
	self.resetFrame:Hide()
	self.resetFrame:SetScript("OnUpdate", function(self)
		self:Hide()
	end)
	
	-- You can't unhook secure hooks after they are done, so will hook once and the PendHeals table will update with the latest functions
	-- automagically. If a new function is ever used it'll need a specific variable to indicate those set of hooks.
	hooksecurefunc("TargetUnit", function(...)
		--print(GetTime(), "TargetUnit", UnitExists("mouseover"), ...)
		PendHeals:TargetUnit(...)
	end)

	hooksecurefunc("SpellTargetUnit", function(...)
		--print(GetTime(), "SpellTargetUnit", UnitExists("mouseover"), ...)
		PendHeals:SpellTargetUnit(...)
	end)

	hooksecurefunc("UseAction", function(...)
		--print(GetTime(), "UseAction", UnitExists("mouseover"), ...)
		PendHeals:UseAction(...)
	end)

	hooksecurefunc("CastSpellByID", function(...)
		--print(GetTime(), "CastSPellByID", UnitExists("mouseover"), ...)
		PendHeals:CastSpellByID(...)
	end)

	hooksecurefunc("CastSpellByName", function(...)
		--print(GetTime(), "CastSpellByName", UnitExists("mouseover"), ...)
		PendHeals:CastSpellByName(...)
	end)
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
PendHeals.frame:RegisterEvent("UNIT_AURA")
PendHeals.frame:SetScript("OnEvent", OnEvent)

-- If they aren't a healer, all they need to know about are modifier changes
local playerClass = select(2, UnitClass("player"))
--if( playerClass ~= "DRUID" and playerClass ~= "PRIEST" and playerClass ~= "SHAMAN" and playerClass ~= "PALADIN" ) then
if( playerClass ~= "DRUID" and playerClass ~= "PALADIN" and playerClass ~= "PRIEST" ) then
	return
end

PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_SENT")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_START")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_STOP")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
PendHeals.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
PendHeals.frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
PendHeals.frame:RegisterEvent("PLAYER_TALENT_UPDATE")
PendHeals.frame:RegisterEvent("LEARNED_SPELL_IN_TAB")
PendHeals.frame:RegisterEvent("GLYPH_ADDED")
PendHeals.frame:RegisterEvent("GLYPH_REMOVED")
PendHeals.frame:RegisterEvent("GLYPH_UPDATED")
PendHeals.frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
PendHeals.frame:RegisterEvent("RAID_ROSTER_UPDATE")
PendHeals.frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
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
