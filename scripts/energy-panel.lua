-- "Energy" panel shown next to the electric network window (below it, as
-- that window is wide) and next to the accumulator window (on the right),
-- with stored energy in watt-hours:
--   This accumulator: 1.02 kWh / 1.39 kWh (73%)      (accumulator only)
--   Network: 416 kWh / 556 kWh (75%, 400 accumulators)
-- The game draws its own "X / Y MJ" text and mods cannot change it, so the
-- panel sits beside it. Refreshed every 30 ticks while open.
-- Per-player setting "power-overload-energy-panel" turns it off.

local FRAME_NAME = "po-energy-panel"
local REFRESH_INTERVAL = 30

local function percent(part, whole)
  if not whole or whole <= 0 then return "0" end
  return string.format("%d", math.floor(part / whole * 100 + 0.5))
end

-- Stored energy and capacity of every accumulator on the entity's network.
-- Only runs while a player has the panel open.
---@param entity LuaEntity
local function network_totals(entity)
  local network_id = entity.electric_network_id
  if not network_id then return nil end
  local stored, capacity, count = 0, 0, 0
  for _, accumulator in pairs(entity.surface.find_entities_filtered{type = "accumulator"}) do
    if accumulator.electric_network_id == network_id then
      stored = stored + accumulator.energy
      capacity = capacity + accumulator.electric_buffer_size
      count = count + 1
    end
  end
  return stored, capacity, count
end

---@param player LuaPlayer
local function destroy_panel(player)
  local frame = player.gui.relative[FRAME_NAME]
  if frame then frame.destroy() end
end

---@param player LuaPlayer
---@param entity LuaEntity
local function fill_panel(player, entity)
  local frame = player.gui.relative[FRAME_NAME]
  if not frame then return end
  frame.clear()
  local format = shared.format_watt_hours

  if entity.type == "accumulator" then
    frame.add{type = "label", caption = {"po-energy.this-accumulator",
      format(entity.energy), format(entity.electric_buffer_size),
      percent(entity.energy, entity.electric_buffer_size)}}
  end

  local stored, capacity, count = network_totals(entity)
  if stored and count > 0 then
    frame.add{type = "label", caption = {"po-energy.network",
      format(stored), format(capacity), percent(stored, capacity), count}}
  else
    frame.add{type = "label", caption = {"po-energy.no-accumulators"}}
  end
end

---@param player LuaPlayer
---@param entity LuaEntity
local function open_panel(player, entity)
  destroy_panel(player)
  local is_accumulator = entity.type == "accumulator"
  player.gui.relative.add{
    type = "frame",
    name = FRAME_NAME,
    direction = "vertical",
    caption = {"po-energy.panel-title"},
    anchor = {
      gui = is_accumulator and defines.relative_gui_type.accumulator_gui
        or defines.relative_gui_type.electric_network_gui,
      position = is_accumulator and defines.relative_gui_position.right
        or defines.relative_gui_position.bottom,
    },
  }
  fill_panel(player, entity)
end

---@param event EventData.on_gui_opened
function energy_panel_on_opened(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.type ~= "accumulator" and entity.type ~= "electric-pole" then return end
  local player = game.get_player(event.player_index)  ---@cast player -?
  if not settings.get_player_settings(player)["power-overload-energy-panel"].value then return end
  storage.energy_panel_open = storage.energy_panel_open or {}
  storage.energy_panel_open[event.player_index] = entity
  open_panel(player, entity)
end

---@param event EventData.on_gui_closed
function energy_panel_on_closed(event)
  local open = storage.energy_panel_open
  if not (open and open[event.player_index]) then return end
  open[event.player_index] = nil
  local player = game.get_player(event.player_index)
  if player then destroy_panel(player) end
end

---@param tick GameTick
function update_energy_panels(tick)
  if tick % REFRESH_INTERVAL ~= 0 then return end
  local open = storage.energy_panel_open
  if not open then return end
  for player_index, entity in pairs(open) do
    local player = game.get_player(player_index)
    if entity.valid and player and player.valid then
      fill_panel(player, entity)
    else
      open[player_index] = nil
      if player and player.valid then destroy_panel(player) end
    end
  end
end
