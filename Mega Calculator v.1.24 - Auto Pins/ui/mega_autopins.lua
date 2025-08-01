--  ===========================================================
--  Mega Auto Pins  v1.28        (2025-08-02)
--    * blocks districts on bonus / luxury / strategic resources
--    * global 4-tile distance check (includes CS & AI cities)
--    * verbose aqueduct rejection logging
--    * yield-aware city-site scoring (hooks DMT if present)
--    * skips suggesting a district if city already has it (unique replacements included)
--    * city-site pins only on unowned land (no settling in existing borders)
--    * Maya civilization: capital proximity yields accounted in city site scoring
--  ===========================================================
print("mega_autopins: v1.28 loading")

-- Optional link-up with Detailed Map Tacks yield engine.
pcall(function() include("dmt_yieldcalculator") end)

local LOG_PREFIX   = "mega_autopins: "
local function dbg(msg) print(LOG_PREFIX .. tostring(msg)) end

local ACTION_ID    = Input.GetActionId("Mega_ToggleAutoPins")
local isOn         = false
local localPlayer  = -1
local PIN_PREFIX   = "[MEGA]"

-- -------- Config --------
local MIN_CITY_DISTANCE       = 4   -- tiles
local NEXTCITY_MIN_PERCENT    = 80  -- ≥ % of best to list
local NEXTCITY_MAX_PER_PLAYER = 6
local MAX_SETTLER_DISTANCE    = 10  -- from nearest owned city

local ICONS = {
  CITY    = "ICON_DISTRICT_CITY_CENTER",
  CAMPUS  = "ICON_DISTRICT_CAMPUS",
  THEATER = "ICON_MAP_PIN_DISTRICT_THEATER", -- consistent fallback
  HUB     = "ICON_DISTRICT_COMMERCIAL_HUB",
  HARBOR  = "ICON_DISTRICT_HARBOR",
  IZ      = "ICON_DISTRICT_INDUSTRIAL_ZONE",
  EC      = "ICON_DISTRICT_ENTERTAINMENT_COMPLEX",
  AQ      = "ICON_DISTRICT_AQUEDUCT",
}

-- -------- Civ detection (special heuristics) --------
local function isPlayerCiv(pid, civ)
  local pc = PlayerConfigurations[pid]
  return pc and pc:GetCivilizationTypeName() == civ
end
local function isPlayerInca(pid)
  local pc = PlayerConfigurations[pid]
  return pc and pc:GetCivilizationTypeName() == "CIVILIZATION_INCA"
end
local isInca,isBrazil,isJapan,isGermany,isGaul,isKorea,isMaya = false,false,false,false,false,false,false

-- District type indices for base and unique districts
local idxCampus      = GameInfo.Districts["DISTRICT_CAMPUS"].Index
local idxSeowon      = GameInfo.Districts["DISTRICT_SEOWON"] and GameInfo.Districts["DISTRICT_SEOWON"].Index or -1
local idxObservatory = GameInfo.Districts["DISTRICT_OBSERVATORY"] and GameInfo.Districts["DISTRICT_OBSERVATORY"].Index or -1
local idxHub         = GameInfo.Districts["DISTRICT_COMMERCIAL_HUB"].Index
local idxHarbor      = GameInfo.Districts["DISTRICT_HARBOR"].Index
local idxRND         = GameInfo.Districts["DISTRICT_ROYAL_NAVY_DOCKYARD"] and GameInfo.Districts["DISTRICT_ROYAL_NAVY_DOCKYARD"].Index or -1
local idxTheater     = GameInfo.Districts["DISTRICT_THEATER_SQUARE"] and GameInfo.Districts["DISTRICT_THEATER_SQUARE"].Index or GameInfo.Districts["DISTRICT_THEATER"].Index
local idxAcropolis   = GameInfo.Districts["DISTRICT_ACROPOLIS"] and GameInfo.Districts["DISTRICT_ACROPOLIS"].Index or -1
local idxIZ          = GameInfo.Districts["DISTRICT_INDUSTRIAL_ZONE"].Index
local idxHansa       = GameInfo.Districts["DISTRICT_HANSA"] and GameInfo.Districts["DISTRICT_HANSA"].Index or -1
local idxOppidum     = GameInfo.Districts["DISTRICT_OPPIDUM"] and GameInfo.Districts["DISTRICT_OPPIDUM"].Index or -1
local idxEC          = GameInfo.Districts["DISTRICT_ENTERTAINMENT_COMPLEX"].Index
local idxCarnival    = GameInfo.Districts["DISTRICT_STREET_CARNIVAL"] and GameInfo.Districts["DISTRICT_STREET_CARNIVAL"].Index or -1
local idxAqueduct    = GameInfo.Districts["DISTRICT_AQUEDUCT"].Index
local idxBath        = GameInfo.Districts["DISTRICT_BATH"] and GameInfo.Districts["DISTRICT_BATH"].Index or -1

