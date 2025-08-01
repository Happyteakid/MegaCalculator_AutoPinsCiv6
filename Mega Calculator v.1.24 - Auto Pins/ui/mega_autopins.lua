-- mega_autopins.lua v1.24 (full)
print("mega_autopins: v1.24 loading")
local LOG_PREFIX = "mega_autopins: "
local function dbg(msg) print(LOG_PREFIX .. tostring(msg)) end

local ACTION_ID = Input.GetActionId("Mega_ToggleAutoPins")
local isOn = false
local localPlayer = -1
local PIN_PREFIX = "[MEGA]"

-- Config
local MIN_CITY_DISTANCE = 4            -- must be >= this many tiles away from any city center
local NEXTCITY_MIN_PERCENT = 80        -- show proposals >= 80% of best
local NEXTCITY_MAX_PER_PLAYER = 6      -- cap proposals
local MAX_SETTLER_DISTANCE = 10        -- maximum straight-line distance from nearest owned city

local ICONS = {
  CITY    = "ICON_DISTRICT_CITY_CENTER",
  CAMPUS  = "ICON_DISTRICT_CAMPUS",
  THEATER = "ICON_MAP_PIN_DISTRICT_THEATER", -- fallback set below
  HUB     = "ICON_DISTRICT_COMMERCIAL_HUB",
  HARBOR  = "ICON_DISTRICT_HARBOR",
  IZ      = "ICON_DISTRICT_INDUSTRIAL_ZONE",
  EC      = "ICON_DISTRICT_ENTERTAINMENT_COMPLEX",
  AQ      = "ICON_DISTRICT_AQUEDUCT",
}

-- detect civ for special heuristics (e.g., Inca Terrace Farms)
local function isPlayerInca(pid)
  local pc = PlayerConfigurations[pid]
  if not pc then return false end
  local civ = pc:GetCivilizationTypeName() or ""
  return civ == "CIVILIZATION_INCA"
end
local isInca = false

local function isPlayerCiv(pid, civType)
  local pc = PlayerConfigurations[pid]
  if not pc then return false end
  return (pc:GetCivilizationTypeName() or "") == civType
end

local isBrazil = false
local isJapan  = false
local isGermany= false
local isGaul   = false
local isKorea  = false


local function toast(tag)
  local txt = Locale and Locale.Lookup and Locale.Lookup(tag) or tostring(tag)
  if UI and UI.AddWorldViewText then UI.AddWorldViewText(0, txt, -1, -1, 0) end
end

local function visible(p)
  if not p or localPlayer==-1 then return false end
  local pv = PlayersVisibility and PlayersVisibility[localPlayer]
  if not pv then return true end
  return pv:IsRevealed(p:GetIndex())
end

local function AdjacentPlots(x,y) return Map.GetAdjacentPlots(x,y) or {} end

local function canHostDistrictBasic(p)
  if not p then return false end
  if p:IsWater() or p:IsMountain() or p:IsImpassable() then return false end
  if p:GetDistrictType() ~= -1 or p:GetWonderType() ~= -1 then return false end
  local r = p:GetResourceType()
  if r and r ~= -1 then
    local rclass = GameInfo.Resources[r].ResourceClassType
    -- Don't allow districts on bonus or luxury resources
    if rclass == "RESOURCECLASS_BONUS" or rclass == "RESOURCECLASS_LUXURY" then
      return false
    end
  end
  return true
end


local function within3OfCity(city, p)
  return Map.GetPlotDistance(city:GetX(), city:GetY(), p:GetX(), p:GetY()) <= 3
end

local function countAdj(x,y, fn)
  local c=0; for _,q in ipairs(AdjacentPlots(x,y)) do if q and fn(q) then c=c+1 end end; return c
end

