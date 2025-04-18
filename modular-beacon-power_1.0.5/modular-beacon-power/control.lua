---- control.lua

local DELIMITER = "__MBP"
local QUALITY_BONUS = 0.3
local POWER_MINIMUM = 0.2  -- beacons cannot be reduced below this amount of their original power consumption (vanilla uses 0.2 for other machines)
local apply_efficiency     -- whether effiency affects module effects applied to the beacon itself
local bonuses              -- positive, negative (booleans for startup settings)
local update_rate          -- how many ticks elapse between checking individual beacons
local active_mod           -- if disabled, beacons are not affected by their modules
local module_power_bonuses -- module prototype name -> power consumption bonus
local beacon_efficiencies  -- beacon prototype name -> beacon distribution efficiency
local all_beacons          -- beacon unit number -> entity reference, info
local beacon_queue         -- ordered list of beacon unit numbers
local iterator = 1         -- keeps track of current position within beacon_queue
local quality_multipliers  -- quality name -> quality multiplier

script.on_init(
  function()
    storage = { mpb = {}, beff = {}, beacons = {}, queue = {}, qm = {} }
    initialize()
    startup()
    check_all_beacons()
  end
)
script.on_load(
  function()
    startup()
  end
)
script.on_configuration_changed(
  function()
    initialize()
    startup()
    -- TODO: why is check_all_beacons() not needed here?
  end
)

--- Saves module/beacon prototype & entity data
function initialize()
  --local module_prototypes = game.get_filtered_item_prototypes({{filter = "type", type = "module"}})
  local module_prototypes = prototypes.get_item_filtered({{filter = "type", type = "module"}})
  for module_name, module in pairs(module_prototypes) do
    local power_bonus = 0
    if module.module_effects and module.module_effects.consumption then power_bonus = module.module_effects.consumption end
    storage.mpb[module_name] = power_bonus
  end
  --local beacon_prototypes = game.get_filtered_entity_prototypes({{filter = "type", type = "beacon"}})
  local beacon_prototypes = prototypes.get_entity_filtered({{filter = "type", type = "beacon"}})
  for beacon_name, beacon in pairs(beacon_prototypes) do
    storage.beff[beacon_name] = beacon.distribution_effectivity
  end
  local info = catalogue_all_beacons()
  storage.beacons = info[1]
  storage.queue = info[2]
  if not storage.qm then storage.qm = {} end -- for "migration" purposes
  for name, quality in pairs(prototypes.quality) do
      if name ~= "quality-unknown" then
        storage.qm[name] = 1 + QUALITY_BONUS*quality.level
      end
  end
end