-- -------- General helpers --------
local function toast(tag)
  local txt = (Locale and Locale.Lookup and Locale.Lookup(tag)) or tag
  if UI and UI.AddWorldViewText then UI.AddWorldViewText(0, txt, -1, -1, 0) end
end

local function visible(p)
  if not p then return false end
  if localPlayer == -1 then return false end
  local pv = PlayersVisibility and PlayersVisibility[localPlayer]
  return (not pv) or pv:IsRevealed(p:GetIndex())
end

local function AdjacentPlots(x, y) return Map.GetAdjacentPlots(x, y) or {} end

-- Ownership helper: allow our tiles or unowned, block enemy/CS land
local function isOwnedByPlayerOrUnowned(city, p)
  if not p or not city then return false end
  local owner = p:GetOwner()
  return owner == -1 or owner == city:GetOwner()
end

-- Resource-aware check: rejects bonus, luxury, and strategic tiles
local function canHostDistrictBasic(p)
  if not p then return false end
  if p:IsWater() or p:IsMountain() or p:IsImpassable() then return false end
  if p:GetDistrictType() ~= -1 or p:GetWonderType() ~= -1 then return false end
  local r = p:GetResourceType()
  if r and r ~= -1 then
    local class = GameInfo.Resources[r].ResourceClassType
    if class == "RESOURCECLASS_BONUS"
       or class == "RESOURCECLASS_LUXURY"
       or class == "RESOURCECLASS_STRATEGIC" then
      return false
    end
  end
  return true
end

local function within3OfCity(city, p)
  return Map.GetPlotDistance(city:GetX(), city:GetY(), p:GetX(), p:GetY()) <= 3
end

local function countAdj(x, y, fn)
  local c = 0
  for _, q in ipairs(AdjacentPlots(x, y)) do
    if q and fn(q) then c = c + 1 end
  end
  return c
end

-- -------- Global 4-tile distance check (includes CS) --------
local function minCityDistanceOK(plot)
  for _, pl in pairs(Players) do
    if pl and pl:GetCities() then
      for _, city in pl:GetCities():Members() do
        local d = Map.GetPlotDistance(plot:GetX(), plot:GetY(), city:GetX(), city:GetY())
        if d < MIN_CITY_DISTANCE then
          local kind = Players[city:GetOwner()]:IsMinor() and "city-state" or "player city"
          dbg("Rejected city site – too close to "..kind.." ("..d.." tiles)")
          return false
        end
      end
    end
  end
  return true
end

-- -------- Cheap yield proxy (uses DMT if available) --------
local function plotYieldScore(p)
  if DMT and DMT.GetRealizedPlotFeatures then
    local feats = DMT.GetRealizedPlotFeatures(localPlayer, p, nil)
    return (feats.Food or 0)
       + 1.5*(feats.Production or 0)
       +       (feats.Gold or 0)
       + 2.0*(feats.Science or 0)
       + 1.5*(feats.Culture or 0)
       +       (feats.Faith or 0)
  end
  return 0
end

local function getResourceYield(p)
  local r = p:GetResourceType()
  if not r or r == -1 then return 0 end
  local resInfo = GameInfo.Resources[r]
  if not resInfo then return 0 end
  local y = (resInfo.Food or 0) + (resInfo.Production or 0) + (resInfo.Gold or 0)
  return y
end

-- Helper: Check if plot is near an Industrial Zone (IZ)
local function isNearIndustry(plot)
  for dx = -3, 3 do
    for dy = -3, 3 do
      local q = Map.GetPlotXYWithRangeCheck(plot:GetX(), plot:GetY(), dx, dy, 3)
      if q and q:GetDistrictType() ~= -1 then
        local d = q:GetDistrictType()
        if d ~= -1 and GameInfo.Districts[d].DistrictType == "DISTRICT_INDUSTRIAL_ZONE" then
          return true
        end
      end
    end
  end
  return false
end

-- Enhanced canHostDistrict: allow resource removal if beneficial
local function canHostDistrictWithResourceAnalysis(p, scoreFunc)
  if not p then return false, nil end
  if p:IsWater() or p:IsMountain() or p:IsImpassable() then return false, nil end
  if p:GetDistrictType() ~= -1 or p:GetWonderType() ~= -1 then return false, nil end
  local r = p:GetResourceType()
  if r and r ~= -1 then
    local class = GameInfo.Resources[r].ResourceClassType
    if class == "RESOURCECLASS_BONUS"
       or class == "RESOURCECLASS_LUXURY"
       or class == "RESOURCECLASS_STRATEGIC" then
      local districtScore = scoreFunc(p)
      local resourceYield = getResourceYield(p)
      if districtScore > resourceYield then
        dbg(("Resource removal recommended at (%d,%d): district yield %d > resource yield %d"):format(p:GetX(), p:GetY(), districtScore, resourceYield))
        return true, true
      else
        return false, nil
      end
    end
  end
  return true, nil