-- === Scores (fast, expansion-friendly) ===
local function scoreCampus(p)
  local x, y = p:GetX(), p:GetY()
  local s = 0
  dbg("== Scoring Campus at ("..x..","..y..") ==")

  local mountainCount = countAdj(x, y, function(q) return q:IsMountain() end)
  local reefCount = countAdj(x, y, function(q)
    local f=q:GetFeatureType()
    if f==-1 then return false end
    local key = GameInfo.Features[f].FeatureType
    return key == "FEATURE_REEF"
  end)

  if isBrazil then
    local jungle = countAdj(x, y, function(q)
      local f = q:GetFeatureType()
      return f~=-1 and GameInfo.Features[f].FeatureType == "FEATURE_JUNGLE"
    end)
    dbg("  Brazil Jungle bonus: +"..jungle)
    s = s + jungle
  end

  if isKorea then
    local districtPenalty = countAdj(x, y, function(q)
      return q:GetDistrictType()~=-1
    end)
    dbg("  Korea district penalty: -" .. districtPenalty)
    s = s - districtPenalty
  end

  if isJapan then
    local districtAdj = countAdj(x, y, function(q) return q:GetDistrictType()~=-1 end)
    dbg("  Japan district bonus: +"..districtAdj)
    s = s + districtAdj
  end

  if isInca and p:IsHills() then
    local adjM = countAdj(x, y, function(q) return q:IsMountain() end)
    if adjM >= 2 then
      dbg("  Inca penalty for good Terrace Farm hill: -4")
      s = s - 4
    end
  end

  s = s + mountainCount
  dbg("  Mountain bonus: +"..mountainCount)

  s = s + reefCount
  dbg("  Reef bonus: +"..reefCount)

  local jungleAdj = countAdj(x, y, function(q)
    local f = q:GetFeatureType()
    if f==-1 then return false end
    local key = GameInfo.Features[f].FeatureType
    return key=="FEATURE_JUNGLE" or key=="FEATURE_RAINFOREST"
  end)
  dbg("  Jungle/Rainforest adjacency: +"..jungleAdj)
  s = s + jungleAdj

  local districtAdj = math.floor(countAdj(x, y, function(q) return q:GetDistrictType()~=-1 end) / 2)
  dbg("  Adjacent districts (halved): +"..districtAdj)
  s = s + districtAdj

  if isGaul then
    local adjCity = countAdj(x, y, function(q)
      local d=q:GetDistrictType()
      return d~=-1 and GameInfo.Districts[d].CityCenter
    end)
    if adjCity > 0 then
      dbg("  Gaul penalty (near city center): -3")
      s = s - 3
    end
  end

  dbg("=> Final Campus Score: "..s)
  return s
end


local function scoreTheater(p)
  local x,y=p:GetX(),p:GetY()
  local s=0
  s = s + 2*countAdj(x,y, function(q) return q:GetWonderType()~=-1 end)
  s = s + countAdj(x,y, function(q) return q:GetDistrictType()~=-1 end)
    -- Japan: likes adjacent districts (+1 per)
  if isJapan then s = s + countAdj(x,y, function(q) local d=q:GetDistrictType(); return d~=-1 end) end
  return s
end

local function hasRiver(p) return p and p:IsRiver() end

local function scoreHub(p)
  local x,y=p:GetX(),p:GetY()
  local s=0
  if hasRiver(p) then s=s+2 end
  s = s + countAdj(x,y, function(q) return q:GetDistrictType()~=-1 end)
  s = s + countAdj(x,y, function(q)
    local d=q:GetDistrictType(); return (d~=-1) and GameInfo.Districts[d].DistrictType=="DISTRICT_HARBOR"
  end)
  -- Germany: value Hub tiles that can neighbor an IZ (+1 per adjacent clear land)
  if isGermany then s = s + countAdj(x,y, function(q)
    return (not q:IsWater()) and (not q:IsMountain()) and (q:GetDistrictType()==-1)
  end) end
  -- Japan: likes adjacent districts (+1 per)
  if isJapan then s = s + countAdj(x,y, function(q) local d=q:GetDistrictType(); return d~=-1 end) end
  return s
end

-- Harbor must be water and adjacent to THIS city's City Center
local function harborIsLegalForCityTile(harborPlot, city)
  if not harborPlot or not harborPlot:IsWater() then return false end
  local cx,cy = city:GetX(), city:GetY()
  local okAdj = false
  for _,q in ipairs(AdjacentPlots(harborPlot:GetX(), harborPlot:GetY())) do
    if q then
      local d=q:GetDistrictType()
      if d~=-1 and GameInfo.Districts[d].DistrictType=="DISTRICT_CITY_CENTER" and q:GetX()==cx and q:GetY()==cy then
        okAdj = true; break
      end
    end
  end
  return okAdj
