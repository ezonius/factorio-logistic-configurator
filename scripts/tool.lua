local table = require('__kry_stdlib__/stdlib/utils/table')
local Util = require('util')

function debug(msg)
--  game.print(msg)
end

function isRequester(entity)
  return entity.type == "logistic-container" and
    (entity.prototype.logistic_mode == "buffer" or entity.prototype.logistic_mode == "requester")
end

function isBuffer(entity)
  return entity.type == "logistic-container" and
    entity.prototype.logistic_mode == "buffer"
end

function isStorage(entity)
  return entity.type == "logistic-container" and
    entity.prototype.logistic_mode == "storage"
end

-- Adds ingredients from the encraftertity's current recipe.
function addIngredients(requests, crafter)
  if crafter.prototype.crafting_categories and crafter.get_recipe() then
    local recipe, quality = crafter.get_recipe()
    local stackSize = 10
    local products = recipe.products
    if #products > 0 and products[1].type == "item" then
      local product = prototypes.item[products[1].name]
      if product then stackSize = product.stack_size end
    end
    for _, v in pairs(recipe.ingredients) do
      if (v.type == "item") then
        requests[v.name] = (requests[v.name] or { rawAmount = 0, amountPerSec = 0, amountPerStack = 0 })
        requests[v.name].quality = quality
        requests[v.name].rawAmount = requests[v.name].rawAmount + v.amount
        requests[v.name].amountPerStack = requests[v.name].amountPerStack + stackSize * v.amount
        requests[v.name].amountPerSec = requests[v.name].amountPerSec + crafter.crafting_speed * v.amount /  recipe.energy
      end
    end
  end
end

-- Adds science packs for a lab.
function addLabCycle(requests, entity)
  if entity.prototype.lab_inputs then
    for _, v in pairs(entity.prototype.lab_inputs) do
      requests[v.name] = { quality = nil, rawAmount = 6, amountPerSec = 6, amountPerStack = 0 } -- six is good, how about six?
    end
  end
end

function setRequester(player, chest, requests)
  local lp = chest.get_requester_point()
  if not lp then return end
  if lp.sections_count > 0 and getRequestersSkipExisting(player) then return end

  while lp.sections_count > 0 do
    lp.remove_section(1)
--    lp.sections[si].filters = {}
  end
  local lsection = lp.add_section()

  local nextSlot = 1
  for itemName, amountConsumed in pairs(requests) do
    local amount = getRequesterAmount(player, itemName, amountConsumed)
    lsection.set_slot(nextSlot, { value = { type = "item", name = itemName, quality = amountConsumed.quality }, min = amount })
    debug("setting requester slot to " .. itemName .. " = " .. amount)
    nextSlot = nextSlot + 1
  end

  chest.request_from_buffers = getRequestersFromBuffers(player)
end

-- TODO: Rename. Changed to connect crafter-chest instead of inserter-chest.
function setInserter(player, inserter)
  local crafter = inserter.pickup_target
  if crafter.get_control_behavior() and getInsertersSkipExisting(player) then return end

  local recipe, quality = crafter.get_recipe()
  if crafter.prototype.crafting_categories and recipe and #recipe.products > 0 and recipe.products[1].type == "item" then
    local itemName = recipe.products[1].name
    local amount = getInserterAmount(player, itemName)
    local cb = crafter.get_or_create_control_behavior()
    local condition = {
      comparator = "<",
      first_signal = { type = "item", name = itemName, quality = quality.name },
      constant = amount,
    }

    if getInsertersConnectToChest(player) then
      crafter.get_wire_connector(defines.wire_connector_id.circuit_green, true)
        .connect_to(inserter.drop_target.get_wire_connector(defines.wire_connector_id.circuit_green, true))

      cb.connect_to_logistic_network = false
      cb.circuit_enable_disable = true
      cb.circuit_condition = condition
      cb.logistic_condition = nil
      debug("setting circuit condition to " .. itemName .. " < " .. amount)
    else
      local connector = crafter.get_wire_connector(defines.wire_connector_id.circuit_green, false)
      if connector then
        connector.disconnect_from(inserter.drop_target.get_wire_connector(defines.wire_connector_id.circuit_green, true))
      end

      cb.connect_to_logistic_network = true
      cb.circuit_enable_disable = false
      cb.circuit_condition = nil
      cb.logistic_condition = condition

      debug("setting logistic condition to " .. itemName .. " < " .. amount)
    end
  end