end

-- ===========================================================
--  DISTRICT-SCORING FUNCTIONS
-- ===========================================================

-- ---------- Campus ----------
local function scoreCampus(p)
  local x, y = p:GetX(), p:GetY()
  local s = 0
  -- base: mountains, reefs, jungle/rainforest, districts
  local m = countAdj(x, y, function(q) return q:IsMountain() end)
  local r = countAdj(x, y, function(q)
    local f = q:GetFeatureType()
    return f ~= -1 and GameInfo.Features[f].FeatureType == "FEATURE_REEF"
  end)
  local jr = countAdj(x, y, function(q)
    local f = q:GetFeatureType()
    if f == -1 then return false end
    local k = GameInfo.Features[f].FeatureType
    return k == "FEATURE_JUNGLE" or k == "FEATURE_RAINFOREST"
  end)
  local distAdj = math.floor(countAdj(x, y, function(q) return q:GetDistrictType() ~= -1 end) / 2)

  s = s + m + r + jr + distAdj

  -- civ tweaks
  if isBrazil then
    local jungle = countAdj(x, y, function(q)
      local f = q:GetFeatureType()
      return f ~= -1 and GameInfo.Features[f].FeatureType == "FEATURE_JUNGLE"
    end)
    s = s + jungle
  end
  if isKorea then
    local dpen = countAdj(x, y, function(q) return q:GetDistrictType() ~= -1 end)
    s = s - dpen
  end
  if isJapan then
    local dbonus = countAdj(x, y, function(q) return q:GetDistrictType() ~= -1 end)
    s = s + dbonus
  end
  if isInca and p:IsHills() then
    local adjM = countAdj(x, y, function(q) return q:IsMountain() end)
    if adjM >= 2 then s = s - 4 end
  end
  if isGaul then
    local adjCity = countAdj(x, y, function(q)
      local d = q:GetDistrictType()
      return d ~= -1 and GameInfo.Districts[d].CityCenter
    end)
    if adjCity > 0 then s = s - 3 end
  end

  dbg(("Campus (%d,%d) score=%d"):format(x, y, s))
  return s
end

-- ---------- Theater ----------
local function scoreTheater(p)
  local x, y = p:GetX(), p:GetY()
  local s = 0
  s = s + 2 * countAdj(x, y, function(q) return q:GetWonderType() ~= -1 end)
  s = s +     countAdj(x, y, function(q) return q:GetDistrictType() ~= -1 end)
  if isJapan then
    s = s + countAdj(x, y, function(q) return q:GetDistrictType() ~= -1 end)
  end
  dbg(("Theater (%d,%d) score=%d"):format(x, y, s))
  return s
end

-- ---------- Commercial Hub ----------
local function scoreHub(p)
  local x, y = p:GetX(), p:GetY()
  local s = 0
  if p:IsRiver() then s = s + 2 end
  s = s + countAdj(x, y, function(q) return q:GetDistrictType() ~= -1 end)
  s = s + countAdj(x, y, function(q)
    local d = q:GetDistrictType()
    return d ~= -1 and GameInfo.Districts[d].DistrictType == "DISTRICT_HARBOR"
  end)
  if isGermany then
    local clearLand = countAdj(x, y, function(q)
      return (not q:IsWater()) and (not q:IsMountain()) and (q:GetDistrictType() == -1)
    end)
    s = s + clearLand -- Hansa synergy
  end
  if isJapan then
    s = s + countAdj(x, y, function(q) return q:GetDistrictType() ~= -1 end)
  end
  dbg(("Hub (%d,%d) score=%d"):format(x, y, s))
  return s
end

-- ---------- Harbor ----------
local function harborIsLegalForCityTile(hplot, city)
  if not hplot or not hplot:IsWater() then return false end
  local cx, cy = city:GetX(), city:GetY()
  for _, q in ipairs(AdjacentPlots(hplot:GetX(), hplot:GetY())) do
    if q then
      local d = q:GetDistrictType()
      if d ~= -1 and GameInfo.Districts[d].DistrictType == "DISTRICT_CITY_CENTER"
         and q:GetX() == cx and q:GetY() == cy then
        return true
      end
    end
  end
  return false
end

local function scoreHarbor(p, city)
  if not harborIsLegalForCityTile(p, city) then return -999 end
  local s = 0
  s = s + countAdj(p:GetX(), p:GetY(), function(q) return q:GetResourceType() ~= -1 end)
  s = s + countAdj(p:GetX(), p:GetY(), function(q)
    local f = q:GetFeatureType()
    return f ~= -1 and GameInfo.Features[f].FeatureType == "FEATURE_REEF"
  end)
  return s