end

local function scoreHarbor(p, city)
  if not harborIsLegalForCityTile(p, city) then return -999 end
  local s=0
  s = s + countAdj(p:GetX(), p:GetY(), function(q) return q:GetResourceType()~=-1 end)
  s = s + countAdj(p:GetX(), p:GetY(), function(q)
    local f=q:GetFeatureType(); return f~=-1 and GameInfo.Features[f].FeatureType=="FEATURE_REEF"
  end)
  return s
end

local function countImprovements(x,y, list)
  return countAdj(x,y, function(q)
    local imp=q:GetImprovementType(); if imp==-1 then return false end
    local t=GameInfo.Improvements[imp].ImprovementType
    return list[t] == true
  end)
end

local function scoreIZ(p)
  local x,y=p:GetX(),p:GetY()
  local s=0
  s = s + countImprovements(x,y, {["IMPROVEMENT_MINE"]=true, ["IMPROVEMENT_QUARRY"]=true})
  s = s + 2*countAdj(x,y, function(q)
    local d=q:GetDistrictType(); if d==-1 then return false end
    local dt=GameInfo.Districts[d].DistrictType
    return dt=="DISTRICT_AQUEDUCT" or dt=="DISTRICT_DAM"
  end)
    -- Germany: Hansa loves adjacency to CH and resources
  if isGermany then
    s = s + 2*countAdj(x,y, function(q)
      local d=q:GetDistrictType(); return (d~=-1) and GameInfo.Districts[d].DistrictType=="DISTRICT_COMMERCIAL_HUB" end)
    s = s + countAdj(x,y, function(q)
      local r=q:GetResourceType(); if r and r~=-1 then
        local cls = GameInfo.Resources[r].ResourceClassType; return cls=="RESOURCECLASS_BONUS" or cls=="RESOURCECLASS_STRATEGIC" end
      return false
    end)
  end
  return s
end

local function scoreEC(p)
  local seen = {}
  for _, city in Players[localPlayer]:GetCities():Members() do
    local dist = Map.GetPlotDistance(p:GetX(), p:GetY(), city:GetX(), city:GetY())
    if dist <= 6 then seen[city:GetID()] = true end
  end
  local c=0; for _ in pairs(seen) do c=c+1 end
  return c
end

local function isAqueductLegal(p)
  local x,y=p:GetX(),p:GetY()
  local adjCity, hasSource = false,false
  for _,q in ipairs(AdjacentPlots(x,y)) do
    if q then
      local d=q:GetDistrictType()
      if d~=-1 and GameInfo.Districts[d].DistrictType=="DISTRICT_CITY_CENTER" then adjCity=true end
      if q:IsRiver() or q:IsLake() or q:IsMountain() then hasSource=true end
      local f=q:GetFeatureType()
      if f~=-1 and GameInfo.Features[f].FeatureType=="FEATURE_OASIS" then hasSource=true end
    end
  end
  return adjCity and hasSource
end

-- === City site scoring & proposals ===
local function nearestOwnedCityDistance(p)
  local best=999
  for _, city in Players[localPlayer]:GetCities():Members() do
    local d = Map.GetPlotDistance(p:GetX(), p:GetY(), city:GetX(), city:GetY())
    if d<best then best=d end
  end
  return best
end

local function minCityDistanceOK(plot)
  for _, player in pairs(Players) do
    if player and player:GetCities() then
      for _, city in player:GetCities():Members() do
        local dist = Map.GetPlotDistance(plot:GetX(), plot:GetY(), city:GetX(), city:GetY())
        if dist < MIN_CITY_DISTANCE then
          if Players[city:GetOwner()]:IsMinor() then
            dbg("Rejected city site - too close to city-state ("..dist.." tiles) at "..city:GetX()..","..city:GetY())
          else
            dbg("Rejected city site - too close to player city ("..dist.." tiles) at "..city:GetX()..","..city:GetY())
          end
          return false
        end
      end
    end
  end
  return true
end



