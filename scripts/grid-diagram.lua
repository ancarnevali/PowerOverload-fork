-- Grid diagram: a one-line schematic of the transformer grid on the map.
--
-- One straight line per route, from each transformer to each downstream
-- transformer it feeds (the routes found by line-losses.lua):
--   width  = power on the route (the source's output split among the
--            transformers it feeds in proportion to their draw)
--   colour = line loss on the route: green < 10%, yellow < 50%, red above;
--            grey when no power flows
--   label  = "power · loss" at the midpoint, dot at the downstream end
-- A panel (top left) shows the grid's energy balance, averaged over the last 5 s:
-- generated power, power reaching machines, and power lost, split into
-- transformer efficiency and line losses, each also as % of generation.
--
-- Map view only, and only for players who switched it on with the
-- "Toggle grid diagram" shortcut (off by default, per player).
--
-- Self-contained so it is easy to disable or remove:
--   * disable: leave the shortcut off. When no connected player has it on,
--     nothing is computed and every drawing is removed.
--   * remove:  switch it off for everyone (clears the drawings), then delete
--     this file and every block marked "grid-diagram" (control.lua,
--     prototypes/shortcuts.lua, locale), plus the two grid-diagram icons in
--     graphics/shortcuts.

local UPDATE_INTERVAL = 60
-- Energy-balance window. Transformer energy is summed tick by tick over
-- exactly this many ticks; network consumption is Power Overload's 5-second
-- average, so both cover the same span of time.
local STATS_WINDOW = 300
local PANEL_NAME = "po-grid-panel"
local SHORTCUT = "po-toggle-grid-diagram"

local COLOURS = {
  ok = {r = 0.2, g = 0.9, b = 0.2},
  near = {r = 1, g = 0.85, b = 0.1},
  over = {r = 1, g = 0.2, b = 0.2},
  idle = {r = 0.5, g = 0.5, b = 0.5},
}

local function destroy(id)
  if not id then return end
  local object = rendering.get_object_by_id(id)
  if object and object.valid then object.destroy() end
end

local function destroy_route(route)
  destroy(route.line)
  destroy(route.label)
  destroy(route.dot)
end

-- Removes every drawing this module made.
function grid_diagram_clear()
  storage.grid_stats = nil
  for _, player in pairs(game.players) do
    local panel = player.gui.left[PANEL_NAME]
    if panel then panel.destroy() end
  end
  local state = storage.grid_diagram
  if not state then return end
  for _, route in pairs(state.routes) do
    destroy_route(route)
  end
  storage.grid_diagram = nil
end

-- Energy balance -------------------------------------------------------------
-- Every joule generated on the transformer grid either reaches a consumer or
-- is lost in a transformer (accumulators charging count as consumers). So
--   generated = Σ consumption of every network a transformer touches
--               − what transformers deliver into those networks
-- and losses come from the totals summed in update_transformers.

---@param tick GameTick
---@return table? balance  nil until the first full window has been measured
local function measure_balance(tick)
  local stats = storage.grid_stats
  if not stats then return nil end
  local window_ticks = tick - stats.start_tick
  if window_ticks < STATS_WINDOW then return stats.last end

  local seconds = window_ticks / 60
  local p_in = stats.e_in / seconds
  local p_out = stats.e_out / seconds
  local p_line = stats.e_line / seconds
  local p_lost = p_in - p_out

  -- Consumption of every network a transformer touches, each counted once
  local consumption, seen = 0, {}
  for _, transformer_parts in pairs(storage.transformers) do
    for _, pole in pairs({transformer_parts.pole_in, transformer_parts.pole_out}) do
      if pole and pole.valid then
        local network_id = pole.electric_network_id
        if network_id and not seen[network_id] then
          seen[network_id] = true
          consumption = consumption + get_network_consumption(pole, tick)
        end
      end
    end
  end

  local generated = consumption - p_out
  if generated < p_lost then generated = p_lost end  -- guard against sampling skew
  stats.last = {
    generated = generated,
    lost = p_lost,
    line = p_line,
    transformer = p_lost - p_line,
    delivered = generated - p_lost,
  }
  stats.e_in, stats.e_out, stats.e_line = 0, 0, 0
  stats.start_tick = tick
  return stats.last
end

local function percent_of(part, whole)
  if whole <= 0 then return "0.0" end
  return string.format("%.1f", part / whole * 100)
end

---@param player LuaPlayer
---@param balance table?
local function update_panel(player, balance)
  local panel = player.gui.left[PANEL_NAME]
  if not panel then
    panel = player.gui.left.add{type = "frame", name = PANEL_NAME, direction = "vertical", caption = {"po-grid.panel-title"}}
  end
  panel.clear()
  if not balance then
    panel.add{type = "label", caption = {"po-grid.measuring"}}
    return
  end
  local format = shared.format_energy_number
  local g = balance.generated
  panel.add{type = "label", caption = {"po-grid.generated", format(g)}}
  panel.add{type = "label", caption = {"po-grid.delivered", format(balance.delivered), percent_of(balance.delivered, g)}}
  panel.add{type = "label", caption = {"po-grid.lost", format(balance.lost), percent_of(balance.lost, g)}}
  panel.add{type = "label", caption = {"po-grid.lost-transformers", format(balance.transformer), percent_of(balance.transformer, g)}}
  panel.add{type = "label", caption = {"po-grid.lost-lines", format(balance.line), percent_of(balance.line, g)}}