end

-- ---------- Industrial Zone ----------
local function countImprovements(x, y, tbl)
  return countAdj(x, y, function(q)
    local imp = q:GetImprovementType()
    if imp == -1 then return false end
    return tbl[GameInfo.Improvements[imp].ImprovementType] == true
  end)
end

local function scoreIZ(p)
  local x, y = p:GetX(), p:GetY()
  local s = 0
  s = s + countImprovements(x, y, {
        ["IMPROVEMENT_MINE"]   = true,
        ["IMPROVEMENT_QUARRY"] = true,
      })
  s = s + 2 * countAdj(x, y, function(q)
          local d = q:GetDistrictType()
          if d == -1 then return false end
          local dt = GameInfo.Districts[d].DistrictType
          return dt == "DISTRICT_AQUEDUCT" or dt == "DISTRICT_DAM"
        end)
  if isGermany then
    s = s + 2 * countAdj(x, y, function(q)
            local d = q:GetDistrictType()
            return d ~= -1 and GameInfo.Districts[d].DistrictType == "DISTRICT_COMMERCIAL_HUB"
          end)
    s = s +     countAdj(x, y, function(q)
            local r = q:GetResourceType()
            if not r or r == -1 then return false end
            local cls = GameInfo.Resources[r].ResourceClassType
            return cls == "RESOURCECLASS_BONUS" or cls == "RESOURCECLASS_STRATEGIC"
          end)
  end
  dbg(("IZ (%d,%d) score=%d"):format(x, y, s))
  return s
end

-- ---------- Entertainment Complex ----------
local function scoreEC(p)
  local seen = {}
  for _, city in Players[localPlayer]:GetCities():Members() do
    local d = Map.GetPlotDistance(p:GetX(), p:GetY(), city:GetX(), city:GetY())
    if d <= 6 then seen[city:GetID()] = true end
  end
  local c = 0
  for _ in pairs(seen) do c = c + 1 end
  return c
end

-- ---------- Aqueduct helper ----------
local function isAqueductLegal(p)
  local x, y = p:GetX(), p:GetY()
  local adjCity, hasSource = false, false
  for _, q in ipairs(AdjacentPlots(x, y)) do
    if q then
      local d = q:GetDistrictType()
      if d ~= -1 and GameInfo.Districts[d].DistrictType == "DISTRICT_CITY_CENTER" then
        adjCity = true
      end
      if q:IsRiver() or q:IsLake() or q:IsMountain() then hasSource = true end
      local f = q:GetFeatureType()
      if f ~= -1 and GameInfo.Features[f].FeatureType == "FEATURE_OASIS" then
        hasSource = true
      end
    end
  end
  return adjCity and hasSource
end

-- ===========================================================
--  CITY-SITE SCORING  (uses yields + heuristics)
-- ===========================================================
local function nearestOwnedCityDistance(p)
  local best = 999
  for _, city in Players[localPlayer]:GetCities():Members() do
    local d = Map.GetPlotDistance(p:GetX(), p:GetY(), city:GetX(), city:GetY())
    if d < best then best = d end
  end
  return best
end