--- Loads stored data and starts scripts
function startup()
  POWER_MINIMUM = tonumber(math.floor(math.ceil(settings.startup["mbp-power-minimum"].value*1000)/50)/10)/2 or 0.2 -- rounded to nearest 5%
  apply_efficiency = settings.startup["mbp-apply-efficiency"].value
  bonuses = { negative = settings.startup["mbp-negative-bonuses"].value, positive = settings.startup["mbp-positive-bonuses"].value }
  update_rate = settings.global["mbp-update-rate"].value
  active_mod = settings.global["mbp-active-mod"].value
  update_rate = settings.global["mbp-update-rate"].value
  active_mod = settings.global["mbp-active-mod"].value
  module_power_bonuses = storage.mpb
  beacon_efficiencies = storage.beff
  all_beacons = storage.beacons
  beacon_queue = storage.queue
  quality_multipliers = storage.qm
  script.on_event( defines.events.on_runtime_mod_setting_changed, function(event) on_settings_changed(event) end )
  script.on_event( defines.events.on_player_fast_transferred,     function(event) check_entity(event.entity) end )
  script.on_event( defines.events.on_entity_settings_pasted,      function(event) check_entity(event.destination) end )
  script.on_event( defines.events.on_selected_entity_changed,     function(event) check_entity(event.last_entity) end )
  script.on_event( defines.events.on_built_entity,                function(event) beacon_added(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.on_robot_built_entity,          function(event) beacon_added(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.script_raised_built,            function(event) beacon_added(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.on_space_platform_built_entity, function(event) beacon_added(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.script_raised_revive,           function(event) beacon_added(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.on_player_mined_entity,         function(event) beacon_removed(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.on_robot_mined_entity,          function(event) beacon_removed(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.on_entity_died,                 function(event) beacon_removed(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.script_raised_destroy,          function(event) beacon_removed(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.on_space_platform_mined_entity, function(event) beacon_removed(event.entity) end, {{filter = "type", type = "beacon"}} )
  script.on_event( defines.events.on_gui_opened,                  function(event) beacon_gui(event.entity, true) end )
  script.on_event( defines.events.on_gui_closed,                  function(event) beacon_gui(event.entity, false) end )
  if active_mod then register_periodic_updates(update_rate) end
end

--- Handles changes made to runtime settings
function on_settings_changed(event)
  if event.setting == "mbp-update-rate" then
    local previous_update_rate = update_rate
    update_rate = settings.global["mbp-update-rate"].value
    if previous_update_rate ~= update_rate then
      unregister_periodic_updates(previous_update_rate)
      register_periodic_updates(update_rate)
    end
  end
  if event.setting == "mbp-active-mod" then
    local previous_setting = active_mod
    active_mod = settings.global["mbp-active-mod"].value
    if previous_setting ~= active_mod then
      unregister_periodic_updates(nil)
      check_all_beacons()
      if active_mod then register_periodic_updates(update_rate) end
    end
  end
end

function register_periodic_updates(tick_rate)
  script.on_nth_tick(tick_rate, function(event) iterate() end)
end

function unregister_periodic_updates(tick_rate)
  if tick_rate == nil then
    script.on_nth_tick(nil)
  else
    script.on_nth_tick(tick_rate, nil)
  end
end

--- Finds all beacons and updates internal list
function catalogue_all_beacons()
  local beacon_catalogue = {}
  local unit_numbers = {}
  for _, surface in pairs(game.surfaces) do
    if surface == nil then break end
    local beacons = surface.find_entities_filtered({type = "beacon"})
    for _, beacon in pairs(beacons) do
      beacon_catalogue[beacon.unit_number] = {entity=beacon}
      table.insert(unit_numbers, beacon.unit_number)
    end
  end
  return {beacon_catalogue, unit_numbers}
end

function beacon_added(beacon)
  all_beacons[beacon.unit_number] = {entity=beacon}
  table.insert(beacon_queue, beacon.unit_number)
  if not active_mod then check_beacon(beacon) end
end

function beacon_removed(beacon)
  all_beacons[beacon.unit_number] = nil
  for i=1,#beacon_queue do
    if beacon_queue[i] == beacon.unit_number then table.remove(beacon_queue, i) end
  end
end

--- Marks "open" beacons to prevent them from being updated & closed when being viewed
function beacon_gui(entity, open)
  if active_mod and entity and entity.type == 'beacon' and all_beacons[entity.unit_number] then
    all_beacons[entity.unit_number].open = open
  end
end

function check_entity(entity)
  if active_mod and entity and entity.type == 'beacon' then
    check_beacon(entity)
  end
end

--- Iterates through the list of beacons and checks each, one after another
function iterate()
  if #beacon_queue == 0 or not active_mod then return end
    local changed = false
    if beacon_queue[iterator] and all_beacons[ beacon_queue[iterator] ] then
      changed = check_beacon(all_beacons[ beacon_queue[iterator] ].entity)
    else
      local skip_ahead = iterator + 10
      for i=iterator,skip_ahead do
        iterator = iterator + 1
        if beacon_queue[iterator] and all_beacons[ beacon_queue[iterator] ] then return end
      end
    end
    if not changed then iterator = iterator + 1 end
    if iterator > #beacon_queue then iterator = 1 end
end

--- Checks all beacons immediately
function check_all_beacons()
  for _, surface in pairs(game.surfaces) do
    if surface == nil then break end
    local beacons = surface.find_entities_filtered({type = "beacon"})
    for _, beacon in pairs(beacons) do
      check_beacon(beacon)
    end
  end
end

--- Checks and updates a beacon entity's power consumption according to its modules
--- @param beacon LuaEntity
function check_beacon(beacon)
  local changed = false
  if not beacon.valid then return changed end
  local modules = beacon.get_module_inventory().get_contents()
  local value = 0
  for _, module_info in pairs(modules) do
    local module_bonus = module_power_bonuses[module_info.name] or 0
    if ((bonuses.positive or module_bonus < 0) and (bonuses.negative or module_bonus > 0)) then
      quality_mult = 1
      if (module_bonus < 0 and bonuses.negative) then
        quality_mult = quality_multipliers[module_info.quality]
        if not quality_mult then return changed end
      end
      value = value + module_bonus * quality_mult * module_info.count
    end
  end
  if apply_efficiency then value = value * beacon_efficiencies[beacon.name] end
  local base_name = base_name(beacon.name, DELIMITER)
  local new_name = base_name..DELIMITER..normalize(value)
  if value == 0 or active_mod == false then new_name = base_name end
  if new_name == beacon.name then return changed end
  if beacon_efficiencies[new_name] == nil then return changed end
  if all_beacons[beacon.unit_number] and all_beacons[beacon.unit_number].open then return changed end
	local new_beacon = beacon.surface.create_entity({
		name = new_name,
    quality = beacon.quality,
		position = beacon.position,
		force = beacon.force_index,
		create_build_effect_smoke = false,
    raise_built = true
	})
  if new_beacon and beacon.valid then
    copy_modules(beacon, new_beacon)
    if beacon.is_registered_for_deconstruction(beacon.force_index) or beacon.to_be_deconstructed() then new_beacon.order_deconstruction(new_beacon.force_index) end
    beacon.destroy({raise_destroy = true})
    changed = true
  end
  return changed
end

--- Copies modules and module requests from one beacon to another
--- @param source LuaEntity
--- @param target LuaEntity
function copy_modules(source, target)
	local beacon_modules = source.get_inventory(defines.inventory.beacon_modules) or {}
  local new_beacon_modules = target.get_inventory(defines.inventory.beacon_modules) or {}
  for i=1,#beacon_modules do
    new_beacon_modules.insert(beacon_modules[i])
  end
  local request_proxies = source.surface.find_entities_filtered({
    area = {
      { source.position.x - 0.01, source.position.y - 0.01 },
      { source.position.x + 0.01, source.position.y + 0.01 }
    },
    name = "item-request-proxy",
    force = source.force
  })
  for _, proxy in pairs(request_proxies) do
    if proxy.proxy_target == source then
      target.surface.create_entity({
        name = "item-request-proxy",
        position = target.position,
        force = target.force,
        target = target,
        modules = proxy.insert_plan
      })
    end
  end
  -- TODO: Check empty module slots and rearrange requests as needed to preserve unfulfilled requests - modules get inserted by bots into the first open slot, not necessarily whichever slot originally requested them
end

--- Returns the "ID" for a beacon name corresponding to the given power consumption value
--- @param value double
--- @return string
function normalize(value)
  if value < POWER_MINIMUM-1 then value = POWER_MINIMUM-1 end
  return tostring(math.floor(math.ceil(value*1000)/10)) -- decimal value is rounded to the nearest 1%
end

--- Returns the "base" part of a beacon name to the left of the separator
--- @param name string
--- @param separator string
--- @return string
function base_name(name, separator)
  local t = {}
  for s in string.gmatch(name, "([^"..separator.."]+)") do
    table.insert(t,s)
  end
  return t[1]
end