end

function setBuffer(player, inserter)
  local chest  = inserter.drop_target
  if not isBuffer(chest) then return end
  local lp = chest.get_requester_point()
  if not lp then return end
  if lp.sections_count > 0 and getBuffersSkipExisting(player) then return end

  local crafter = inserter.pickup_target
  local recipe, quality = crafter.get_recipe()
  if crafter.prototype.crafting_categories and recipe and #recipe.products > 0 and recipe.products[1].type == "item" then
    local itemName = recipe.products[1].name
    local amount = getBufferAmount(player, itemName)

    while lp.sections_count > 0 do
      lp.remove_section(1)
    end
    local lsection = lp.add_section()
    lsection.set_slot(1, { value = { type = "item", name = itemName, quality = quality }, min = amount })
    debug("setting buffer slot to " .. itemName .. " = " .. amount)
  end
end

-- TODO: Separate settings from Buffer.
function setStorageFilter(player, inserter)
  local chest  = inserter.drop_target
  if not isStorage(chest) then return end
  if chest.storage_filter ~= nil and getBuffersSkipExisting(player) then return end

  local crafter = inserter.pickup_target
  local recipe, quality = crafter.get_recipe()
  if crafter.prototype.crafting_categories and recipe and #recipe.products > 0 and recipe.products[1].type == "item" then
    local itemName = recipe.products[1].name
    chest.storage_filter = { name = itemName, quality = quality }
    debug("setting storage filter to " .. itemName)
  end
end

script.on_event(defines.events.on_player_selected_area, function(event)
  if event.item ~= Config.TOOL_NAME then return end
  local player = game.players[event.player_index]

  local requesters = {}
  local inserters = {}
  table.each(player.surface.find_entities_filtered{type = "inserter", area = event.area}, function(v)
    if v.drop_target and v.pickup_target then
      if isRequester(v.pickup_target) then
        local id = v.pickup_target.unit_number
        requesters[id] = requesters[id] or { chest = v.pickup_target, targets = {} }
        table.insert(requesters[id].targets, v.drop_target)
      elseif v.drop_target.get_inventory(defines.inventory.chest) then
        table.insert(inserters, v)
      end
    end
  end)

  if getRequestersEnabled(player) then
    for _, data in pairs(requesters) do
      local chest = data.chest
      local requests = {}
      for _,drop in pairs(data.targets) do
        addIngredients(requests, drop)
        addLabCycle(requests, drop)
      end
      setRequester(player, chest, requests)
    end
  end
  if getInsertersEnabled(player) then
    for _, inserter in pairs(inserters) do
      setInserter(player, inserter)
    end
  end
  if getBuffersEnabled(player) then
    for _, inserter in pairs(inserters) do
      setBuffer(player, inserter)
    end
  end
  for _, inserter in pairs(inserters) do
    setStorageFilter(player, inserter)
  end
end)

script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
  local player = game.players[event.player_index]
  local item = player.cursor_stack and player.cursor_stack.valid_for_read and player.cursor_stack.name
  if item == Config.TOOL_NAME then
    showGui(player)
  else
    hideGui(player)
  end
end)

script.on_event(defines.events.on_player_dropped_item, function(event)
  local player = game.players[event.player_index]
  if event.entity and event.entity.stack and event.entity.stack.name == Config.TOOL_NAME then
    event.entity.stack.clear()
    hideGui(player)
  end
end)