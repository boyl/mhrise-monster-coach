local ActionReader = require("MHRiseMonsterCoach.action_reader")

local M = {}

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function find_method(type_name, method_name)
    return safe(function()
        local type_def = sdk.find_type_definition(type_name)
        return type_def and type_def:get_method(method_name) or nil
    end)
end

local function find_field(type_name, field_name)
    return safe(function()
        local type_def = sdk.find_type_definition(type_name)
        return type_def and type_def:get_field(field_name) or nil
    end)
end

function M.new(config, profile)
    local self = {
        config = config,
        profile = profile,
        reader = ActionReader.new(config),
        enemy = nil,
        enemy_id = nil,
        player = nil,
        player_data = nil,
        player_anchor = nil,
        enemy_anchor = nil,
        time_scale_owned = false,
        last_context = nil,
        last_player_health = nil,
        was_in_quest = false,
        game_name = safe(function() return reframework:get_game_name() end),
        tdb_version = safe(function() return sdk.get_tdb_version() end),
        capabilities = {},
    }

    self.methods = {
        enemy_update = find_method("snow.enemy.EnemyCharacterBase", "update"),
        enemy_destroy = find_method("snow.enemy.EnemyCharacterBase", "onDestroy"),
        enemy_is_boss = find_method("snow.enemy.EnemyCharacterBase", "get_isBossEnemy"),
        enemy_type = find_method("snow.enemy.EnemyCharacterBase", "get_EnemyType"),
        enemy_physical = find_method("snow.enemy.EnemyCharacterBase", "get_PhysicalParam"),
        player_data = find_method("snow.player.PlayerBase", "get_PlayerData"),
        lobby_online = find_method("snow.LobbyManager", "IsQuestOnline"),
        quest_playing = find_method("snow.QuestManager", "isPlayQuest"),
        quest_no = find_method("snow.QuestManager", "getQuestNo"),
    }
    if self.methods.enemy_physical then
        local physical_type = safe(function() return self.methods.enemy_physical:get_return_type() end)
        self.methods.physical_vital = physical_type and safe(function() return physical_type:get_method("getVital") end) or nil
        local vital_type = self.methods.physical_vital and safe(function() return self.methods.physical_vital:get_return_type() end) or nil
        self.methods.vital_current = vital_type and safe(function() return vital_type:get_method("get_Current") end) or nil
        self.methods.vital_max = vital_type and safe(function() return vital_type:get_method("get_Max") end) or nil
        self.methods.vital_set_current = vital_type and safe(function() return vital_type:get_method("set_Current") end) or nil
    end
    self.fields = {
        enemy_type = find_field("snow.enemy.EnemyCharacterBase", "<EnemyType>k__BackingField"),
        player_health = find_field("snow.player.PlayerData", "_r_Vital"),
        player_max_health = find_field("snow.player.PlayerData", "_vitalMax"),
        player_stamina = find_field("snow.player.PlayerData", "_stamina"),
        player_max_stamina = find_field("snow.player.PlayerData", "_staminaMax"),
    }
    return setmetatable(self, { __index = M })
end