local function scoreCitySite(plot)
  if not plot or not visible(plot) then return -999 end
  if plot:IsWater() or plot:IsMountain() or plot:IsImpassable() then return -999 end
  if plot:GetDistrictType()~=-1 or plot:GetWonderType()~=-1 then return -999 end
  if not minCityDistanceOK(plot) then return -999 end
  if nearestOwnedCityDistance(plot) > MAX_SETTLER_DISTANCE then return -999 end

  local s=0
  -- Fresh water
  local fresh = plot:IsRiver() or plot:IsLake()
  if not fresh then
    for _,q in ipairs(AdjacentPlots(plot:GetX(), plot:GetY())) do
      local f=q and q:GetFeatureType()
      if f and f~=-1 and GameInfo.Features[f].FeatureType=="FEATURE_OASIS" then fresh=true break end
    end
  end
  if fresh then s=s+20 end

  -- First ring resources / second ring resources
  s = s + 6 * countAdj(plot:GetX(), plot:GetY(), function(q) return q:GetResourceType()~=-1 end)
  for dx=-2,2 do for dy=-2,2 do
    local q=Map.GetPlotXYWithRangeCheck(plot:GetX(), plot:GetY(), dx, dy, 2)
    if q and visible(q) and Map.GetPlotDistance(plot:GetX(), plot:GetY(), q:GetX(), q:GetY())==2 and q:GetResourceType()~=-1 then s=s+3 end
  end end

  -- Hills (early prod), reef nearby (science), woods/jungle (chops and adj)
  s = s + 2 * countAdj(plot:GetX(), plot:GetY(), function(q) return q:IsHills() end)
  s = s + 2 * countAdj(plot:GetX(), plot:GetY(), function(q)
    local f=q:GetFeatureType(); if f==-1 then return false end
    local key=GameInfo.Features[f].FeatureType
    return key=="FEATURE_REEF" or key=="FEATURE_JUNGLE" or key=="FEATURE_RAINFOREST"
  end)

  -- Coast adjacency: modest boost if coastal, higher if has 2+ sea resources adjacent
  if plot:IsCoastalLand() then
    s = s + 4
    s = s + countAdj(plot:GetX(), plot:GetY(), function(q) return q:IsWater() and q:GetResourceType()~=-1 end)
  end

  return s
end