local function scoreCitySite(plot)
  if not plot or not visible(plot) then return -999 end
  if plot:IsWater() or plot:IsMountain() or plot:IsImpassable() then return -999 end
  if plot:GetDistrictType() ~= -1 or plot:GetWonderType() ~= -1 then return -999 end
  if plot:GetOwner() ~= -1 then return -999 end
  if not minCityDistanceOK(plot) then return -999 end
  if nearestOwnedCityDistance(plot) > MAX_SETTLER_DISTANCE then return -999 end

  local s = 0

  -- fresh water
  local fresh = plot:IsRiver() or plot:IsLake()
  if not fresh then
    for _, q in ipairs(AdjacentPlots(plot:GetX(), plot:GetY())) do
      local f = q and q:GetFeatureType()
      if f ~= -1 and GameInfo.Features[f].FeatureType == "FEATURE_OASIS" then
        fresh = true; break
      end
    end
  end
  if fresh then s = s + 20 end

  -- resources ring 1 / ring 2
  s = s + 6 * countAdj(plot:GetX(), plot:GetY(), function(q)
          return q:GetResourceType() ~= -1
        end)
  for dx = -2, 2 do
    for dy = -2, 2 do
      local q = Map.GetPlotXYWithRangeCheck(plot:GetX(), plot:GetY(), dx, dy, 2)
      if q and visible(q)
         and Map.GetPlotDistance(plot:GetX(), plot:GetY(), q:GetX(), q:GetY()) == 2
         and q:GetResourceType() ~= -1 then
        s = s + 3
      end
    end
  end

  -- terrain goodies
  s = s + 2 * countAdj(plot:GetX(), plot:GetY(), function(q) return q:IsHills() end)
  s = s + 2 * countAdj(plot:GetX(), plot:GetY(), function(q)
          local f = q:GetFeatureType()
          if f == -1 then return false end
          local k = GameInfo.Features[f].FeatureType
          return k == "FEATURE_REEF" or k == "FEATURE_JUNGLE" or k == "FEATURE_RAINFOREST"
        end)

  if plot:IsCoastalLand() then
    s = s + 4
    s = s + countAdj(plot:GetX(), plot:GetY(), function(q)
          return q:IsWater() and q:GetResourceType() ~= -1
        end)
  end

  -- yield proxy bonus
  local yld = plotYieldScore(plot)
  s = s + yld

  -- Maya capital proximity
  if isMaya then
    local capCity = Players[localPlayer]:GetCities():GetCapitalCity()
    if capCity then
      local capDist = Map.GetPlotDistance(capCity:GetX(), capCity:GetY(), plot:GetX(), plot:GetY())
      if capDist <= 6 then
        s = s + 10
        dbg(("CitySite (%d,%d) Maya bonus: within 6 of capital (distance %d)"):format(plot:GetX(), plot:GetY(), capDist))
      elseif capDist > 6 then
        s = s - 15
        dbg(("CitySite (%d,%d) Maya penalty: %d tiles from capital"):format(plot:GetX(), plot:GetY(), capDist))
      end
    end
  end

  -- Industry adjacency bonus
  if isNearIndustry(plot) then
    s = s + 8
    dbg(("CitySite (%d,%d) gets Industry adjacency bonus"):format(plot:GetX(), plot:GetY()))
  end

  dbg(("CitySite (%d,%d) score=%d (+yield %.1f)"):format(plot:GetX(), plot:GetY(), s, yld))
  return s
end