function M.get_scene(self)
    local manager = sdk.get_native_singleton("via.SceneManager")
    if manager == nil then return nil end
    return safe(function()
        return sdk.call_native_func(manager, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end)
end

function M.set_time_scale(self, scale)
    local scene = M.get_scene(self)
    if scene == nil then return false, "Current scene unavailable" end
    local ok = pcall(function() scene:call("set_TimeScale", scale) end)
    if ok then self.time_scale_owned = scale ~= 1.0 end
    return ok, ok and nil or "set_TimeScale failed"
end

function M.restore_time_scale(self)
    if not self.time_scale_owned then return true end
    local ok = M.set_time_scale(self, 1.0)
    self.time_scale_owned = false
    return ok
end

local function normalize_enemy_id(value)
    if value == nil then return nil end
    if type(value) == "number" or type(value) == "string" then return value end
    return tostring(value)
end

function M.read_enemy_id(self, enemy)
    local value
    if self.methods.enemy_type then value = safe(function() return self.methods.enemy_type:call(enemy) end) end
    if value == nil and self.fields.enemy_type then value = safe(function() return self.fields.enemy_type:get_data(enemy) end) end
    return normalize_enemy_id(value)
end

function M.is_tigrex(self, enemy)
    local enemy_id = M.read_enemy_id(self, enemy)
    if enemy_id == nil then return false end
    if self.profile.enemy_ids[enemy_id] then return true end
    local numeric = tonumber(enemy_id)
    if numeric and self.profile.enemy_ids[numeric] then return true end
    local text = string.lower(tostring(enemy_id))
    return string.find(text, "em032_00", 1, true) ~= nil
end

function M.observe_enemy(self, enemy)
    if enemy == nil or self.methods.enemy_is_boss == nil then return end
    local is_boss = safe(function() return self.methods.enemy_is_boss:call(enemy) end)
    if not is_boss or not M.is_tigrex(self, enemy) then return end
    self.enemy = enemy
    self.enemy_id = M.read_enemy_id(self, enemy)
end

function M.install_enemy_hook(self, callback)
    if self.methods.enemy_update == nil then return false, "EnemyCharacterBase.update unavailable" end
    sdk.hook(self.methods.enemy_update, function(args)
        local enemy = sdk.to_managed_object(args[2])
        M.observe_enemy(self, enemy)
        if enemy == self.enemy then callback(enemy) end
    end, function(retval) return retval end)
    if self.methods.enemy_destroy then
        sdk.hook(self.methods.enemy_destroy, function(args)
            local enemy = sdk.to_managed_object(args[2])
            if enemy == self.enemy then
                self.enemy = nil
                self.enemy_id = nil
                self.enemy_anchor = nil
            end
        end, function(retval) return retval end)
    end
    return true
end

function M.refresh_player(self)
    local manager = sdk.get_managed_singleton("snow.player.PlayerManager")
    if manager == nil then self.player = nil self.player_data = nil return nil end
    self.player = safe(function() return manager:call("findMasterPlayer") end)
    if self.player and self.methods.player_data then
        self.player_data = safe(function() return self.methods.player_data:call(self.player) end)
    else
        self.player_data = nil
    end
    return self.player
end

function M.context(self)
    local quest = sdk.get_managed_singleton("snow.QuestManager")
    local lobby = sdk.get_managed_singleton("snow.LobbyManager")
    local in_quest = false
    local is_online = false
    if quest and self.methods.quest_playing then
        in_quest = safe(function() return self.methods.quest_playing:call(quest) end) == true
    end
    local quest_no = quest and self.methods.quest_no
        and safe(function() return self.methods.quest_no:call(quest) end) or nil
    if lobby and self.methods.lobby_online then
        is_online = safe(function() return self.methods.lobby_online:call(lobby) end) == true
    end
    if self.was_in_quest and not in_quest then
        M.restore_time_scale(self)
        self.enemy = nil
        self.enemy_id = nil
        self.player_anchor = nil
        self.enemy_anchor = nil
        self.last_player_health = nil
    end
    self.was_in_quest = in_quest
    M.refresh_player(self)
    local build_supported = self.game_name == self.config.supported_game_name
        and self.tdb_version == self.config.supported_tdb_version
    self.last_context = {
        in_quest = in_quest,
        quest_no = quest_no,
        is_online = is_online,
        target_found = self.enemy ~= nil,
        reader_ready = self.reader:ready(),
        player_found = self.player ~= nil,
        safe_mode = self.config.diagnostic_safe_mode == true,
        build_supported = build_supported,
        game_name = self.game_name,
        tdb_version = self.tdb_version,
    }
    return self.last_context
end

function M.read_action(self)
    if self.enemy == nil then return nil end
    return self.reader:read(self.enemy)
end

function M.read_player_health(self)
    if self.player_data == nil or self.fields.player_health == nil then return nil end
    return safe(function() return self.fields.player_health:get_data(self.player_data) end)
end

function M.restore_player_resources(self)
    if self.player_data == nil then return false, "PlayerData unavailable" end
    local health = self.fields.player_health
    local max_health = self.fields.player_max_health
    local stamina = self.fields.player_stamina
    local max_stamina = self.fields.player_max_stamina
    if not health or not max_health then return false, "Player health fields unavailable" end

    local max_hp = safe(function() return max_health:get_data(self.player_data) end)
    if max_hp == nil then return false, "Maximum health unavailable" end
    local ok = pcall(function()
        self.player_data:set_field("_r_Vital", max_hp)
        self.player_data:call("set__vital", max_hp + 0.0)
        if stamina and max_stamina then
            self.player_data:set_field("_stamina", max_stamina:get_data(self.player_data))
        end
    end)
    return ok, ok and nil or "Failed to restore player resources"
end

local function get_transform(component)
    if component == nil then return nil end
    return safe(function()
        local game_object = component:call("get_GameObject")
        return game_object and game_object:call("get_Transform") or nil
    end)
end

local function get_position(transform)
    return transform and safe(function() return transform:call("get_Position") end) or nil
end

function M.capture_anchors(self)
    if self.player == nil or self.enemy == nil then return false, "Player or Tigrex unavailable" end
    local player_transform = get_transform(self.player)
    local enemy_transform = get_transform(self.enemy)
    local player_position = get_position(player_transform)
    local enemy_position = get_position(enemy_transform)
    if player_position == nil or enemy_position == nil then return false, "Transform position unavailable" end
    self.player_anchor = player_position
    self.enemy_anchor = enemy_position
    return true
end

function M.restore_anchors(self)
    if self.player_anchor == nil or self.enemy_anchor == nil then return false, "Capture anchors with F8 first" end
    local player_transform = get_transform(self.player)
    local enemy_transform = get_transform(self.enemy)
    if player_transform == nil or enemy_transform == nil then return false, "Transform unavailable" end
    local ok = pcall(function()
        player_transform:call("set_Position", self.player_anchor)
        enemy_transform:call("set_Position", self.enemy_anchor)
    end)
    return ok, ok and nil or "Position reset failed"
end

function M.restore_monster_health(self)
    if self.enemy == nil or not self.methods.enemy_physical or not self.methods.physical_vital then
        return false, "Monster vital capability unavailable"
    end
    local physical = safe(function() return self.methods.enemy_physical:call(self.enemy) end)
    if physical == nil then return false, "Monster PhysicalParam unavailable" end
    local vital = safe(function() return self.methods.physical_vital:call(physical, 0, 0) end)
    if vital == nil then return false, "Monster vital unavailable" end
    local maximum = self.methods.vital_max and safe(function() return self.methods.vital_max:call(vital) end) or nil
    if maximum == nil then return false, "Monster maximum health unavailable" end

    local ok = false
    if self.methods.vital_set_current then
        ok = pcall(function() self.methods.vital_set_current:call(vital, maximum) end)
    else
        ok = pcall(function() vital:call("set_Current", maximum) end)
    end
    return ok, ok and nil or "Monster health setter unavailable"
end

function M.quick_reset(self)
    M.restore_time_scale(self)
    local player_ok, player_error = M.restore_player_resources(self)
    local monster_ok, monster_error = M.restore_monster_health(self)
    local anchor_ok, anchor_error = M.restore_anchors(self)
    if not player_ok then return false, player_error end
    if not monster_ok then return false, monster_error end
    if not anchor_ok then return false, anchor_error end
    return true
end

function M.screen_size(self)
    local manager = sdk.get_native_singleton("via.SceneManager")
    if manager == nil then return 1920, 1080 end
    local view = safe(function()
        return sdk.call_native_func(manager, sdk.find_type_definition("via.SceneManager"), "get_MainView")
    end)
    if view == nil then return 1920, 1080 end
    local size = safe(function() return view:call("get_Size") end)
    if size == nil then return 1920, 1080 end
    local width = safe(function() return size:get_field("w") end)
    local height = safe(function() return size:get_field("h") end)
    return tonumber(width) or 1920, tonumber(height) or 1080
end

return M