local function collectCandidateSites()
  local candidates = {}
  local best = -999
  local seen = {}
  for _, city in Players[localPlayer]:GetCities():Members() do
    local cx,cy = city:GetX(), city:GetY()
    for dx=-12,12 do
      for dy=-12,12 do
        local p=Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 12)
        if p and visible(p) then
          local idx = p:GetIndex()
          if not seen[idx] then -- avoid duplicates from overlapping radii
            seen[idx]=true
            local sc=scoreCitySite(p)
            if sc>-999 then
              candidates[#candidates+1] = {plot=p, score=sc}
              if sc>best then best=sc end
            end
          end
        end
      end
    end
  end
  return candidates, best
end

-- === Pin API ===
local function cfg() return PlayerConfigurations[localPlayer] end

local function setIconSafe(pin, icon)
  if not pin or not pin.SetIconName then return end
  if icon=="ICON_MAP_PIN_DISTRICT_THEATER" or icon=="ICON_DISTRICT_THEATER_SQUARE" or icon=="ICON_DISTRICT_THEATER" then
    pin:SetIconName("ICON_MAP_PIN_DISTRICT_THEATER")
  else
    pin:SetIconName(icon)
  end
end

function ensurePinAt(x, y, icon, name)
  local c = cfg(); if not c then return false end
  local ex = c.GetMapPin and c:GetMapPin(x, y)
  if ex and ex.SetIconName then
    setIconSafe(ex, icon)
    if ex.SetName then
      ex:SetName(name or PIN_PREFIX)
      dbg("UpdatePin label set to: "..(name or PIN_PREFIX))
    else
      dbg("UpdatePin: Failed to set pin name")
    end
    if c.UpdateMapPin then c:UpdateMapPin(ex) end
    if LuaEvents and LuaEvents.DMT_MapPinAdded then LuaEvents.DMT_MapPinAdded(ex) end
    dbg("UpdatePin: "..(name or PIN_PREFIX).." @("..x..","..y..")")
    return true
  end

  -- Create new pin
  local pin = nil
  if c.AddMapPinAt then pin = c:AddMapPinAt(x, y) end
  if type(pin) == "number" and c.GetMapPinByID then pin = c:GetMapPinByID(pin) end
  if not pin and c.AddMapPin then pin = c:AddMapPin(x, y) end
  if type(pin) == "number" and c.GetMapPinByID then pin = c:GetMapPinByID(pin) end
  if not pin then dbg("Failed to create pin at ("..x..","..y..")"); return false end

  setIconSafe(pin, icon)
  if pin.SetName then
    pin:SetName(name or PIN_PREFIX)
    dbg("CreatePin label set to: "..(name or PIN_PREFIX))
  else
    dbg("CreatePin: Failed to set pin name")
  end

  if c.UpdateMapPin then c:UpdateMapPin(pin) end
  if Network and Network.BroadcastPlayerInfo then Network.BroadcastPlayerInfo() end

  if LuaEvents and LuaEvents.DMT_MapPinAdded then
    local cfg = cfg()
    local mp = cfg and cfg.GetMapPin and cfg:GetMapPin(x, y)
    if mp then LuaEvents.DMT_MapPinAdded(mp) end
  end

  dbg("CreatePin: "..(name or PIN_PREFIX).." @("..x..","..y..")")
  return true
end


local function clearOurPins()
  local c=cfg(); if not c or not c.GetMapPins then return end
  local del={}
  local ICONSET={}
  for k,v in pairs(ICONS) do ICONSET[v]=true end
  for _, pin in pairs(c:GetMapPins()) do
    local nm=(pin.GetName and pin:GetName()) or ""
    local ic=(pin.GetIconName and pin:GetIconName()) or ""
    if string.sub(nm,1,#PIN_PREFIX)==PIN_PREFIX or string.sub(nm,1,10)=="NEXT CITY " or ICONSET[ic] then
      table.insert(del, pin:GetID())
    end
  end
  for _, id in ipairs(del) do
    local mp = c.GetMapPinByID and c:GetMapPinByID(id)
    if LuaEvents and LuaEvents.DMT_MapPinRemoved and mp then LuaEvents.DMT_MapPinRemoved(mp) end
    c:DeleteMapPin(id)
  end
  if Network and Network.BroadcastPlayerInfo then Network.BroadcastPlayerInfo() end
  dbg("Cleared "..tostring(#del).." pins")
end

-- === Placement helpers ===
local function bestPlotAround(city, radius, scoreFunc, minWanted, used)
  local cx,cy=city:GetX(),city:GetY()
  local bestP=nil; local best=-999
  for dx=-radius, radius do
    for dy=-radius, radius do
      local p=Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, radius)
      if p and visible(p) and (not used[p:GetIndex()]) and canHostDistrictBasic(p) and within3OfCity(city,p) then
        local sc=scoreFunc(p)
        if sc>=minWanted and sc>best then best=sc; bestP=p end
      end
    end
  end
  return bestP, best
end

-- Campus↔Hub synergy (each within 3 tiles)
local function placeCampusHubSynergy(city, used)
  local cx,cy=city:GetX(),city:GetY()
  local campList={}
  for dx=-3,3 do for dy=-3,3 do
    local p=Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 3)
    if p and visible(p) and (not used[p:GetIndex()]) and canHostDistrictBasic(p) and within3OfCity(city,p) then
      local sc=scoreCampus(p)
      if sc>=2 then table.insert(campList,{plot=p,score=sc}) end
    end
  end end
  table.sort(campList, function(a,b) return a.score>b.score end)
  if #campList==0 then return end
  if #campList>6 then campList={campList[1],campList[2],campList[3],campList[4],campList[5],campList[6]} end
  local bestC,bestH,bestTotal=nil,nil,-999
  for _,c in ipairs(campList) do
    for dx=-3,3 do for dy=-3,3 do
      local h=Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 3)
      if h and h~=c.plot and visible(h) and (not used[h:GetIndex()]) and canHostDistrictBasic(h) and within3OfCity(city,h) then
        local hs=scoreHub(h)
        -- synergy bonus if adjacent
        local isAdj=false; for _,q in ipairs(AdjacentPlots(h:GetX(),h:GetY())) do if q==c.plot then isAdj=true break end end
        if isAdj then hs=hs+1 end
        local total=c.score+hs
        if total>bestTotal then bestTotal=total; bestC=c; bestH={plot=h,score=hs} end
      end
    end end
  end
  if bestC then
    local idx=bestC.plot:GetIndex(); used[idx]=true
    ensurePinAt(bestC.plot:GetX(), bestC.plot:GetY(), ICONS.CAMPUS, PIN_PREFIX.." Campus "..tostring(bestC.score))
    dbg("Placed Campus synergy @"..bestC.plot:GetX()..","..bestC.plot:GetY().." score="..bestC.score)
  end
  if bestH then
    local idx=bestH.plot:GetIndex(); used[idx]=true
    ensurePinAt(bestH.plot:GetX(), bestH.plot:GetY(), ICONS.HUB, PIN_PREFIX.." Hub "..tostring(bestH.score))
    dbg("Placed Hub synergy @"..bestH.plot:GetX()..","..bestH.plot:GetY().." score="..bestH.score)
  end
end

local function placeForCity(city, used)
  placeCampusHubSynergy(city, used)

  local tP,ts=bestPlotAround(city,3, scoreTheater, 0, used)
  if tP then used[tP:GetIndex()]=true; ensurePinAt(tP:GetX(),tP:GetY(), ICONS.THEATER, PIN_PREFIX.." Theater "..tostring(ts)); dbg("Placed Theater @"..tP:GetX()..","..tP:GetY().." score="..ts) end

  local izP,izs=bestPlotAround(city,3, scoreIZ, 0, used)
  if izP then used[izP:GetIndex()]=true; ensurePinAt(izP:GetX(),izP:GetY(), ICONS.IZ, PIN_PREFIX.." IZ "..tostring(izs)); dbg("Placed IZ @"..izP:GetX()..","..izP:GetY().." score="..izs) end

  local ecP,ecs=bestPlotAround(city,3, scoreEC, 1, used)
  if ecP then used[ecP:GetIndex()]=true; ensurePinAt(ecP:GetX(),ecP:GetY(), ICONS.EC, PIN_PREFIX.." EC "..tostring(ecs)); dbg("Placed EC @"..ecP:GetX()..","..ecP:GetY().." score="..ecs) end

  -- Aqueduct: pick any legal candidate in ring 1-3
  local aqBest = nil
  local cx, cy = city:GetX(), city:GetY()
  for dx = -3, 3 do
    for dy = -3, 3 do
      local p = Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 3)
      if p and visible(p) and (not used[p:GetIndex()]) and within3OfCity(city, p) then
        if not canHostDistrictBasic(p) then
          dbg("Rejected Aqueduct plot at ("..p:GetX()..","..p:GetY()..") - invalid district site (water, mountain, resource, etc.)")
        elseif not isAqueductLegal(p) then
          dbg("Rejected Aqueduct plot at ("..p:GetX()..","..p:GetY()..") - lacks required adjacents (city + water/mountain/oasis)")
        else
          dbg("Selected Aqueduct plot at ("..p:GetX()..","..p:GetY()..") - valid location")
          aqBest = p
          break
        end
      end
    end
  end

  if aqBest then used[aqBest:GetIndex()]=true; ensurePinAt(aqBest:GetX(),aqBest:GetY(), ICONS.AQ, PIN_PREFIX.." Aqueduct 1"); dbg("Placed Aqueduct @"..aqBest:GetX()..","..aqBest:GetY()) end

  -- Harbor: only legal tiles for this city
  for dx=-3,3 do for dy=-3,3 do
    local p=Map.GetPlotXYWithRangeCheck(cx, cy, dx, dy, 3)
    if p and visible(p) and (not used[p:GetIndex()]) and p:IsWater() and p:GetDistrictType()==-1 and harborIsLegalForCityTile(p, city) then
      local sc=scoreHarbor(p, city)
      if sc>=0 then used[p:GetIndex()]=true; ensurePinAt(p:GetX(),p:GetY(), ICONS.HARBOR, PIN_PREFIX.." Harbor "..tostring(sc)); dbg("Placed Harbor @"..p:GetX()..","..p:GetY().." score="..sc); break end
    end
  end end