-- ===========================================================
--  Candidate collection
-- ===========================================================
local function collectCandidateSites()
  local cands, best = {}, -999
  local seen = {}
  for _, city in Players[localPlayer]:GetCities():Members() do
    local cx, cy = city:GetX(), city:GetY()
    for dx = -12, 12 do
      for dy = -12, 12 do
        local p = Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 12)
        if p and visible(p) then
          local idx = p:GetIndex()
          if not seen[idx] then
            seen[idx] = true
            local sc = scoreCitySite(p)
            if sc > -999 then
              cands[#cands + 1] = { plot = p, score = sc }
              if sc > best then best = sc end
            end
          end
        end
      end
    end
  end
  return cands, best
end

-- ===========================================================
--  Pin helpers
-- ===========================================================
local function cfg()
  dbg("cfg() called, localPlayer="..tostring(localPlayer))
  return PlayerConfigurations[localPlayer]
end

local function setIconSafe(pin, icon)
  if not pin or not pin.SetIconName then return end
  if icon == "ICON_MAP_PIN_DISTRICT_THEATER"
     or icon == "ICON_DISTRICT_THEATER"
     or icon == "ICON_DISTRICT_THEATER_SQUARE" then
    pin:SetIconName("ICON_MAP_PIN_DISTRICT_THEATER")
  else
    pin:SetIconName(icon)
  end
end

function ensurePinAt(x, y, icon, name)
  local c = cfg(); if not c then dbg("cfg() returned nil!"); return false end
  local ex = c.GetMapPin and c:GetMapPin(x, y)
  if ex and ex.SetIconName then
    setIconSafe(ex, icon)
    if ex.SetName then
      ex:SetName(name or PIN_PREFIX)
    else
      dbg("Warning: Pin at ("..x..","..y..") could not set name!")
    end
    if c.UpdateMapPin then c:UpdateMapPin(ex) end
    if LuaEvents and LuaEvents.DMT_MapPinAdded then LuaEvents.DMT_MapPinAdded(ex) end
    dbg("UpdatePin: "..(name or PIN_PREFIX).." @("..x..","..y..")")
    return true
  end

  -- create new
  local pin = nil
  if c.AddMapPinAt then pin = c:AddMapPinAt(x, y) end
  if type(pin) == "number" and c.GetMapPinByID then pin = c:GetMapPinByID(pin) end
  if not pin and c.AddMapPin then pin = c:AddMapPin(x, y) end
  if type(pin) == "number" and c.GetMapPinByID then pin = c:GetMapPinByID(pin) end
  if not pin then dbg("Failed to create pin at ("..x..","..y..")"); return false end

  setIconSafe(pin, icon)
  if pin.SetName then
    pin:SetName(name or PIN_PREFIX)
  else
    dbg("Warning: Pin at ("..x..","..y..") could not set name!")
  end
  if c.UpdateMapPin then c:UpdateMapPin(pin) end
  if Network and Network.BroadcastPlayerInfo then Network.BroadcastPlayerInfo() end
  if LuaEvents and LuaEvents.DMT_MapPinAdded then
    local mp = c:GetMapPin(x, y)
    if mp then LuaEvents.DMT_MapPinAdded(mp) end
  end
  dbg("CreatePin: "..(name or PIN_PREFIX).." @("..x..","..y..")")
  return true
end

local function clearOurPins()
  local c = cfg(); if not c or not c.GetMapPins then return end
  local del, ICONSET = {}, {}
  for _, v in pairs(ICONS) do ICONSET[v] = true end
  for _, pin in pairs(c:GetMapPins()) do
    local nm = (pin.GetName and pin:GetName()) or ""
    local ic = (pin.GetIconName and pin:GetIconName()) or ""
    if nm:sub(1, #PIN_PREFIX) == PIN_PREFIX
       or nm:sub(1, 10) == "NEXT CITY "
       or ICONSET[ic] then
      del[#del + 1] = pin:GetID()
    end
  end
  for _, id in ipairs(del) do
    local mp = c.GetMapPinByID and c:GetMapPinByID(id)
    if LuaEvents and LuaEvents.DMT_MapPinRemoved and mp then LuaEvents.DMT_MapPinRemoved(mp) end
    c:DeleteMapPin(id)
  end
  if Network and Network.BroadcastPlayerInfo then Network.BroadcastPlayerInfo() end
  dbg("Cleared "..#del.." pins")
end

-- ===========================================================
--  Placement helpers & city-specific logic
-- ===========================================================
local function isPlotBlocked(p, used, city)
  if not p then return true end
  if used and used[p:GetIndex()] then return true end
  if p:GetDistrictType() ~= -1 then return true end
  if city and not isOwnedByPlayerOrUnowned(city, p) then return true end
  return false
end

local function bestPlotAround(city, radius, scoreFunc, minWanted, used)
  local cx, cy = city:GetX(), city:GetY()
  local bestP, best, recommendRemoval = nil, -999, false
  if type(scoreFunc) ~= "function" then
    dbg("ERROR: bestPlotAround called with nil or non-function scoreFunc!")
    return nil, -999, false
  end
  for dx = -radius, radius do
    for dy = -radius, radius do
      local p = Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, radius)
      if p and visible(p) and not isPlotBlocked(p, used, city)
         and within3OfCity(city, p) then
        local canPlace, removal = canHostDistrictWithResourceAnalysis(p, scoreFunc)
        if canPlace then
          local sc = scoreFunc(p)
          local adjDistricts = countAdj(p:GetX(), p:GetY(), function(q)
            return q:GetDistrictType() ~= -1
          end)
          sc = sc + adjDistricts
          if sc >= minWanted and sc > best then
            best, bestP, recommendRemoval = sc, p, removal
          end
        end
      end
    end
  end
  return bestP, best, recommendRemoval
end

-- ---------- City-specific routine ----------
local function placeForCity(city, used)
  local cityDistricts = city:GetDistricts()
  local hasCampus    = cityDistricts:HasDistrict(idxCampus) or (idxSeowon ~= -1 and cityDistricts:HasDistrict(idxSeowon)) or (idxObservatory ~= -1 and cityDistricts:HasDistrict(idxObservatory))
  local hasHub       = cityDistricts:HasDistrict(idxHub)
  local hasHarbor    = cityDistricts:HasDistrict(idxHarbor) or (idxRND ~= -1 and cityDistricts:HasDistrict(idxRND))
  local hasTheater   = cityDistricts:HasDistrict(idxTheater) or (idxAcropolis ~= -1 and cityDistricts:HasDistrict(idxAcropolis))
  local hasIZ        = cityDistricts:HasDistrict(idxIZ) or (idxHansa ~= -1 and cityDistricts:HasDistrict(idxHansa)) or (idxOppidum ~= -1 and cityDistricts:HasDistrict(idxOppidum))
  local hasEC        = cityDistricts:HasDistrict(idxEC) or (idxCarnival ~= -1 and cityDistricts:HasDistrict(idxCarnival))
  local hasAqueduct  = cityDistricts:HasDistrict(idxAqueduct) or (idxBath ~= -1 and cityDistricts:HasDistrict(idxBath))
  local cx, cy = city:GetX(), city:GetY()

  -- Campus & Hub placement
  if (not hasCampus) and (not hasHub) then
    placeCampusHubSynergy(city, used)
  elseif (not hasCampus) and hasHub then
    -- City has Hub but no Campus
    local cP, cs, cRemove = bestPlotAround(city, 3, scoreCampus, 0, used)
    if cP then
      used[cP:GetIndex()] = true
      local name = PIN_PREFIX.." Campus "..cs
      if cRemove then name = name.." (remove resource)" end
      ensurePinAt(cP:GetX(), cP:GetY(), ICONS.CAMPUS, name)
      dbg(string.format("Placed Campus @%d,%d sc=%d", cP:GetX(), cP:GetY(), cs))
    end
  elseif hasCampus and (not hasHub) then
    -- City has Campus but no Hub
    local hP, hs, hRemove = bestPlotAround(city, 3, scoreHub, 0, used)
    if hP then
      used[hP:GetIndex()] = true
      local name = PIN_PREFIX.." Hub "..hs
      if hRemove then name = name.." (remove resource)" end
      ensurePinAt(hP:GetX(), hP:GetY(), ICONS.HUB, name)
      dbg(string.format("Placed Hub @%d,%d sc=%d", hP:GetX(), hP:GetY(), hs))
    end
  end

  -- Harbor (only one per city)
  if not hasHarbor then
    local harborPlaced = false
    for dx = -3, 3 do
      for dy = -3, 3 do
        local p = Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 3)
        if p and visible(p) and (not used[p:GetIndex()]) and p:IsWater()
           and isOwnedByPlayerOrUnowned(city, p)
           and p:GetDistrictType() == -1 and harborIsLegalForCityTile(p, city) then
          local sc = scoreHarbor(p, city)
          if sc >= 0 then
            used[p:GetIndex()] = true
            ensurePinAt(p:GetX(), p:GetY(), ICONS.HARBOR, PIN_PREFIX.." Harbor "..sc)
            dbg(string.format("Placed Harbor @%d,%d sc=%d", p:GetX(), p:GetY(), sc))
            harborPlaced = true
            break
          end
        end
      end
      if harborPlaced then break end
    end
  end

  -- Theater Square
  if not hasTheater then
    local tP, ts, tRemove = bestPlotAround(city, 3, scoreTheater, 0, used)
    if tP then
      used[tP:GetIndex()] = true
      local name = PIN_PREFIX.." Theater "..ts
      if tRemove then name = name.." (remove resource)" end
      ensurePinAt(tP:GetX(), tP:GetY(), ICONS.THEATER, name)
      dbg(string.format("Placed Theater @%d,%d sc=%d", tP:GetX(), tP:GetY(), ts))
    end
  end

  -- Industrial Zone
  if not hasIZ then
    local izP, izs, izRemove = bestPlotAround(city, 3, scoreIZ, 0, used)
    if izP then
      used[izP:GetIndex()] = true
      local name = PIN_PREFIX.." IZ "..izs
      if izRemove then name = name.." (remove resource)" end
      ensurePinAt(izP:GetX(), izP:GetY(), ICONS.IZ, name)
      dbg(string.format("Placed IZ @%d,%d sc=%d", izP:GetX(), izP:GetY(), izs))
    end
  end

  -- Entertainment Complex
  if not hasEC then
    local ecP, ecs, ecRemove = bestPlotAround(city, 3, scoreEC, 1, used)
    if ecP then
      used[ecP:GetIndex()] = true
      local name = PIN_PREFIX.." EC "..ecs
      if ecRemove then name = name.." (remove resource)" end
      ensurePinAt(ecP:GetX(), ecP:GetY(), ICONS.EC, name)
      dbg(string.format("Placed EC @%d,%d sc=%d", ecP:GetX(), ecP:GetY(), ecs))
    end
  end

  -- Aqueduct
  if not hasAqueduct then
    local aqBest = nil
    for dx = -3, 3 do
      for dy = -3, 3 do
        local p = Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 3)
        if p and visible(p) and (not used[p:GetIndex()]) and within3OfCity(city, p)
           and isOwnedByPlayerOrUnowned(city, p) then
          if not canHostDistrictBasic(p) then
            dbg(string.format("Aqueduct reject (%d,%d) – on resource / invalid", p:GetX(), p:GetY()))
          elseif not isAqueductLegal(p) then
            dbg(string.format("Aqueduct reject (%d,%d) – needs city+water", p:GetX(), p:GetY()))
          else
            aqBest = p; break
          end
        end
      end
      if aqBest then break end
    end
    if aqBest then
      used[aqBest:GetIndex()] = true
      ensurePinAt(aqBest:GetX(), aqBest:GetY(), ICONS.AQ, PIN_PREFIX.." Aqueduct 1")
      dbg(string.format("Placed Aqueduct @%d,%d", aqBest:GetX(), aqBest:GetY()))
    end
  end
end

-- ===========================================================
--  Next-city suggestions
-- ===========================================================
local function placeNextCityPins()
  local cands, best = collectCandidateSites()
  if best < 0 or #cands == 0 then
    dbg("NextCity: no candidates"); return
  end

  table.sort(cands, function(a, b) return a.score > b.score end)

  local placed, chosen = 0, {}
  local function farFromChosen(p)
    for _, ch in ipairs(chosen) do
      if Map.GetPlotDistance(p:GetX(), p:GetY(), ch.plot:GetX(), ch.plot:GetY()) < MIN_CITY_DISTANCE then
        return false
      end
    end
    return true
  end

  for _, item in ipairs(cands) do
    local pct = math.floor(100.0 * item.score / best + 0.5)
    if pct < NEXTCITY_MIN_PERCENT then
      dbg(("Reject site (%d,%d) %.0f%% < threshold"):format(item.plot:GetX(), item.plot:GetY(), pct))
    elseif not farFromChosen(item.plot) then
      dbg(("Reject site (%d,%d) – too close to another pick"):format(item.plot:GetX(), item.plot:GetY()))
    else
      local name = ("NEXT CITY [%d%%]"):format(pct)
      ensurePinAt(item.plot:GetX(), item.plot:GetY(), ICONS.CITY, name)
      dbg(("Placed NextCity @%d,%d score=%d"):format(item.plot:GetX(), item.plot:GetY(), item.score))
      chosen[#chosen+1] = item
      placed = placed + 1
      if placed >= NEXTCITY_MAX_PER_PLAYER then break end
    end
  end

  -- Fallback – always give at least one site
  if placed == 0 then
    local t = cands[1]
    local pct = math.floor(100.0 * t.score / best + 0.5)
    ensurePinAt(t.plot:GetX(), t.plot:GetY(), ICONS.CITY, ("NEXT CITY [%d%%]"):format(pct))
    dbg("Fallback: placed single best city site")
  end
  dbg(("NextCity placed %d (best=%d)"):format(placed, best))
end

-- ===========================================================
--  Top-level helpers
-- ===========================================================
local function placeAllPins()
  local pl = Players[localPlayer]; if not pl then return end
  local used = {}
  for _, city in pl:GetCities():Members() do
    placeForCity(city, used)
  end
  placeNextCityPins()
end

local function Toggle()
  isOn = not isOn
  if isOn then
    toast("LOC_MEGA_AUTOPINS_ON")
    clearOurPins()
    placeAllPins()
  else
    toast("LOC_MEGA_AUTOPINS_OFF")
    clearOurPins()
  end
end

-- ===========================================================
--  Input & init
-- ===========================================================
local function OnInputActionTriggered(id)
  dbg("Event: InputActionTriggered id="..tostring(id).." ACTION_ID="..tostring(ACTION_ID))
  if id == ACTION_ID then
    dbg("InputActionTriggered: Hotkey matched, toggling pins."); Toggle()
  end
end

local function OnInputHandler(pInput)
  dbg("Event: OnInputHandler called")
  if pInput:GetMessageType() == KeyEvents.KeyUp then
    dbg("KeyUp event detected")
    if pInput:GetKey() == Keys.G then
      dbg("Key G detected")
      if pInput:IsShiftDown() then
        dbg("Shift+G detected, toggling pins.")
        Toggle(); return true
      end
    end
  end
  return false
end

local function Initialize()
  dbg("Initialize called")
  localPlayer = Game.GetLocalPlayer() or -1
  dbg("localPlayer="..tostring(localPlayer))
  isInca    = isPlayerInca(localPlayer)
  isBrazil  = isPlayerCiv(localPlayer, "CIVILIZATION_BRAZIL")
  isJapan   = isPlayerCiv(localPlayer, "CIVILIZATION_JAPAN")
  isGermany = isPlayerCiv(localPlayer, "CIVILIZATION_GERMANY")
  isGaul    = isPlayerCiv(localPlayer, "CIVILIZATION_GAUL")
  isKorea   = isPlayerCiv(localPlayer, "CIVILIZATION_KOREA")
  isMaya    = isPlayerCiv(localPlayer, "CIVILIZATION_MAYA")

  if ContextPtr and ContextPtr.SetInputHandler then
    dbg("Registering input handler via ContextPtr")
    ContextPtr:SetInputHandler(OnInputHandler, true)
  else
    dbg("ContextPtr or SetInputHandler missing!")
  end
  if Events and Events.InputActionTriggered then
    dbg("Registering InputActionTriggered event")
    Events.InputActionTriggered.Add(OnInputActionTriggered)
  else
    dbg("Events or InputActionTriggered missing!")
  end
  if UI and UI.StatusMessage and Locale and Locale.Lookup then
    dbg("Showing status message: LOC_MEGA_AUTOPINS_READY")
    UI.StatusMessage(Locale.Lookup("LOC_MEGA_AUTOPINS_READY"))
  else
    dbg("UI/StatusMessage/Locale missing!")
  end

  dbg(("Initialized; player=%d Inca=%s"):format(localPlayer, tostring(isInca)))
end

Events.LoadGameViewStateDone.Add(Initialize)
print("mega_autopins: v1.28 ready")