end

---@return uint[] players, string key  players with the diagram on, and a key to detect changes
local function viewers()
  local list, parts = {}, {}
  for _, player in pairs(game.connected_players) do
    if player.is_shortcut_toggled(SHORTCUT) then
      list[#list + 1] = player.index
      parts[#parts + 1] = player.index
    end
  end
  return list, table.concat(parts, ",")
end

local function band_for(power, loss)
  if power <= 0 then return "idle" end
  if loss >= 0.5 then return "over" end
  if loss >= 0.1 then return "near" end
  return "ok"
end

-- 10 kW -> 1 ... 1 GW -> 8, logarithmic so small and huge flows both read
local function width_for(power)
  if power <= 10000 then return 1 end
  local w = 1 + 1.5 * math.log(power / 10000, 10)
  if w > 8 then w = 8 end
  return math.floor(w * 2 + 0.5) / 2  -- half steps, so tiny changes do not redraw
end

local function midpoint(a, b)
  return {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2}
end

-- Flips the shortcut for a player and redraws straight away rather than
-- waiting for the next 60-tick update.
---@param player LuaPlayer
---@param tick GameTick
function toggle_grid_diagram(player, tick)
  player.set_shortcut_toggled(SHORTCUT, not player.is_shortcut_toggled(SHORTCUT))
  update_grid_diagram(tick, true)
end

---@param tick GameTick
---@param force boolean?  update now regardless of the interval
function update_grid_diagram(tick, force)
  if not force and tick % UPDATE_INTERVAL ~= 0 then return end
  local players, players_key = viewers()
  if #players == 0 or not storage.global_settings["power-overload-line-losses"] then
    grid_diagram_clear()
    return
  end

  local state = storage.grid_diagram
  if not state then
    state = {routes = {}, players_key = players_key}
    storage.grid_diagram = state
  end

  -- Energy balance panel
  if not storage.grid_stats then
    storage.grid_stats = {e_in = 0, e_out = 0, e_line = 0, start_tick = tick}
  end
  local balance = measure_balance(tick)
  local viewing = {}
  for _, index in pairs(players) do viewing[index] = true end
  for _, player in pairs(game.connected_players) do
    if viewing[player.index] then
      update_panel(player, balance)
    else
      local panel = player.gui.left[PANEL_NAME]
      if panel then panel.destroy() end
    end
  end
  local players_changed = state.players_key ~= players_key
  state.players_key = players_key

  local transformers = storage.transformers
  local seen = {}

  for source_unit, source in pairs(transformers) do
    local source_entity = source.transformer
    local load_total = source.line_load_total or 0
    if source_entity and source_entity.valid and source.line_sinks then
      for _, sink in pairs(source.line_sinks) do
        local sink_parts = transformers[sink.unit]
        local sink_entity = sink_parts and sink_parts.transformer
        if sink_entity and sink_entity.valid and sink_entity.surface.index == source_entity.surface.index then
          local key = source_unit .. ">" .. sink.unit
          seen[key] = true

          -- Proportional sharing: this route carries the source's output
          -- times the sink's share of the network's load
          local power = 0
          if load_total > 0 then
            power = (source.p_out or 0) * (sink_parts.p_in or 0) / load_total
          end
          local loss = get_route_line_loss(sink.d)
          local band = band_for(power, loss)
          local width = width_for(power)
          local text = shared.format_energy_number(power) .. " · " .. string.format("%.1f", loss * 100) .. "%"

          local route = state.routes[key]
          if route and not (rendering.get_object_by_id(route.line) or {}).valid then
            destroy_route(route)
            route = nil
          end

          if not route then
            local from, to = source_entity.position, sink_entity.position
            route = {
              band = band, width = width, text = text,
              line = rendering.draw_line{
                color = COLOURS[band], width = width,
                from = source_entity, to = sink_entity,
                surface = source_entity.surface, players = players,
                render_mode = "chart",
              }.id,
              dot = rendering.draw_circle{
                color = COLOURS[band], radius = 1.5, filled = true,
                target = sink_entity,
                surface = source_entity.surface, players = players,
                render_mode = "chart",
              }.id,
              label = rendering.draw_text{
                text = text, color = COLOURS[band], scale = 3,
                target = midpoint(from, to),
                surface = source_entity.surface, players = players,
                alignment = "center", vertical_alignment = "middle",
                render_mode = "chart",
              }.id,
            }
            state.routes[key] = route
          else
            local line = rendering.get_object_by_id(route.line)
            local dot = rendering.get_object_by_id(route.dot)
            local label = rendering.get_object_by_id(route.label)
            if route.band ~= band then
              for _, object in pairs({line, dot, label}) do
                if object and object.valid then object.color = COLOURS[band] end
              end
              route.band = band
            end
            if route.width ~= width and line and line.valid then
              line.width = width
              route.width = width
            end
            if route.text ~= text and label and label.valid then
              label.text = text
              route.text = text
            end
            if players_changed then
              for _, object in pairs({line, dot, label}) do
                if object and object.valid then object.players = players end
              end
            end
          end
        end
      end
    end
  end

  -- Routes that no longer exist (transformer removed, rewired)
  for key, route in pairs(state.routes) do
    if not seen[key] then
      destroy_route(route)
      state.routes[key] = nil
    end
  end
end