end

local function placeNextCityPins()
  local cands, best = collectCandidateSites()
  if best < 0 or #cands == 0 then
    dbg("NextCity: no candidates found")
    return
  end

  dbg("NextCity: "..#cands.." candidate plots collected; best score = "..best)

  table.sort(cands, function(a, b) return a.score > b.score end)
  local placed = 0
  local chosen = {}

  local function farFromChosen(p)
    for _, ch in ipairs(chosen) do
      local dist = Map.GetPlotDistance(p:GetX(), p:GetY(), ch.plot:GetX(), ch.plot:GetY())
      if dist < MIN_CITY_DISTANCE then
        dbg("Rejected site at ("..p:GetX()..","..p:GetY()..") - too close to another planned city ("..ch.plot:GetX()..","..ch.plot:GetY()..")")
        return false
      end
    end
    return true
  end

  for _, item in ipairs(cands) do
    local pct = math.floor(100.0 * (item.score / best) + 0.5)

    if pct < NEXTCITY_MIN_PERCENT then
      dbg("Rejected site at ("..item.plot:GetX()..","..item.plot:GetY()..") - score too low: "..pct.."% < "..NEXTCITY_MIN_PERCENT.."% threshold")
    elseif not farFromChosen(item.plot) then
      dbg("Rejected site at ("..item.plot:GetX()..","..item.plot:GetY()..") - too close to another chosen site")
    else
      local name = "NEXT CITY ["..tostring(pct).."%".."]"
      ensurePinAt(item.plot:GetX(), item.plot:GetY(), ICONS.CITY, name)
      dbg("OK Placed NextCity pin at ("..item.plot:GetX()..","..item.plot:GetY()..") score="..item.score.." pct="..pct)
      table.insert(chosen, item)
      placed = placed + 1
      if placed >= NEXTCITY_MAX_PER_PLAYER then
        dbg("Reached city pin limit of "..NEXTCITY_MAX_PER_PLAYER)
        break
      end
    end
  end

  if placed == 0 and #cands > 0 then
    local top = cands[1]
    local pct = math.floor(100.0 * (top.score / best) + 0.5)
    ensurePinAt(top.plot:GetX(), top.plot:GetY(), ICONS.CITY, "NEXT CITY ["..tostring(pct).."%]")
    placed = 1
    dbg("Fallback: Placed top city site because none met threshold or distance requirements")
  end

  dbg("NextCity placement complete. Total placed: "..tostring(placed).." (best score: "..tostring(best)..")")
end


local function placeAllPins()
  local pl=Players[localPlayer]; if not pl then return end
  local used={}
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

local function OnInputActionTriggered(id)
  if id==ACTION_ID then dbg("InputActionTriggered"); Toggle() end
end

local function OnInputHandler(pInput)
  if pInput:GetMessageType()==KeyEvents.KeyUp and pInput:GetKey()==Keys.G and pInput:IsShiftDown() then dbg("Raw Shift+G captured"); Toggle(); return true end
  return false
end

local function Initialize()
  localPlayer = Game.GetLocalPlayer() or -1
  isInca = isPlayerInca(localPlayer)
  isBrazil = isPlayerCiv(localPlayer, "CIVILIZATION_BRAZIL")
  isJapan  = isPlayerCiv(localPlayer, "CIVILIZATION_JAPAN")
  isGermany= isPlayerCiv(localPlayer, "CIVILIZATION_GERMANY")
  isGaul   = isPlayerCiv(localPlayer, "CIVILIZATION_GAUL")
  isKorea  = isPlayerCiv(localPlayer, "CIVILIZATION_KOREA")
  if ContextPtr and ContextPtr.SetInputHandler then ContextPtr:SetInputHandler(OnInputHandler, true) end
  if Events and Events.InputActionTriggered then Events.InputActionTriggered.Add(OnInputActionTriggered) end
  if UI and UI.StatusMessage and Locale and Locale.Lookup then UI.StatusMessage(Locale.Lookup("LOC_MEGA_AUTOPINS_READY")) end
  dbg("Initialized; action="..tostring(ACTION_ID).." player="..tostring(localPlayer).." Inca="..tostring(isInca))
end

Events.LoadGameViewStateDone.Add(Initialize)
