-- Adds watt-hour readouts (Wh, kWh, MWh, ...) to tooltips and Factoriopedia:
-- "Fuel value" on every prototype with a fuel value (items, fluids) and
-- "Capacity" on accumulators and battery equipment. The game's own joule
-- values are left as they are; this only adds a row.
-- Runs in data-final-fixes so values changed by other mods are converted.
-- Startup setting "power-overload-energy-tooltips" turns it off.

if not settings.startup["power-overload-energy-tooltips"].value then return end

local util = require("util")

local function add_field(prototype, label_key, energy)
  if type(energy) ~= "string" then return end
  local ok, joules = pcall(util.parse_energy, energy)
  if not ok or not joules or joules <= 0 then return end
  prototype.custom_tooltip_fields = prototype.custom_tooltip_fields or {}
  table.insert(prototype.custom_tooltip_fields, {
    name = {"po-energy." .. label_key},
    value = shared.format_watt_hours(joules),
  })
end

for _, prototypes_of_type in pairs(data.raw) do
  for _, prototype in pairs(prototypes_of_type) do
    if type(prototype) == "table" and prototype.fuel_value then
      add_field(prototype, "fuel-value", prototype.fuel_value)
    end
  end
end

for _, type_name in pairs({"accumulator", "battery-equipment"}) do
  for _, prototype in pairs(data.raw[type_name] or {}) do
    if prototype.energy_source then
      add_field(prototype, "capacity", prototype.energy_source.buffer_capacity)
    end
  end
end
