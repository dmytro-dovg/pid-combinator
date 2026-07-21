local PidSettings = require "model.pid-settings"

---@alias KComponent "p"|"i"|"d"
---@alias WireType "red"|"green"
---@alias SettingsTargetKind "live"|"ghost"

---@alias SettingsTargetDescriptor
---| { kind: "live", unit_number: uint }
---| { kind: "ghost", entity: LuaEntity }

---@alias SignalType SignalID | string | PrototypeWithQuality

---A unified read/write interface over either a live combinator's storage
---state or a ghost's tag payload. Descriptors are safe to persist.
---Instances are rebuilt via `SettingsTarget.resolve` on load.
---@class SettingsTarget
---@field valid fun(self: SettingsTarget): boolean
---@field descriptor fun(self: SettingsTarget): SettingsTargetDescriptor
---@field unit_number fun(self: SettingsTarget): uint?
---@field preview_entity fun(self: SettingsTarget): LuaEntity?
---@field get_k fun(self: SettingsTarget, component: KComponent): number?
---@field set_k fun(self: SettingsTarget, component: KComponent, value: number)
---@field get_anti_windup_limit fun(self: SettingsTarget): number?
---@field set_anti_windup_limit fun(self: SettingsTarget, value: number)
---@field get_signal fun(self: SettingsTarget, role: SignalRole): SignalType?
---@field set_signal fun(self: SettingsTarget, role: SignalRole, value: SignalType?)
---@field get_network fun(self: SettingsTarget, role: SignalRole): NetworkFlags?
---@field set_network fun(self: SettingsTarget, role: SignalRole, wire_type: WireType, value: boolean)
---@field queue_output_connection_change fun(self: SettingsTarget, wire_type: WireType, value: boolean)

local SettingsTarget = {}

---@class Live: SettingsTarget
---@field unit uint
local Live = {}
Live.__index = Live

function Live:_state()
    return storage.pid and storage.pid[self.unit]
end

function Live:valid()
    local state = self:_state()
    return state ~= nil and state.entity ~= nil and state.entity.valid
end

function Live:descriptor()
    return { kind = "live", unit_number = self.unit }
end

function Live:unit_number()
    return self.unit
end

function Live:preview_entity()
    local state = self:_state()
    return state and state.entity
end

function Live:get_k(component)
    local state = self:_state()
    return state and state["k" .. component]
end

function Live:set_k(component, value)
    local state = self:_state()
    if state then state["k" .. component] = value end
end

function Live:get_anti_windup_limit()
    local state = self:_state()
    return state and state.anti_windup_limit
end

function Live:set_anti_windup_limit(value)
    local state = self:_state()
    if state then state.anti_windup_limit = value end
end

function Live:get_signal(role)
    local state = self:_state()
    return state and state.signals[role]
end

function Live:set_signal(role, value)
    local state = self:_state()
    if not state then return end
    state.signals[role] = value
    if role == "output" then state.last_value = nil end
end

function Live:get_network(role)
    local state = self:_state()
    return state and state.networks[role]
end

function Live:set_network(role, wire_type, value)
    local state = self:_state()
    local network = state and state.networks[role]
    if network then network[wire_type] = value end
end

function Live:queue_output_connection_change(wire_type, value)
    local state = self:_state()
    if not state then return end
    state.pending_connection_changes = state.pending_connection_changes or {}
    table.insert(state.pending_connection_changes, { wire_type = wire_type, value = value })
end

---@class Ghost: SettingsTarget
---@field entity LuaEntity
local Ghost = {}
Ghost.__index = Ghost

function Ghost:_read()
    if not self.entity.valid then return PidSettings.defaults() end
    local tags = self.entity.tags
    local stored = tags and tags.pid_settings
    if not stored then return PidSettings.defaults() end
    local settings = {}
    PidSettings.copy(stored, settings)
    return settings
end

function Ghost:_write(mutate)
    if not self.entity.valid then return end
    local tags = self.entity.tags or {}
    local settings = self:_read()
    mutate(settings)
    tags.pid_settings = settings
    -- entity.tags returns a copy. In-place mutation is dropped, so reassign the whole table.
    self.entity.tags = tags
end

function Ghost:valid()
    return self.entity ~= nil and self.entity.valid
end

function Ghost:descriptor()
    return { kind = "ghost", entity = self.entity }
end

function Ghost:unit_number()
    return self.entity.valid and self.entity.unit_number
end

function Ghost:preview_entity()
    return self.entity
end

function Ghost:get_k(component)
    return self:_read()["k" .. component]
end

function Ghost:set_k(component, value)
    self:_write(function(settings) settings["k" .. component] = value end)
end

function Ghost:get_anti_windup_limit()
    return self:_read().anti_windup_limit
end

function Ghost:set_anti_windup_limit(value)
    self:_write(function(settings) settings.anti_windup_limit = value end)
end

function Ghost:get_signal(role)
    return self:_read().signals[role]
end

function Ghost:set_signal(role, value)
    self:_write(function(settings) settings.signals[role] = value end)
end

function Ghost:get_network(role)
    return self:_read().networks[role]
end

function Ghost:set_network(role, wire_type, value)
    self:_write(function(settings)
        if settings.networks[role] then settings.networks[role][wire_type] = value end
    end)
end

-- No-op. Ghost has no wires.
function Ghost:queue_output_connection_change(_wire_type, _value)
end

---@param unit_number uint
---@return Live
function SettingsTarget.live(unit_number)
    return setmetatable({ unit = unit_number }, Live)
end

---@param entity LuaEntity
---@return Ghost
function SettingsTarget.ghost(entity)
    return setmetatable({ entity = entity }, Ghost)
end

---Rebuilds a target from a stored descriptor. Metatables/closures don't
---survive save/load in storage, so descriptors are the persistent form and
---this reconstructs the live/ghost instance.
---@param descriptor SettingsTargetDescriptor?
---@return SettingsTarget?
function SettingsTarget.resolve(descriptor)
    if not descriptor then return nil end
    if descriptor.kind == "live" then
        return SettingsTarget.live(descriptor.unit_number)
    elseif descriptor.kind == "ghost" then
        if not (descriptor.entity and descriptor.entity.valid) then return nil end
        return SettingsTarget.ghost(descriptor.entity)
    end
    return nil
end

return SettingsTarget
