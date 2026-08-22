local ActionReader = require("MHRiseMonsterCoach.action_reader")
local QuestListOrder = require("MHRiseMonsterCoach.quest_list_order")
local PlayerStateReader = require("MHRiseMonsterCoach.player_state_reader")
local HitboxProvider = require("MHRiseMonsterCoach.hitbox_provider")
local QuestRestart = require("MHRiseMonsterCoach.quest_restart")
local EnvironmentCreatureRecorder = require("MHRiseMonsterCoach.environment_creature_recorder")
local MonsterRespawn = require("MHRiseMonsterCoach.monster_respawn")
local BehaviorTreeReader = require("MHRiseMonsterCoach.behavior_tree_reader")
local ThinkContextReader = require("MHRiseMonsterCoach.think_context_reader")

local M = {}
local NATIVE_IN_PLACE_RESET_VALIDATED = false
local get_transform, get_position, read_area_no, clear_enemy

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function plain_vector(value)
    if value == nil then return nil end
    return safe(function()
        return { x = tonumber(value.x), y = tonumber(value.y), z = tonumber(value.z) }
    end)
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

local function enum_value(type_name, field_name)
    local field = find_field(type_name, field_name)
    return field and safe(function() return field:get_data(nil) end) or nil
end

function M.new(config, profile)
    local default_arena_navigation = safe(function()
        return json.load_file("MHRiseMonsterCoach/arena_navigation_defaults.json")
    end)
    local saved_arena_navigation = safe(function()
        return json.load_file("MHRiseMonsterCoach/arena_navigation_anchors.json")
    end)
    local saved_markers = {}
    local function merge_marker_document(document, source_prefix)
        if type(document) ~= "table" then return end
        local marker_document = document
        if type(document.maps) == "table" then
            marker_document = document.maps[tostring(profile.training_quest.map_id)]
        elseif tonumber(document.map_id) ~= tonumber(profile.training_quest.map_id) then
            return
        end
        if type(marker_document) ~= "table" or type(marker_document.markers) ~= "table" then return end
        for index, entry in ipairs(marker_document.markers) do
            if type(entry) == "table" and type(entry.position) == "table" then
                saved_markers[tostring(entry.key or (source_prefix .. ":" .. tostring(index)))] = entry
            end
        end
    end
    merge_marker_document(default_arena_navigation, "default")
    merge_marker_document(saved_arena_navigation, "learned")
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
        pending_quest_list = nil,
        pending_quest_order_ids = nil,
        pending_quest_order_attempts = 0,
        pending_quest_order_logged = false,
        quest_order_warned = false,
        game_name = safe(function() return reframework:get_game_name() end),
        tdb_version = safe(function() return sdk.get_tdb_version() end),
        capabilities = {},
        quest_posting = {
            active = false,
            direct_session = false,
            action = nil,
            action_arg = nil,
            hooks = {},
        },
        quest_reset_trace = {
            active = false,
            dirty = false,
            events = {},
            next_sequence = 0,
            hooks = {},
            lifecycle_hook_failures = {},
        },
        action_request_trace = {
            installed = false,
            dirty = false,
            calls = 0,
            events = {},
        },
        arena_transfer_focus = nil,
        arena_transfer_trace = {},
        arena_transfer_marker_cache = saved_markers,
        arena_transfer_access_count = 0,
        arena_transfer_last_access_clock = nil,
        arena_transfer_focus_sequence = 0,
        environment_creature_recorder = EnvironmentCreatureRecorder.new(256),
        environment_creature_field_cache = {},
        environment_creature_saved_revision = 0,
        enemy_spawn_contract_address = nil,
        enemy_spawn_contract_history = {},
        monster_respawn = nil,
        startup_flow = {
            phase = nil,
            hooks = {},
            hook_failures = {},
            autosave_notice_seen = false,
            force_autosave_notice_success = false,
        },
    }

    local hitbox_runtime_supported = self.game_name == config.supported_game_name
        and self.tdb_version == config.supported_tdb_version
    self.hitbox_provider = HitboxProvider.new({
        enabled = hitbox_runtime_supported,
        disabled_reason = string.format("Native hitbox hook disabled for %s / TDB %s",
            tostring(self.game_name), tostring(self.tdb_version)),
    })
    self.hitbox_provider:set_debug_shapes(config.show_hitboxviewer_debug_shapes == true)

    self.methods = {
        enemy_type = find_method("snow.enemy.EnemyCharacterBase", "get_EnemyType"),
        boss_enemy_count = find_method("snow.enemy.EnemyManager", "getBossEnemyCount"),
        boss_enemy = find_method("snow.enemy.EnemyManager", "getBossEnemy"),
        enemy_physical = find_method("snow.enemy.EnemyCharacterBase", "get_PhysicalParam"),
        player_data = find_method("snow.player.PlayerBase", "get_PlayerData"),
        lobby_online = find_method("snow.LobbyManager", "IsQuestOnline"),
        quest_playing = find_method("snow.QuestManager", "isPlayQuest"),
        quest_no = find_method("snow.QuestManager", "getQuestNo"),
        quest_notify_reset = find_method("snow.QuestManager", "notifyReset"),
        quest_active = find_method("snow.QuestManager", "isActiveQuest"),
        quest_data = find_method("snow.QuestManager", "getQuestData(System.Int32)"),
        player_native_warp = find_method("snow.player.PlayerBase", "setPosWarpConsiderDogRide(via.vec3)"),
        enemy_native_warp_init = find_method("snow.enemy.EnemyCharacterBase", "warpEnemyInitPos"),
        character_area_no = find_method("snow.CharacterBase", "get_AreaNo"),
        enemy_set_info = find_method("snow.enemy.EnemyCharacterBase", "get_SetInfo"),
        enemy_destroy = find_method("snow.enemy.EnemyManager", "destroyEnemy(snow.enemy.EnemyCharacterBase)"),
        set_info_destroy = find_method("snow.enemy.EnemySetInfo", "destroyEnemy(System.Int32, snow.enemy.EnemyManager.DestroyStatus)"),
        set_info_repop = find_method("snow.enemy.EnemySetInfo", "repop"),
        enemy_create_from_set = find_method("snow.enemy.EnemyManager", "createEnemyFromSetInfo(snow.enemy.EnemySetInfo, snow.enemy.EnemyDef.EnemySetType, System.Int32)"),
        enemy_create_from_set_runtime = find_method("snow.enemy.EnemyManager", "createEnemyFromSetInfoNetSend(snow.enemy.EnemySetInfo, System.Boolean, snow.enemy.EnemyDef.EnemySetType, System.Int32)"),
        enemy_notify_create = find_method("snow.enemy.EnemyManager", "notifyCreateEnemy(snow.enemy.EnemySetInfo)"),
        enemy_create_set_info = find_method("snow.enemy.EnemyManager", "createEnemySetInfo(snow.quest.EnemySetParam)"),
        enemy_set_action_unique = find_method("snow.enemy.em032.Em032CharacterBase",
            "setActionUnique(snow.enemy.EnemyDef.EmActCategory, System.UInt16)"),
        enemy_request_no_change_action = find_method("snow.enemy.EnemyCharacterBase",
            "requestNoChangeTargetActionSet(snow.enemy.SetupActionBaseData)"),
    }
    self.player_state_reader = PlayerStateReader.new(self.game_name, self.tdb_version)
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
    self.monster_respawn = MonsterRespawn.new(M.monster_respawn_api(self))
    local posting_ready, posting_reason = M.install_quest_posting_hooks(self)
    self.capabilities.quest_posting = posting_ready
    self.capabilities.quest_posting_reason = posting_reason
    local trace_ready, trace_reason = M.install_quest_reset_trace_hooks(self)
    self.capabilities.quest_reset_trace = trace_ready
    self.capabilities.quest_reset_trace_reason = trace_reason
    local transfer_ready, transfer_reason = M.install_arena_transfer_focus_hook(self)
    self.capabilities.arena_transfer = transfer_ready
    self.capabilities.arena_transfer_reason = transfer_reason
    self.quest_restart = QuestRestart.new(M.quest_restart_api(self), profile.training_quest.id)
    M.install_startup_flow_hooks(self)
    M.dump_in_place_reset_metadata(self)
    M.dump_in_place_type_candidates(self)
    M.dump_title_flow_metadata(self)
    M.dump_action_request_metadata(self)
    local action_observer_ready, action_observer_reason = M.install_action_request_observer(self)
    self.capabilities.action_request_observer = action_observer_ready
    self.capabilities.action_request_observer_reason = action_observer_reason
    return setmetatable(self, { __index = M })
end

function M.install_action_request_observer(self)
    local function owner_type_name(args)
        local owner = safe(function() return sdk.to_managed_object(args[2]) end)
        return owner and safe(function()
            local definition = owner:get_type_definition()
            return definition and definition:get_full_name() or nil
        end) or nil
    end
    local function snapshot_payload(value)
        local payload = safe(function() return sdk.to_managed_object(value) end)
        if payload == nil then return nil end
        local result = { type = safe(function()
            local definition = payload:get_type_definition()
            return definition and definition:get_full_name() or nil
        end), fields = {} }
        local type_def = safe(function() return payload:get_type_definition() end)
        local seen, depth = {}, 0
        while type_def and depth < 8 do
            local current_name = safe(function() return type_def:get_full_name() end) or "unknown"
            if seen[current_name] then break end
            seen[current_name] = true
            for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
                local name = safe(function() return field:get_name() end)
                local field_value = safe(function() return field:get_data(payload) end)
                if type(field_value) == "number" or type(field_value) == "boolean"
                    or type(field_value) == "string" then
                    result.fields[current_name .. "." .. tostring(name)] = field_value
                end
            end
            type_def = safe(function() return type_def:get_parent_type() end)
            depth = depth + 1
        end
        return result
    end
    local function record(method_name, args, payload_index, category_index, action_index)
        local owner_type = owner_type_name(args)
        if not owner_type or not string.find(string.lower(owner_type), "em032", 1, true) then return end
        local trace = self.action_request_trace
        trace.calls = trace.calls + 1
        local event = {
            sequence = trace.calls,
            method = method_name,
            owner_type = owner_type,
            source = trace.request_tag or "game",
        }
        if payload_index then event.payload = snapshot_payload(args[payload_index]) end
        if category_index then
            event.category = tonumber(safe(function() return sdk.to_int64(args[category_index]) end)
                or safe(function() return sdk.to_int(args[category_index]) end))
        end
        if action_index then
            event.action_no = tonumber(safe(function() return sdk.to_int64(args[action_index]) end)
                or safe(function() return sdk.to_int(args[action_index]) end))
        end
        trace.events[#trace.events + 1] = event
        if #trace.events > 512 then table.remove(trace.events, 1) end
        trace.dirty = true
    end
    local candidates = {
        { "snow.enemy.em032.Em032CharacterBase", "setActionUnique(snow.enemy.EnemyDef.EmActCategory, System.UInt16)", nil, 3, 4 },
        { "snow.enemy.EnemyCharacterBase", "requestActionSet(snow.enemy.SetupActionBaseData)", 3 },
        { "snow.enemy.EnemyCharacterBase", "requestNoChangeTargetActionSet(snow.enemy.SetupActionBaseData)", 3 },
        { "snow.enemy.EnemyCharacterBase", "setAction(snow.enemy.SetupActionBaseData)", 3 },
        { "snow.enemy.EnemyCharacterBase", "setActionParam(snow.enemy.SetupActionBaseData)", 3 },
        { "snow.enemy.EnemyCharacterBase", "startActionTable", nil },
    }
    local installed, failures = 0, {}
    for _, candidate in ipairs(candidates) do
        local method = find_method(candidate[1], candidate[2])
        if method then
            local ok, reason = pcall(function()
                sdk.hook(method, function(args)
                    record(candidate[2], args, candidate[3], candidate[4], candidate[5])
                end, function(retval) return retval end)
            end)
            if ok then installed = installed + 1
            else failures[#failures + 1] = candidate[2] .. ": " .. tostring(reason) end
        else
            failures[#failures + 1] = candidate[2] .. ": unavailable"
        end
    end
    self.action_request_trace.installed = installed > 0
    self.action_request_trace.hook_count = installed
    self.action_request_trace.hook_failures = failures
    return installed > 0, table.concat(failures, "; ")
end

function M.persist_action_request_trace(self)
    local trace = self.action_request_trace
    if not trace or not trace.dirty then return false end
    local written = safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_action_request_trace.json", {
            schema_version = 1,
            policy = "observe_natural_action_request_pipeline_only",
            runtime = { game_name = self.game_name, tdb_version = self.tdb_version },
            installed = trace.installed,
            hook_count = trace.hook_count,
            hook_failures = trace.hook_failures,
            calls = trace.calls,
            events = trace.events,
        })
        return true
    end) == true
    if written then trace.dirty = false end
    return written
end

function M.install_arena_transfer_focus_hook(self)
    local candidates = {
        { "snow.access.QuestAreaMovePopMarker", "intoFocus" },
        { "snow.access.QuestAreaMovePopMarker", "outOfFocus" },
        { "snow.access.ObjectPopMarker", "eventIntoFocus" },
        { "snow.access.ObjectPopMarker", "eventOutOfFocus" },
        { "snow.access.ObjectPopMarker", "eventIntoAccessable" },
        { "snow.access.ObjectPopMarker", "eventOnAccessable" },
        { "snow.access.ObjectPopMarker", "eventAccessStart" },
        { "snow.access.ObjectPopMarker", "eventAccess" },
        { "snow.access.ObjectPopMarker", "eventAccessEnd" },
        { "snow.access.ObjectPopMarker", "onAccessStart" },
        { "snow.access.ObjectPopMarker", "onAccess" },
        { "snow.access.ObjectPopMarker", "onAccessEnd" },
        { "snow.access.ObjectPopMarker", "callBeforeAccessMethod" },
        { "snow.access.ObjectPopMarker", "callAccessStartMethod" },
        { "snow.access.ObjectPopMarker", "callAccessMethod" },
        { "snow.access.ObjectPopMarker", "callAccessEndMethod" },
    }
    local installed = 0
    local errors = {}
    for _, candidate in ipairs(candidates) do
        local candidate_type = candidate[1]
        local candidate_method = candidate[2]
        local method = find_method(candidate_type, candidate_method)
        if method then
            local ok, reason = pcall(function()
                sdk.hook(method, function(args)
                    local marker = safe(function() return sdk.to_managed_object(args[2]) end)
                    local marker_type = marker and safe(function()
                        return marker:get_type_definition():get_full_name()
                    end) or ""
                    local first = safe(function() return sdk.to_managed_object(args[3]) end)
                    local second = safe(function() return sdk.to_managed_object(args[4]) end)
                    if string.find(tostring(marker_type), "QuestAreaMovePopMarker", 1, true) then
                        local event_clock = os.clock()
                        local marker_position = get_position(get_transform(marker))
                        local marker_key = tostring(safe(function() return marker:get_address() end) or marker)
                        if marker_position ~= nil then
                            self.arena_transfer_marker_cache[marker_key] = {
                                key = marker_key,
                                type_name = marker_type,
                                position = plain_vector(marker_position),
                                cached = true,
                            }
                            safe(function()
                                local persisted = {}
                                for _, entry in pairs(self.arena_transfer_marker_cache) do
                                    persisted[#persisted + 1] = entry
                                end
                                json.dump_file("MHRiseMonsterCoach/arena_navigation_anchors.json", {
                                    schema_version = 1,
                                    map_id = self.profile.training_quest.map_id,
                                    source = "native_QuestAreaMovePopMarker_focus",
                                    markers = persisted,
                                })
                            end)
                        end
                        self.arena_transfer_trace[#self.arena_transfer_trace + 1] = {
                            sequence = #self.arena_transfer_trace + 1,
                            clock = event_clock,
                            name = candidate_type .. "." .. candidate_method,
                            marker_address = tostring(safe(function() return marker:get_address() end)),
                            marker_position = plain_vector(marker_position),
                            player_position = plain_vector(get_position(get_transform(self.player))),
                            first_address = first and tostring(safe(function() return first:get_address() end)) or nil,
                            second_address = second and tostring(safe(function() return second:get_address() end)) or nil,
                        }
                        while #self.arena_transfer_trace > 128 do table.remove(self.arena_transfer_trace, 1) end
                        safe(function()
                            json.dump_file("MHRiseMonsterCoach/runtime_arena_transfer_trace.json", {
                                schema_version = 1,
                                policy = "passive_native_area_transfer_trace",
                                events = self.arena_transfer_trace,
                            })
                        end)
                        local leaving_focus = candidate_method == "outOfFocus"
                            or candidate_method == "eventOutOfFocus"
                        local entering_focus = candidate_method == "intoFocus"
                            or candidate_method == "eventIntoFocus"
                        local access_start = candidate_method == "eventAccessStart"
                            or candidate_method == "onAccessStart"
                            or candidate_method == "callAccessStartMethod"
                        if entering_focus then
                            self.arena_transfer_focus_sequence = self.arena_transfer_focus_sequence + 1
                        end
                        if access_start and (self.arena_transfer_last_access_clock == nil
                            or event_clock - self.arena_transfer_last_access_clock > 0.25) then
                            self.arena_transfer_access_count = self.arena_transfer_access_count + 1
                            self.arena_transfer_last_access_clock = event_clock
                        end
                        if leaving_focus then
                            if self.arena_transfer_focus == nil
                                or self.arena_transfer_focus.marker == marker then
                                self.arena_transfer_focus = nil
                            end
                        elseif first and second then self.arena_transfer_focus = {
                            marker = marker,
                            first = first,
                            second = second,
                            request = safe(function()
                                local infos = marker:get_field("_AreaMoveInfos")
                                local elements = infos and infos:get_elements() or nil
                                if elements == nil then return nil end
                                for _, info in ipairs(elements) do
                                    if info and info:call("isEnabled") == true then
                                        return info:call("get_QuestAreaMoveRequest")
                                    end
                                end
                                return nil
                            end),
                            source = candidate_type .. "." .. candidate_method,
                            clock = os.clock(),
                        } end
                    end
                end, function(retval) return retval end)
            end)
            if ok then installed = installed + 1 else errors[#errors + 1] = tostring(reason) end
        end
    end
    return installed > 0, installed > 0 and nil
        or (errors[1] or "Quest area transfer focus hooks unavailable")
end

function M.install_startup_flow_hooks(self)
    local candidates = {
        { "snow.gui.fsm.title.GuiGameStartFsm_AutoSaveCaution_Action", "autosave_notice" },
        { "snow.gui.fsm.title.GuiTitleFsm_PressAnyButton_Action", "press_any" },
        { "snow.gui.fsm.title.GuiTitleFsm_TitleMenu_Action", "title_menu" },
        { "snow.gui.fsm.title.GuiTitleFsm_LoadDataSelectMenuStart", "save_menu" },
        { "snow.gui.fsm.title.GuiTitleFsm_LoadDataSelectMenuInit", "save_menu" },
        { "snow.gui.fsm.title.GuiTitleFsm_LoadDataSelectMenuEnd", "save_menu" },
    }
    for _, candidate in ipairs(candidates) do
        local phase = candidate[2]
        local method = find_method(candidate[1], "update(via.behaviortree.ActionArg)")
        if method then
            local ok, reason = pcall(function()
                sdk.hook(method, function()
                    self.startup_flow.phase = phase
                    if phase == "autosave_notice" then
                        self.startup_flow.autosave_notice_seen = true
                    end
                    if phase == "save_menu" then self.startup_flow.force_continue = false end
                    if phase == "title_menu" and self.startup_flow.force_continue == true then
                        local manager = sdk.get_managed_singleton(
                            "snow.gui.fsm.title.GuiTitleFsmManager")
                        local success = enum_value(
                            "snow.gui.SnowGuiCommonUtility.BaseBranchValue", "SUCCESS")
                        local branch_ok, branch_error = pcall(function()
                            manager:setBaseBranchValue(success)
                        end)
                        if branch_ok then return sdk.PreHookResult.SKIP_ORIGINAL end
                        self.startup_flow.transition_error = tostring(branch_error)
                    end
                end, function(retval)
                    if phase == "autosave_notice"
                        and self.startup_flow.force_autosave_notice_success == true then
                        local manager = sdk.get_managed_singleton(
                            "snow.gui.fsm.title.GuiGameStartFsmManager")
                        local success = enum_value(
                            "snow.gui.SnowGuiCommonUtility.BaseBranchValue", "SUCCESS")
                        local branch_ok, branch_error = pcall(function()
                            manager:setBaseBranchValue(success)
                        end)
                        if not branch_ok then
                            self.startup_flow.transition_error = tostring(branch_error)
                        end
                    end
                    return retval
                end)
            end)
            if ok then
                self.startup_flow.hooks[#self.startup_flow.hooks + 1] = candidate[1]
            else
                self.startup_flow.hook_failures[#self.startup_flow.hook_failures + 1] = tostring(reason)
            end
        else
            self.startup_flow.hook_failures[#self.startup_flow.hook_failures + 1] = candidate[1]
        end
    end
    return #self.startup_flow.hooks > 0
end

local RESET_TRACE_METHODS = {
    "notifyReset", "notifyReturn", "onQuestReturn", "reqOpenDialogQuestReturn",
    "requestQuestUI_EndQuestStart", "setupQuest_LoadQuest", "initSyncBeforeLoad",
    "executeSyncBeforeLoad", "loadQuestStartTempData", "lotBeforeLoad",
    "netSendQuestDoneResult",
}

local RESET_TRACE_LIFECYCLE_METHODS = {
    ["snow.enemy.EnemySetInfo"] = {
        ".ctor",
        "destroyEnemy",
        "repop",
        "resetEnemy",
        "updateDestroyStatus",
        "updateSetStatus",
    },
    ["snow.enemy.EnemyManager"] = {
        "registerRequestDestroyEnemyList",
        "destroyEnemy",
        "destroyEnemyGameObject",
        "createEnemySetInfo",
        "createEnemyFromSetInfo",
        "notifyCreateEnemy",
    },
}

local QUEST_LAUNCH_KEYWORDS = {
    "orderquest", "questorder", "startquest", "queststart", "loadquest", "questload",
    "acceptquest", "questaccept", "requestquest", "questrequest", "depart", "departure",
    "entryquest", "questentry", "decidequest", "questdecide", "questcounter",
}

local function is_quest_launch_candidate(name)
    local lower = string.lower(tostring(name or ""))
    for _, keyword in ipairs(QUEST_LAUNCH_KEYWORDS) do
        if string.find(lower, keyword, 1, true) then return true end
    end
    return false
end

local function append_reset_trace_event(self, kind, name, context, details)
    local trace = self.quest_reset_trace
    if not trace or not trace.active or #trace.events >= 256 then return end
    trace.next_sequence = trace.next_sequence + 1
    local event = {
        sequence = trace.next_sequence,
        kind = kind,
        name = name,
        clock = os.clock(),
        in_quest = context and context.in_quest or nil,
        quest_no = context and context.quest_no or nil,
        target_found = context and context.target_found or nil,
    }
    for key, value in pairs(details or {}) do event[key] = value end
    trace.events[#trace.events + 1] = event
    trace.dirty = true
end

local function managed_address(value)
    local object = safe(function() return sdk.to_managed_object(value) end)
    return object and tostring(safe(function() return object:get_address() end)) or nil
end

local function native_int32(value)
    local raw = safe(function() return sdk.to_int64(value) end)
        or safe(function() return sdk.to_int(value) end)
    if raw == nil then return nil end
    local low = raw % 4294967296
    if low >= 2147483648 then low = low - 4294967296 end
    return low
end

local function lifecycle_trace_details(event_name, args)
    local details = { owner_address = managed_address(args[2]) }
    if event_name == "snow.enemy.EnemySetInfo..ctor" then
        details.em_set_id = native_int32(args[3])
        details.unique_id = native_int32(args[4])
        details.enemy_set_param_address = managed_address(args[5])
    elseif event_name == "snow.enemy.EnemyManager.destroyEnemy" then
        details.enemy_address = managed_address(args[3])
    elseif event_name == "snow.enemy.EnemySetInfo.destroyEnemy" then
        details.enemy_index = native_int32(args[3])
        details.destroy_status = native_int32(args[4])
    elseif event_name == "snow.enemy.EnemyManager.createEnemySetInfo" then
        details.enemy_set_param_address = managed_address(args[3])
    elseif event_name == "snow.enemy.EnemyManager.createEnemyFromSetInfo" then
        details.set_info_address = managed_address(args[3])
        details.enemy_set_type = native_int32(args[4])
        details.enemy_index = native_int32(args[5])
    end
    return details
end

local function lifecycle_trace_post_details(event_name, retval)
    if event_name == "snow.enemy.EnemyManager.createEnemySetInfo" then
        return { returned_set_info_address = managed_address(retval) }
    end
    return nil
end

function M.install_quest_reset_trace_hooks(self)
    local quest_type = safe(function() return sdk.find_type_definition("snow.QuestManager") end)
    if quest_type == nil then return false, "QuestManager type unavailable" end
    local candidates = {}
    local seen = {}
    for _, name in ipairs(RESET_TRACE_METHODS) do
        local method = safe(function() return quest_type:get_method(name) end)
        if method then candidates[#candidates + 1] = { name = name, method = method } seen[name] = true end
    end
    for _, method in ipairs(safe(function() return quest_type:get_methods() end) or {}) do
        local name = safe(function() return method:get_name() end)
        if name and is_quest_launch_candidate(name) and not seen[name] and #candidates < 80 then
            candidates[#candidates + 1] = { name = name, method = method }
            seen[name] = true
        end
    end
    for _, candidate in ipairs(candidates) do
        local method_name = candidate.name
        local method = candidate.method
        if method then
            local ok = pcall(function()
                sdk.hook(method, function()
                    append_reset_trace_event(self, "method_pre", method_name)
                end, function(retval)
                    append_reset_trace_event(self, "method_post", method_name)
                    return retval
                end)
            end)
            if ok then self.quest_reset_trace.hooks[#self.quest_reset_trace.hooks + 1] = method_name end
        end
    end
    for requested_type, method_names in pairs(RESET_TRACE_LIFECYCLE_METHODS) do
        local type_def = safe(function() return sdk.find_type_definition(requested_type) end)
        if type_def == nil then
            self.quest_reset_trace.lifecycle_hook_failures[#self.quest_reset_trace.lifecycle_hook_failures + 1]
                = requested_type .. ": type unavailable"
        end
        for _, method_name in ipairs(method_names) do
            local method = type_def and safe(function() return type_def:get_method(method_name) end)
            if method then
                local event_name = requested_type .. "." .. method_name
                local ok, reason = pcall(function()
                    sdk.hook(method, function(args)
                        append_reset_trace_event(self, "lifecycle_pre", event_name, nil,
                            lifecycle_trace_details(event_name, args))
                    end, function(retval)
                        append_reset_trace_event(self, "lifecycle_post", event_name, nil,
                            lifecycle_trace_post_details(event_name, retval))
                        return retval
                    end)
                end)
                if ok then self.quest_reset_trace.hooks[#self.quest_reset_trace.hooks + 1] = event_name end
                if not ok then
                    self.quest_reset_trace.lifecycle_hook_failures[
                        #self.quest_reset_trace.lifecycle_hook_failures + 1]
                        = event_name .. ": " .. tostring(reason)
                end
            elseif type_def then
                self.quest_reset_trace.lifecycle_hook_failures[
                    #self.quest_reset_trace.lifecycle_hook_failures + 1]
                    = requested_type .. "." .. method_name .. ": method unavailable"
            end
        end
    end
    return #self.quest_reset_trace.hooks > 0,
        #self.quest_reset_trace.hooks > 0 and nil or "No reset trace hooks installed"
end

function M.start_quest_reset_trace(self, context)
    local trace = self.quest_reset_trace
    trace.active = true
    trace.dirty = true
    trace.events = {}
    trace.next_sequence = 0
    trace.last_state_key = nil
    append_reset_trace_event(self, "trace", "armed", context)
    return true
end

function M.flush_quest_reset_trace(self, context, stop)
    local trace = self.quest_reset_trace
    if not trace or not trace.active then return false end
    local state_key = table.concat({
        tostring(context and context.in_quest), tostring(context and context.quest_no),
        tostring(context and context.target_found),
    }, "|")
    if state_key ~= trace.last_state_key then
        trace.last_state_key = state_key
        append_reset_trace_event(self, "state", "context_changed", context)
    end
    if stop then append_reset_trace_event(self, "trace", "completed", context) end
    if trace.dirty then
        safe(function()
            json.dump_file("MHRiseMonsterCoach/runtime_quest_reset_trace.json", {
                schema_version = 1,
                policy = "hook_observation_only_no_gameplay_method_invocation",
                hooks = trace.hooks,
                lifecycle_hook_failures = trace.lifecycle_hook_failures,
                active = not stop,
                events = trace.events,
            })
        end)
        trace.dirty = false
    end
    if stop then trace.active = false end
    return true
end

function M.request_native_quest_reset(self)
    local context = self.last_context or {}
    if self.config.native_quest_reset_enabled ~= true then
        return false, "Native quest reset is disabled"
    end
    if self.game_name ~= self.config.supported_game_name
        or self.tdb_version ~= self.config.supported_tdb_version then
        return false, "Unsupported runtime"
    end
    if not context.in_quest or context.is_online
        or tonumber(context.quest_no) ~= self.profile.training_quest.id then
        return false, "Native reset is limited to the single-player training quest"
    end
    if self.methods.quest_notify_reset == nil then return false, "QuestManager.notifyReset unavailable" end
    local manager = sdk.get_managed_singleton("snow.QuestManager")
    if manager == nil then return false, "QuestManager unavailable" end
    M.restore_time_scale(self)
    local ok = pcall(function() self.methods.quest_notify_reset:call(manager) end)
    return ok, ok and nil or "QuestManager.notifyReset call failed"
end

local function posting_active(self)
    return self.quest_posting and self.quest_posting.active == true
end

local function install_conditional_hook(self, type_name, method_name, pre, post)
    local method = find_method(type_name, method_name)
    if method == nil then return false, type_name .. "." .. method_name .. " unavailable" end
    local last_args
    local ok, reason = pcall(function()
        sdk.hook(method, function(args)
            last_args = args
            if posting_active(self) and pre then return pre(args) end
        end, function(retval)
            if posting_active(self) and post then
                local replacement = post(retval, last_args)
                if replacement ~= nil then return sdk.to_ptr(replacement) end
            end
            return retval
        end)
    end)
    if ok then self.quest_posting.hooks[#self.quest_posting.hooks + 1] = method_name end
    return ok, ok and nil or tostring(reason)
end

function M.install_quest_posting_hooks(self)
    local skip = function() return sdk.PreHookResult.SKIP_ORIGINAL end
    local true_post = function() return true end
    local hooks = {
        { "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager",
            "getQuestCounterSelectedQuest()", nil, function()
                local manager = sdk.get_managed_singleton("snow.QuestManager")
                if manager == nil or self.methods.quest_data == nil then return nil end
                return safe(function()
                    return self.methods.quest_data:call(manager, self.profile.training_quest.id)
                end)
            end },
        { "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager", "awake()", function(args)
            local counter = sdk.to_managed_object(args[2])
            local access = enum_value(
                "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager.QuestCounterAccessType", "HallCounter")
            if counter and access ~= nil then counter:call("set_QuestCounterType", access) end
        end },
        { "snow.gui.GuiManager", "IsCanFieldObjectAccessSub()", nil, true_post },
        { "snow.gui.GuiManager", "isDisplayForHeadMessage(System.Boolean)", nil, true_post },
        { "snow.SnowSessionManager", "reqOnlineWarning()", skip },
        { "snow.gui.GuiManager", "updateYNInfoWindow(System.UInt32)", nil, function()
            return enum_value("snow.gui.GuiCommonYNInfoWindow.YNInfoUIState", "Yes_on")
        end },
    }
    local installed = 0
    local failures = {}
    for _, hook in ipairs(hooks) do
        local ok, reason = install_conditional_hook(self, hook[1], hook[2], hook[3], hook[4])
        if ok then installed = installed + 1 else failures[#failures + 1] = reason end
    end
    self.quest_posting.hook_failures = failures
    return installed == #hooks, table.concat(failures, "; ")
end

function M.quest_restart_api(self)
    local api = {}

    local function is_target_quest_posted()
        local quest = sdk.get_managed_singleton("snow.QuestManager")
        if quest == nil or self.methods.quest_active == nil or self.methods.quest_no == nil then
            return false
        end
        local active = safe(function() return self.methods.quest_active:call(quest) end) == true
        local quest_no = safe(function() return self.methods.quest_no:call(quest) end)
        return active and tonumber(quest_no) == tonumber(self.profile.training_quest.id)
    end

    function api:request_reset()
        if self.runtime.capabilities.quest_posting ~= true then
            return false, "Quest posting hooks unavailable: "
                .. tostring(self.runtime.capabilities.quest_posting_reason)
        end
        M.start_quest_reset_trace(self.runtime, self.runtime.last_context)
        return M.request_native_quest_reset(self.runtime)
    end

    function api:is_hub_ready()
        local gui = sdk.get_managed_singleton("snow.gui.GuiManager")
        local quest = sdk.get_managed_singleton("snow.QuestManager")
        local player = sdk.get_managed_singleton("snow.player.PlayerManager")
        if gui == nil or quest == nil or player == nil then return false end
        local lobby_state = enum_value("snow.player.GameStatePlayer", "Lobby")
        local current_state = safe(function()
            local player_id = player:call("getMasterPlayerID")
            local params = player:call("get_PlayerParam")
            return params[player_id]:get_field("_gameStatePlayer")
        end)
        if lobby_state == nil or current_state ~= lobby_state then return false end
        local can_invoke = safe(function() return gui:call("IsCanInvokeQuestBoard") end) == true
        local active = self.runtime.methods.quest_active
            and safe(function() return self.runtime.methods.quest_active:call(quest) end) == true
        return can_invoke and not active
    end

    function api:open_counter()
        local facility = sdk.get_managed_singleton("snow.LobbyFacilityUIManager")
        local scene_id = enum_value("snow.LobbyFacilityUIManager.SceneId", "QuestCounter")
        if facility == nil or scene_id == nil then return false, "Quest counter API unavailable" end
        self.runtime.quest_posting.active = true
        local ok = pcall(function() facility:call("activateOnly", scene_id) end)
        return ok, ok and nil or "Failed to open quest counter"
    end

    function api:start_session()
        local counter = sdk.get_managed_singleton(
            "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager")
        if counter == nil then return nil end
        local identifier_ok, identifier_error = pcall(function()
            counter:call("setQuestIdentifierQuestNo", self.runtime.profile.training_quest.id)
        end)
        if not identifier_ok then
            return false, "Failed to set training quest identifier: " .. tostring(identifier_error)
        end
        local action = safe(function()
            return sdk.create_instance(
                "snow.gui.fsm.questcounter.GuiQuestCounterFsmCreateQuestSessionAction"):add_ref()
        end)
        if action == nil then return false, "Failed to create quest session Action" end
        local info_ok, info_error = pcall(function() action:setQuestInfoToQuestManager() end)
        if not info_ok then
            safe(function() action:release() end)
            return false, "Failed to copy quest info to QuestManager: " .. tostring(info_error)
        end
        local create_ok, create_error = pcall(function() action:routine_CreateSession() end)
        if not create_ok then
            safe(function() action:release() end)
            return false, "Failed to create native quest session: " .. tostring(create_error)
        end
        self.runtime.quest_posting.action = action
        self.runtime.quest_posting.action_arg = nil
        self.runtime.quest_posting.direct_session = true
        return true
    end

    function api:select_quest()
        if is_target_quest_posted() then return true end
        local gui = sdk.get_managed_singleton("snow.gui.GuiManager")
        if gui == nil then return false, "GuiManager unavailable" end
        if safe(function() return gui:call("isOpenYNInfo") end) == true then return true end
        local selection
        if safe(function() return gui:call("isOpenServantSelectInfoWindow") end) == true then
            selection = safe(function() return gui:call("get_refGuiServantSelectInfoWindow") end)
            local quest = sdk.get_managed_singleton("snow.QuestManager")
            local save = quest and safe(function() return quest:call("get_SaveData") end)
            if save then safe(function() save:set_field("_IsServantSelectCheck", false) end) end
        elseif safe(function() return gui:call("isOpenSelectInfo") end) == true then
            selection = safe(function() return gui:call("get_refGuiCommonSelectWindow") end)
        else
            return nil
        end
        if selection == nil then return false, "Quest confirmation window unavailable" end
        local decided = enum_value("snow.gui.GuiCommonSelectWindow.Result", "Decide")
        local ok, reason = pcall(function()
            local scroll = selection._ScrollListCtrl
            local cursor = scroll._Cursor
            scroll._result = decided
            cursor:set_index(0)
        end)
        return ok and true or false, ok and nil or "Failed to confirm quest: " .. tostring(reason)
    end

    function api:tick_posting()
        local posting = self.runtime.quest_posting
        if posting.direct_session == true then return true end
        local action = posting.action
        if action == nil then return false, "Quest posting action unavailable" end
        local ok, reason = pcall(function()
            local routine = action._RoutineCtrl
            if routine and routine:isExecute() then routine:execute() end
        end)
        return ok, ok and nil or "Quest posting routine failed: " .. tostring(reason)
    end

    function api:update_posting()
        local counter = sdk.get_managed_singleton(
            "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager")
        local success = enum_value("snow.gui.SnowGuiCommonUtility.BaseBranchValue", "SUCCESS")
        local branch_succeeded = counter and success ~= nil
            and safe(function() return counter:call("get_BaseBranchValue") end) == success
        if branch_succeeded or is_target_quest_posted() then
            local gui = sdk.get_managed_singleton("snow.gui.GuiManager")
            local facility = sdk.get_managed_singleton("snow.LobbyFacilityUIManager")
            local scene_id = enum_value("snow.LobbyFacilityUIManager.SceneId", "QuestCounter")
            safe(function() gui:call("set_IsActivateQuestCounterFromQuestBoard", false) end)
            safe(function() facility:call("deactivateOnly", scene_id) end)
            return true
        end
        return nil
    end

    function api:is_counter_closed()
        return sdk.get_managed_singleton(
            "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager") == nil
    end

    function api:depart()
        local quest = sdk.get_managed_singleton("snow.QuestManager")
        local active = quest and self.runtime.methods.quest_active
            and safe(function() return self.runtime.methods.quest_active:call(quest) end) == true
        if not active then return false, "Training quest was not posted" end
        local gui = sdk.get_managed_singleton("snow.gui.GuiManager")
        local flow = gui and safe(function() return gui:call("get_refQuestStartFlowHandler") end)
        if flow == nil then return false, "Quest departure flow unavailable" end
        local ok = pcall(function() flow:call("requestGoQuest", true) end)
        return ok, ok and nil or "Automatic departure failed"
    end

    function api:finish_posting()
        M.flush_quest_reset_trace(self.runtime, self.runtime.last_context, true)
        self.runtime:clear_quest_posting(false)
    end

    function api:cancel_posting()
        M.flush_quest_reset_trace(self.runtime, self.runtime.last_context, true)
        self.runtime:clear_quest_posting(true)
    end

    api.runtime = self
    return api
end

function M.record_quest_restart_state(self, restart, context)
    local message = string.format("[MHRiseMonsterCoach] One-key restart: %s (%s)",
        tostring(restart.state), tostring(restart.status))
    if restart.state == "failed" then log.error(message) else log.info(message) end
    safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_quest_restart_state.json", {
            schema_version = 1,
            version = "0.18.5-fast-one-key-restart",
            state = restart.state,
            status = restart.status,
            error = restart.error,
            state_frames = restart.state_frames,
            hub_stable_frames = restart.hub_stable_frames,
            quest_id = restart.quest_id,
            context = context,
            posting_hooks = self.quest_posting.hooks,
            posting_hook_failures = self.quest_posting.hook_failures,
        })
    end)
end

function M.clear_quest_posting(self, close_windows)
    local posting = self.quest_posting
    posting.active = false
    posting.direct_session = false
    if close_windows then
        local gui = sdk.get_managed_singleton("snow.gui.GuiManager")
        local facility = sdk.get_managed_singleton("snow.LobbyFacilityUIManager")
        local scene_id = enum_value("snow.LobbyFacilityUIManager.SceneId", "QuestCounter")
        safe(function() gui:call("closeYNInfo") end)
        safe(function() gui:call("closeServantSelectInfoWindow") end)
        safe(function() gui:call("closeSelectWindow") end)
        safe(function() gui:call("closeInfo") end)
        safe(function() gui:call("set_IsActivateQuestCounterFromQuestBoard", false) end)
        safe(function() facility:call("deactivateOnly", scene_id) end)
    end
    if posting.action_arg then safe(function() posting.action_arg:release() end) end
    if posting.action then safe(function() posting.action:release() end) end
    posting.action = nil
    posting.action_arg = nil
end

function M.dump_quest_restart_metadata(self)
    local quest_type = safe(function() return sdk.find_type_definition("snow.QuestManager") end)
    if quest_type == nil then return false end
    local keywords = {
        "restart", "reset", "retry", "reload", "return", "retire",
        "abandon", "forfeit", "endquest", "startquest", "loadquest", "orderquest",
    }
    local methods = {}
    for _, method in ipairs(safe(function() return quest_type:get_methods() end) or {}) do
        local name = safe(function() return method:get_name() end)
        local lower = string.lower(tostring(name or ""))
        local matched = false
        for _, keyword in ipairs(keywords) do
            if string.find(lower, keyword, 1, true) then matched = true break end
        end
        if matched then
            local return_type = safe(function() return method:get_return_type() end)
            methods[#methods + 1] = {
                name = name,
                parameter_count = safe(function() return method:get_num_params() end),
                return_type = return_type and safe(function() return return_type:get_full_name() end) or nil,
            }
        end
    end
    table.sort(methods, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_quest_restart_probe.json", {
            schema_version = 1,
            policy = "metadata_only_no_method_invocation",
            runtime = { game_name = self.game_name, tdb_version = self.tdb_version },
            type_name = "snow.QuestManager",
            methods = methods,
        })
        return true
    end) == true
end

local IN_PLACE_RESET_TYPES = {
    "snow.enemy.EnemyManager",
    "snow.enemy.EnemyCharacterBase",
    "snow.player.PlayerManager",
    "snow.player.PlayerBase",
    "snow.QuestManager",
    "snow.stage.StageManager",
    "snow.access.QuestAreaMovePopManager",
    "snow.access.QuestAreaMovePopMarker",
    "snow.access.QuestAreaMovePopMarker.AreaMoveInfo",
    "snow.stage.StageManager.QuestAreaMoveRequest",
    "snow.envCreature.EnvironmentCreatureManager",
    "snow.envCreature.EnvironmentCreatureBase",
    "snow.envCreature.EcPopBehavior",
    "snow.enemy.EnemySetInfo",
    "snow.quest.EnemySetParam",
    "snow.quest.QuestData",
}

local function type_name(type_def)
    return type_def and safe(function() return type_def:get_full_name() end) or nil
end

local ACTION_REQUEST_TYPES = {
    "snow.enemy.em032.Em032_00Character",
    "snow.enemy.em032.Em032CharacterBase",
    "snow.enemy.EnemyCharacterBase",
    "snow.enemy.EnemyActionParam",
    "snow.enemy.EnemyThinkParam",
    "snow.enemy.EnemyThinkBehavior",
    "snow.enemy.EnemyThinkBehavior.ThinkInfoData",
    "snow.enemy.EnemyThinkData",
    "snow.enemy.ThinkState",
    "snow.enemy.ThinkCondition",
    "snow.enemy.EnemyActionTableParam",
    "snow.enemy.EnemyDef.RestartThinkType",
    "snow.enemy.SetupActionData",
    "snow.enemy.SetupActionBaseData",
    "snow.enemy.EnemyActionParamData.ActionInfo",
}

local ACTION_REQUEST_FULL_TYPES = {
    ["snow.enemy.SetupActionData"] = true,
    ["snow.enemy.SetupActionBaseData"] = true,
    ["snow.enemy.EnemyActionParamData.ActionInfo"] = true,
    ["snow.enemy.EnemyThinkParam"] = true,
    ["snow.enemy.EnemyThinkBehavior"] = true,
    ["snow.enemy.EnemyThinkBehavior.ThinkInfoData"] = true,
    ["snow.enemy.EnemyThinkData"] = true,
    ["snow.enemy.ThinkState"] = true,
    ["snow.enemy.ThinkCondition"] = true,
    ["snow.enemy.EnemyActionTableParam"] = true,
    ["snow.enemy.EnemyDef.RestartThinkType"] = true,
}

local ACTION_REQUEST_METHODS = {
    setActionUnique = true,
    setAction = true,
    requestActionSet = true,
    requestNoChangeTargetActionSet = true,
    setActionParam = true,
    setActionThinkParam = true,
    startActionTable = true,
    finishActionTable = true,
    requestRestartThinkFsmInEndAction = true,
    restartThinkFsmCore = true,
    forceResetThink = true,
    CreateSetupActionData = true,
    setProgActionData = true,
}

function M.dump_action_request_metadata(self)
    if self.game_name ~= self.config.supported_game_name
        or self.tdb_version ~= self.config.supported_tdb_version then return false end
    local types = {}
    for _, requested_name in ipairs(ACTION_REQUEST_TYPES) do
        local type_def = safe(function() return sdk.find_type_definition(requested_name) end)
        local entry = { requested_type = requested_name, found = type_def ~= nil, levels = {} }
        local include_all = ACTION_REQUEST_FULL_TYPES[requested_name] == true
        local seen, depth = {}, 0
        while type_def and depth < 10 do
            local current_name = type_name(type_def) or "unknown"
            if seen[current_name] then break end
            seen[current_name] = true
            local level = { type = current_name, methods = {}, fields = {} }
            for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
                local name = safe(function() return method:get_name() end)
                if include_all or ACTION_REQUEST_METHODS[tostring(name)] then
                    local params = {}
                    for _, param_type in ipairs(safe(function() return method:get_param_types() end) or {}) do
                        params[#params + 1] = type_name(param_type) or "unknown"
                    end
                    level.methods[#level.methods + 1] = {
                        name = name,
                        return_type = type_name(safe(function() return method:get_return_type() end)),
                        param_types = params,
                    }
                end
            end
            for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
                local name = safe(function() return field:get_name() end)
                local lower = string.lower(tostring(name or ""))
                if include_all or string.find(lower, "action", 1, true)
                    or string.find(lower, "think", 1, true) then
                    local static_value = nil
                    if safe(function() return field:is_static() end) == true then
                        local candidate = safe(function() return field:get_data(nil) end)
                        if type(candidate) == "number" or type(candidate) == "boolean"
                            or type(candidate) == "string" then static_value = candidate end
                    end
                    level.fields[#level.fields + 1] = {
                        name = name,
                        type = type_name(safe(function() return field:get_type() end)),
                        is_static = safe(function() return field:is_static() end) == true,
                        is_literal = safe(function() return field:is_literal() end) == true,
                        static_value = static_value,
                    }
                end
            end
            table.sort(level.methods, function(a, b) return tostring(a.name) < tostring(b.name) end)
            table.sort(level.fields, function(a, b) return tostring(a.name) < tostring(b.name) end)
            entry.levels[#entry.levels + 1] = level
            type_def = safe(function() return type_def:get_parent_type() end)
            depth = depth + 1
        end
        types[#types + 1] = entry
    end
    return safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_action_request_probe.json", {
            schema_version = 1,
            policy = "metadata_only_no_action_method_invocation",
            runtime = { game_name = self.game_name, tdb_version = self.tdb_version },
            types = types,
        })
        return true
    end) == true
end

local IN_PLACE_RESET_FULL_TYPES = {
    ["snow.enemy.EnemySetInfo"] = true,
    ["snow.quest.EnemySetParam"] = true,
    ["snow.quest.QuestData"] = true,
    ["snow.access.QuestAreaMovePopMarker"] = true,
    ["snow.access.QuestAreaMovePopMarker.AreaMoveInfo"] = true,
    ["snow.stage.StageManager.QuestAreaMoveRequest"] = true,
}

local IN_PLACE_RESET_KEYWORDS = {
    "spawn", "despawn", "respawn", "create", "generate", "instantiate",
    "arrange", "destroy", "delete", "erase", "remove", "reset", "restart",
    "reload", "reentry", "revive", "warp", "teleport", "position",
    "area", "block", "stage", "map", "camp", "safe", "battle",
}

local function matches_reset_keyword(name)
    local lower = string.lower(tostring(name or ""))
    for _, keyword in ipairs(IN_PLACE_RESET_KEYWORDS) do
        if string.find(lower, keyword, 1, true) then return true end
    end
    return false
end

local function mentions_enemy_spawn_contract(type_def)
    local name = string.lower(tostring(type_name(type_def) or ""))
    return string.find(name, "enemysetinfo", 1, true) ~= nil
        or string.find(name, "enemysetparam", 1, true) ~= nil
end

local TITLE_FLOW_TYPES = {
    "snow.gui.fsm.title.GuiTitleFsmManager",
    "snow.gui.fsm.title.GuiTitleFsmManager",
    "snow.gui.fsm.title.GuiTitleMenuFsmManager",
    "snow.gui.fsm.title.GuiTitleMenuFsmManager.TitleMenu",
    "snow.gui.fsm.title.GuiTitleMenuFsmManager.TitleMenuStateType",
    "snow.gui.SnowGuiCommonUtility.MenuListCursor",
    "snow.gui.GuiSaveDataSelectMenu",
    "snow.gui.GuiSaveDataSelectMenu.PnlSlot",
    "snow.gui.GuiSaveDataSelectMenu.CheckDlcRefundRno",
    "snow.gui.fsm.title.GuiTitleFsm_PressAnyButton_Action",
    "snow.gui.fsm.title.GuiTitleFsm_TitleMenu_Action",
    "snow.gui.fsm.title.GuiTitleFsm_LoadDataSelectMenuStart",
    "snow.gui.fsm.title.GuiTitleFsm_LoadDataSelectMenuInit",
    "snow.gui.fsm.title.GuiTitleFsm_LoadDataSelectMenuEnd",
    "snow.gui.fsm.title.GuiTitleFsmToLoadDataSelectMenu",
    "snow.gui.fsm.title.GuiTitleFsmLoadSaveData",
    "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager",
    "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager.QuestCounterTopMenuType",
    "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager.QuestCounterSubMenuType",
    "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager.QuestCounterLevelMenuType",
    "snow.gui.fsm.questcounter.GuiQuestCounterFsmManager.QuestCounterRankMenuType",
    "snow.gui.fsm.questcounter.GuiQuestCounterFsmTopMenuAction",
    "snow.gui.fsm.questcounter.GuiQuestCounterFsmCreateQuestSessionAction",
}

function M.dump_title_flow_metadata(self)
    if self.game_name ~= self.config.supported_game_name
        or self.tdb_version ~= self.config.supported_tdb_version then return false end
    local types = {}
    for _, requested_name in ipairs(TITLE_FLOW_TYPES) do
        local type_def = safe(function() return sdk.find_type_definition(requested_name) end)
        local entry = { requested_type = requested_name, found = type_def ~= nil, fields = {}, methods = {} }
        if type_def then
            for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
                local field_type = safe(function() return field:get_type() end)
                local is_static = safe(function() return field:is_static() end) == true
                local value = is_static and safe(function() return field:get_data(nil) end) or nil
                if type(value) ~= "number" and type(value) ~= "boolean" and type(value) ~= "string" then
                    value = nil
                end
                entry.fields[#entry.fields + 1] = {
                    name = safe(function() return field:get_name() end),
                    type = type_name(field_type),
                    is_static = is_static,
                    is_literal = safe(function() return field:is_literal() end) == true,
                    static_value = value,
                }
            end
            for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
                local params = {}
                for _, param_type in ipairs(safe(function() return method:get_param_types() end) or {}) do
                    params[#params + 1] = type_name(param_type) or "unknown"
                end
                entry.methods[#entry.methods + 1] = {
                    name = safe(function() return method:get_name() end),
                    return_type = type_name(safe(function() return method:get_return_type() end)),
                    param_types = params,
                }
            end
            table.sort(entry.fields, function(a, b) return tostring(a.name) < tostring(b.name) end)
            table.sort(entry.methods, function(a, b) return tostring(a.name) < tostring(b.name) end)
            if requested_name == "snow.gui.fsm.title.GuiTitleFsmManager"
                or requested_name == "snow.gui.fsm.title.GuiTitleMenuFsmManager"
                or requested_name == "snow.gui.fsm.title.GuiTitleFsmToLoadDataSelectMenu"
                or string.find(requested_name, "GuiQuestCounterFsm", 1, true) ~= nil then
                entry.hierarchy = {}
                local current, depth = type_def, 0
                while current and depth < 12 do
                    local level = { type = type_name(current), fields = {}, methods = {} }
                    for _, field in ipairs(safe(function() return current:get_fields() end) or {}) do
                        level.fields[#level.fields + 1] = {
                            name = safe(function() return field:get_name() end),
                            type = type_name(safe(function() return field:get_type() end)),
                        }
                    end
                    for _, method in ipairs(safe(function() return current:get_methods() end) or {}) do
                        local params = {}
                        for _, param_type in ipairs(safe(function() return method:get_param_types() end) or {}) do
                            params[#params + 1] = type_name(param_type) or "unknown"
                        end
                        level.methods[#level.methods + 1] = {
                            name = safe(function() return method:get_name() end),
                            return_type = type_name(safe(function() return method:get_return_type() end)),
                            param_types = params,
                        }
                    end
                    entry.hierarchy[#entry.hierarchy + 1] = level
                    current = safe(function() return current:get_parent_type() end)
                    depth = depth + 1
                end
            end
        end
        types[#types + 1] = entry
    end
    local behavior_instances = {}
    local title = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleFsmManager")
    local list_field = find_field(
        "snow.gui.fsm.GuiFsmBaseManager`1<snow.gui.fsm.title.GuiTitleFsmManager>",
        "guiFsmBehaviorList")
    local behavior_list = title and list_field
        and safe(function() return list_field:get_data(title) end) or nil
    local count = behavior_list and safe(function() return behavior_list:call("get_Count") end) or 0
    for index = 0, math.min(tonumber(count) or 0, 32) - 1 do
        local instance = safe(function() return behavior_list:call("get_Item", index) end)
        local current = instance and safe(function() return instance:get_type_definition() end) or nil
        local entry = { index = index, type = type_name(current), hierarchy = {} }
        local depth = 0
        while current and depth < 10 do
            local level = { type = type_name(current), fields = {}, methods = {} }
            for _, field in ipairs(safe(function() return current:get_fields() end) or {}) do
                level.fields[#level.fields + 1] = {
                    name = safe(function() return field:get_name() end),
                    type = type_name(safe(function() return field:get_type() end)),
                }
            end
            for _, method in ipairs(safe(function() return current:get_methods() end) or {}) do
                local params = {}
                for _, param_type in ipairs(safe(function() return method:get_param_types() end) or {}) do
                    params[#params + 1] = type_name(param_type) or "unknown"
                end
                level.methods[#level.methods + 1] = {
                    name = safe(function() return method:get_name() end),
                    return_type = type_name(safe(function() return method:get_return_type() end)),
                    param_types = params,
                }
            end
            entry.hierarchy[#entry.hierarchy + 1] = level
            current = safe(function() return current:get_parent_type() end)
            depth = depth + 1
        end
        behavior_instances[#behavior_instances + 1] = entry
    end
    return safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_title_flow_probe.json", {
            schema_version = 4,
            policy = "exact_type_metadata_only_no_title_action_invocation",
            runtime = { game_name = self.game_name, tdb_version = self.tdb_version },
            types = types,
            behavior_instances = behavior_instances,
        })
        return true
    end) == true
end

function M.startup_bootstrap_observation(self)
    local title = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleMenuFsmManager")
    local save_menu = sdk.get_managed_singleton("snow.gui.GuiSaveDataSelectMenu")
    local title_state, title_cursor_index, current_save_slot
    if title then
        title_state = safe(function() return title:get_TitleMenuState() end)
        local cursor = safe(function() return title:get_TitleMenuCursor() end)
        if cursor then title_cursor_index = safe(function() return cursor:getIndex() end) end
    end
    if save_menu then
        current_save_slot = safe(function() return save_menu:get_field("_CurrentSlotNo") end)
    end
    local slot_array = save_menu and safe(function() return save_menu:get_field("_SlotArray") end) or nil
    local phase = self.startup_flow and self.startup_flow.phase or nil
    local game_start_fsm = sdk.get_managed_singleton(
        "snow.gui.fsm.title.GuiGameStartFsmManager")
    local game_start_node = game_start_fsm and safe(function()
        return game_start_fsm:getCurrentNodeName()
    end) or nil
    local autosave_notice_active = phase == "autosave_notice"
        or string.find(string.lower(tostring(game_start_node or "")), "autosavecaution", 1, true) ~= nil
    if self.startup_flow.transition_action then
        if phase == "save_menu" then
            safe(function() self.startup_flow.transition_arg:release() end)
            safe(function() self.startup_flow.transition_action:release() end)
            self.startup_flow.transition_arg = nil
            self.startup_flow.transition_action = nil
        else
            local ok, reason = pcall(function()
                self.startup_flow.transition_action:update(self.startup_flow.transition_arg)
            end)
            if not ok then self.startup_flow.transition_error = tostring(reason) end
        end
    end
    if phase == "press_any" then title_state = 1 end
    if phase == "title_menu" then title_state = 2 end
    local quest_api = M.quest_restart_api(self)
    return {
        build_supported = self.game_name == self.config.supported_game_name
            and self.tdb_version == self.config.supported_tdb_version,
        in_hub = quest_api:is_hub_ready() == true,
        title_state = title_state,
        title_cursor_index = title_cursor_index,
        save_menu_available = phase == "save_menu" and save_menu ~= nil and slot_array ~= nil,
        save_menu_active = phase == "save_menu",
        current_save_slot = current_save_slot,
        autosave_notice_active = autosave_notice_active,
        autosave_notice_seen = self.startup_flow.autosave_notice_seen == true,
        game_start_node = game_start_node,
        bootstrap_error = self.startup_flow.transition_error,
    }
end

function M.startup_bootstrap_diagnostics(self)
    local title = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleMenuFsmManager")
    local game_start_fsm = sdk.get_managed_singleton(
        "snow.gui.fsm.title.GuiGameStartFsmManager")
    local game_start_node = game_start_fsm and safe(function()
        return game_start_fsm:getCurrentNodeName()
    end) or nil
    return {
        phase = self.startup_flow and self.startup_flow.phase or nil,
        hooks = self.startup_flow and self.startup_flow.hooks or {},
        hook_failures = self.startup_flow and self.startup_flow.hook_failures or {},
        title_manager_available = title ~= nil,
        title_state = title and safe(function() return title:get_TitleMenuState() end) or nil,
        save_menu_available = sdk.get_managed_singleton("snow.gui.GuiSaveDataSelectMenu") ~= nil,
        reframework_ui_open = safe(function() return reframework:is_drawing_ui() end) == true,
        transition_error = self.startup_flow and self.startup_flow.transition_error or nil,
        autosave_notice_seen = self.startup_flow
            and self.startup_flow.autosave_notice_seen == true or false,
        autosave_notice_active = self.startup_flow
            and self.startup_flow.phase == "autosave_notice" or false,
        game_start_node = game_start_node,
    }
end

function M.select_startup_title_menu(self, index)
    if tonumber(index) ~= 1 then return false, "Only Continue (index 1) is permitted" end
    local title = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleMenuFsmManager")
    if title == nil then return false, "Title menu manager unavailable" end
    local state = safe(function() return title:get_TitleMenuState() end)
    if tonumber(state) ~= 2 then return false, "Title menu is not in the selectable state" end
    local cursor = safe(function() return title:get_TitleMenuCursor() end)
    if cursor == nil then return false, "Title menu cursor unavailable" end
    local ok, reason = pcall(function() cursor:setIndex(1) end)
    if not ok then return false, "Failed to select Continue: " .. tostring(reason) end
    local selected = safe(function() return cursor:getIndex() end)
    if tonumber(selected) ~= 1 then return false, "Continue selection did not persist" end
    return true
end

function M.advance_startup_to_press_any(self)
    local title = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleMenuFsmManager")
    if title == nil then return false, "Title menu manager unavailable" end
    local state = safe(function() return title:get_TitleMenuState() end)
    if tonumber(state) == 1 then return true end
    if tonumber(state) ~= 0 then
        return false, "Title INIT advance refused from state " .. tostring(state)
    end
    local ok, reason = pcall(function() title:setState(1) end)
    if not ok then return false, "Failed to enter PressAnyButton: " .. tostring(reason) end
    local selected = safe(function() return title:get_TitleMenuState() end)
    if tonumber(selected) ~= 1 then return false, "PressAnyButton transition did not persist" end
    return true
end

function M.advance_startup_to_title_menu(self)
    local title = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleMenuFsmManager")
    if title == nil then return false, "Title menu manager unavailable" end
    local state = safe(function() return title:get_TitleMenuState() end)
    if tonumber(state) == 2 then return true end
    if tonumber(state) ~= 1 then
        return false, "Title menu advance refused from state " .. tostring(state)
    end
    local ok, reason = pcall(function() title:setState(2) end)
    if not ok then return false, "Failed to enter TitleMenu: " .. tostring(reason) end
    local selected = safe(function() return title:get_TitleMenuState() end)
    if tonumber(selected) ~= 2 then return false, "TitleMenu transition did not persist" end
    return true
end

function M.dismiss_startup_autosave_notice(self)
    if self.startup_flow.autosave_notice_seen ~= true then
        return false, "Autosave caution action has not been observed"
    end
    local manager = sdk.get_managed_singleton("snow.gui.fsm.title.GuiGameStartFsmManager")
    local success = enum_value("snow.gui.SnowGuiCommonUtility.BaseBranchValue", "SUCCESS")
    if manager == nil or success == nil then
        return false, "Game-start FSM branch API unavailable"
    end
    self.startup_flow.force_autosave_notice_success = true
    return true
end

function M.open_startup_load_data_menu(self)
    local title_menu = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleMenuFsmManager")
    local state = title_menu and safe(function() return title_menu:get_TitleMenuState() end) or nil
    local cursor = title_menu and safe(function() return title_menu:get_TitleMenuCursor() end) or nil
    local index = cursor and safe(function() return cursor:getIndex() end) or nil
    if tonumber(state) ~= 2 or tonumber(index) ~= 1 then
        return false, "Native load transition requires verified Continue selection"
    end
    local title_fsm = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleFsmManager")
    local success = enum_value("snow.gui.SnowGuiCommonUtility.BaseBranchValue", "SUCCESS")
    if title_fsm == nil or success == nil then return false, "Title FSM branch API unavailable" end
    self.startup_flow.transition_error = nil
    self.startup_flow.force_continue = true
    return true
end

function M.select_startup_save_slot(self, index)
    if tonumber(index) ~= 0 then return false, "Only the first save slot (index 0) is permitted" end
    local title = sdk.get_managed_singleton("snow.gui.fsm.title.GuiTitleMenuFsmManager")
    local state = title and safe(function() return title:get_TitleMenuState() end) or nil
    if tonumber(state) == 3 then return false, "Safety stop: New Game state is active" end
    if tonumber(state) == 2 then return false, "Save data menu is not active" end
    local save_menu = sdk.get_managed_singleton("snow.gui.GuiSaveDataSelectMenu")
    if save_menu == nil then return false, "Save data menu unavailable" end
    local ok, reason = pcall(function() save_menu:set_field("_CurrentSlotNo", 0) end)
    if not ok then return false, "Failed to select first save slot: " .. tostring(reason) end
    local selected = safe(function() return save_menu:get_field("_CurrentSlotNo") end)
    if tonumber(selected) ~= 0 then return false, "First save slot selection did not persist" end
    return true
end

function M.dump_in_place_reset_metadata(self)
    if self.game_name ~= self.config.supported_game_name
        or self.tdb_version ~= self.config.supported_tdb_version then return false end
    local types = {}
    for _, requested_name in ipairs(IN_PLACE_RESET_TYPES) do
        local type_def = safe(function() return sdk.find_type_definition(requested_name) end)
        local entry = { requested_type = requested_name, found = type_def ~= nil, levels = {} }
        local include_all = IN_PLACE_RESET_FULL_TYPES[requested_name] == true
        local seen = {}
        while type_def do
            local current_name = type_name(type_def) or "unknown"
            if seen[current_name] then break end
            seen[current_name] = true
            local level = { type = current_name, methods = {}, fields = {} }
            for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
                local name = safe(function() return method:get_name() end)
                local param_types = safe(function() return method:get_param_types() end) or {}
                local return_type = safe(function() return method:get_return_type() end)
                local contract = mentions_enemy_spawn_contract(return_type)
                for _, param_type in ipairs(param_types) do
                    contract = contract or mentions_enemy_spawn_contract(param_type)
                end
                if include_all or matches_reset_keyword(name) or contract then
                    local params = {}
                    for _, param_type in ipairs(param_types) do
                        params[#params + 1] = type_name(param_type) or "unknown"
                    end
                    level.methods[#level.methods + 1] = {
                        name = name,
                        return_type = type_name(return_type),
                        param_types = params,
                    }
                end
            end
            for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
                local name = safe(function() return field:get_name() end)
                local field_type = safe(function() return field:get_type() end)
                if include_all or matches_reset_keyword(name)
                    or mentions_enemy_spawn_contract(field_type) then
                    level.fields[#level.fields + 1] = {
                        name = name,
                        type = type_name(field_type),
                        is_static = safe(function() return field:is_static() end) == true,
                    }
                end
            end
            table.sort(level.methods, function(a, b) return tostring(a.name) < tostring(b.name) end)
            table.sort(level.fields, function(a, b) return tostring(a.name) < tostring(b.name) end)
            entry.levels[#entry.levels + 1] = level
            type_def = safe(function() return type_def:get_parent_type() end)
        end
        types[#types + 1] = entry
    end
    return safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_in_place_reset_probe.json", {
            schema_version = 1,
            policy = "metadata_only_no_candidate_method_invocation",
            runtime = { game_name = self.game_name, tdb_version = self.tdb_version },
            keywords = IN_PLACE_RESET_KEYWORDS,
            types = types,
        })
        return true
    end) == true
end

local IN_PLACE_TYPE_KEYWORDS = {
    "endemic", "creature", "ecology", "ecologic", "environment",
    "envcreature", "fieldgimmick",
}

function M.dump_in_place_type_candidates(self)
    if self.game_name ~= self.config.supported_game_name
        or self.tdb_version ~= self.config.supported_tdb_version then return false end
    local existing = safe(function()
        return json.load_file("MHRiseMonsterCoach/runtime_in_place_type_candidates.json")
    end)
    if type(existing) == "table" and existing.schema_version == 2 then return true end
    local matches = {}
    local seen = {}
    local ok, reason = pcall(function()
        local app_domain_type = sdk.find_type_definition("System.AppDomain")
        local get_current = app_domain_type and app_domain_type:get_method("get_CurrentDomain")
        local domain = get_current and get_current:call(nil)
        local assemblies = domain and domain:call("GetAssemblies")
        if assemblies == nil then error("loaded assemblies unavailable") end
        for assembly_index = 0, assemblies:get_size() - 1 do
            local assembly = assemblies:get_element(assembly_index)
            local types = assembly and safe(function() return assembly:call("GetTypes") end)
            if types then
                for type_index = 0, types:get_size() - 1 do
                    local system_type = types:get_element(type_index)
                    local name = system_type and safe(function()
                        return system_type:call("get_FullName")
                    end)
                    local lower = string.lower(tostring(name or ""))
                    for _, keyword in ipairs(IN_PLACE_TYPE_KEYWORDS) do
                        if string.find(lower, keyword, 1, true) then
                            if not seen[name] then matches[#matches + 1] = name seen[name] = true end
                            break
                        end
                    end
                end
            end
        end
    end)
    table.sort(matches)
    return safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_in_place_type_candidates.json", {
            schema_version = 2,
            policy = "type_names_only_no_instance_access_or_method_invocation",
            error = ok and nil or tostring(reason),
            keywords = IN_PLACE_TYPE_KEYWORDS,
            matches = matches,
        })
        return true
    end) == true
end

function M.get_scene(self)
    local manager = sdk.get_native_singleton("via.SceneManager")
    if manager == nil then return nil end
    return safe(function()
        return sdk.call_native_func(manager, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end)
end

local ENVIRONMENT_STATE_KEYWORDS = {
    "state", "status", "active", "enable", "standby", "access", "get",
    "use", "destroy", "repop", "timer", "visible", "draw", "find", "disable",
}

local function is_environment_state_field(name)
    local lower = string.lower(tostring(name or ""))
    for _, keyword in ipairs(ENVIRONMENT_STATE_KEYWORDS) do
        if string.find(lower, keyword, 1, true) then return true end
    end
    return false
end

local function environment_state_fields(self, type_def)
    local type_key = type_name(type_def) or "unknown"
    if self.environment_creature_field_cache[type_key] then
        return self.environment_creature_field_cache[type_key]
    end
    local result = {}
    local seen = {}
    local current = type_def
    while current do
        local owner = type_name(current) or "unknown"
        for _, field in ipairs(safe(function() return current:get_fields() end) or {}) do
            local name = safe(function() return field:get_name() end)
            local key = owner .. "." .. tostring(name)
            if name and is_environment_state_field(name) and not seen[key]
                and safe(function() return field:is_static() end) ~= true then
                result[#result + 1] = { key = key, field = field }
                seen[key] = true
            end
        end
        current = safe(function() return current:get_parent_type() end)
    end
    self.environment_creature_field_cache[type_key] = result
    return result
end

local function primitive_field_value(field, instance)
    local value = safe(function() return field:get_data(instance) end)
    local value_type = type(value)
    if value_type == "number" or value_type == "boolean" or value_type == "string" then return value end
    local field_type = safe(function() return field:get_type() end)
    if field_type and safe(function() return field_type:is_enum() end) == true then
        return tonumber(value) or tostring(value)
    end
    return nil
end

function M.read_environment_creatures(self)
    local scene = M.get_scene(self)
    local component_type = safe(function() return sdk.typeof("snow.envCreature.EnvironmentCreatureBase") end)
    if scene == nil or component_type == nil then return {}, "Environment creature scene capability unavailable" end
    local components = safe(function()
        return scene:call("findComponents(System.Type)", component_type)
    end)
    local elements = components and safe(function() return components:get_elements() end) or nil
    if type(elements) ~= "table" then return {}, "Environment creature component list unavailable" end
    local entries = {}
    for _, component in ipairs(elements) do
        local type_def = component and safe(function() return component:get_type_definition() end)
        if component and type_def then
            local address = safe(function() return component:get_address() end)
            local values = {}
            for _, candidate in ipairs(environment_state_fields(self, type_def)) do
                local value = primitive_field_value(candidate.field, component)
                if value ~= nil then values[candidate.key] = value end
            end
            local transform = get_transform(component)
            local position = get_position(transform)
            if position then
                values.position_x = tonumber(position.x)
                values.position_y = tonumber(position.y)
                values.position_z = tonumber(position.z)
            end
            entries[#entries + 1] = {
                key = tostring(address or component),
                type_name = type_name(type_def),
                values = values,
            }
        end
    end
    return entries
end

function M.observe_environment_creatures(self)
    local context = self.last_context or {}
    if not context.in_quest or context.is_online
        or tonumber(context.quest_no) ~= self.profile.training_quest.id then return false end
    local entries, reason = M.read_environment_creatures(self)
    if reason then return false, reason end
    local revision = self.environment_creature_recorder:observe(entries, {
        clock = safe(function() return os.clock() end),
        quest_no = context.quest_no,
        area_no = read_area_no(self, self.player),
    })
    if revision <= self.environment_creature_saved_revision then return false end
    local exported = self.environment_creature_recorder:export()
    exported.runtime = { game_name = self.game_name, tdb_version = self.tdb_version }
    local written = safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_environment_creatures.json", exported)
        return true
    end) == true
    if written then self.environment_creature_saved_revision = revision end
    return written
end

function M.environment_creature_evidence(self)
    return self.environment_creature_recorder:export()
end

function M.spawn_owned_environment_probe(self, session_id)
    local context = self.last_context or {}
    if type(session_id) ~= "string" or session_id == "" then
        return false, "Developer probe session identity is required"
    end
    if not context.in_quest or context.is_online
        or tonumber(context.quest_no) ~= self.profile.training_quest.id then
        return false, "Environment probe is limited to the offline training quest"
    end
    if self.player == nil then return false, "Hunter unavailable for environment probe" end
    local manager = sdk.get_managed_singleton("snow.envCreature.EnvironmentCreatureManager")
    if manager == nil then return false, "EnvironmentCreatureManager unavailable" end
    local prefab_list = safe(function() return manager:get_field("_EcPrefabList") end)
    local items = prefab_list and safe(function() return prefab_list:get_field("mItems") end)
    local prefabs = items and safe(function() return items:get_elements() end)
    if type(prefabs) ~= "table" then return false, "Environment creature prefab list unavailable" end

    -- Index 11 is the attack Spiribird in the mature SpiritBirds implementation.
    -- It avoids colliding with that mod's optional rainbow-bird auto spawn (index 15).
    local prefab = prefabs[11]
    if prefab == nil then return false, "Attack Spiribird prefab unavailable" end
    local position = get_position(get_transform(self.player))
    if position == nil then return false, "Hunter position unavailable for environment probe" end
    local instance = safe(function()
        if prefab:call("get_Standby") ~= true then prefab:call("set_Standby", true) end
        return prefab:call("instantiate(via.vec3)", position)
    end)
    if instance == nil or sdk.is_managed_object(instance) ~= true then
        return false, "Environment probe instantiation failed"
    end
    self.dev_probe_session_id = session_id
    self.dev_probe_creature = instance
    local key = tostring(safe(function() return instance:get_address() end) or instance)
    M.observe_environment_creatures(self)
    return true, key
end

function M.set_time_scale(self, scale)
    local application = sdk.get_native_singleton("via.Application")
    local application_type = safe(function() return sdk.find_type_definition("via.Application") end)
    if application == nil or application_type == nil then
        return false, "via.Application unavailable"
    end
    local ok = pcall(function()
        sdk.call_native_func(application, application_type, "set_GlobalSpeed", scale)
    end)
    if ok then self.time_scale_owned = scale ~= 1.0 end
    return ok, ok and nil or "set_GlobalSpeed failed"
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

local function serializable_vector(value, include_w)
    if value == nil then return nil end
    local result = {
        x = safe(function() return value.x end),
        y = safe(function() return value.y end),
        z = safe(function() return value.z end),
    }
    if include_w then result.w = safe(function() return value.w end) end
    return result
end

local function inspect_enemy_set_info_registry(target_address)
    local manager = safe(function() return sdk.get_managed_singleton("snow.enemy.EnemyManager") end)
    if manager == nil then return { available = false } end
    local list = safe(function() return manager:call("getEnemySetInfoList") end)
        or safe(function() return manager:get_field("_EnemySetInfoList") end)
    local count = list and tonumber(safe(function() return list:call("get_Count") end)) or nil
    local matched_index = nil
    local addresses = {}
    for index = 0, math.min((count or 0) - 1, 63) do
        local item = safe(function() return list:call("get_Item", index) end)
        local address = item and safe(function() return item:get_address() end) or nil
        addresses[#addresses + 1] = tostring(address)
        if address ~= nil and address == target_address then matched_index = index end
    end
    return {
        available = list ~= nil,
        manager_address = tostring(safe(function() return manager:get_address() end)),
        list_address = tostring(list and safe(function() return list:get_address() end) or nil),
        count = count,
        target_index = matched_index,
        set_info_addresses = addresses,
    }
end

function M.capture_enemy_spawn_contract(self, enemy)
    if enemy == nil then return false, "Enemy unavailable" end
    local set_info = safe(function() return enemy:call("get_SetInfo") end)
    if set_info == nil then return false, "EnemySetInfo unavailable" end
    local set_info_address = safe(function() return set_info:get_address() end)
    if set_info_address ~= nil and self.enemy_spawn_contract_address == set_info_address then
        return true
    end
    local owner = safe(function() return set_info:call("get_OwnerEnemy") end)
    local owner_address = owner and safe(function() return owner:get_address() end)
    local enemy_address = safe(function() return enemy:get_address() end)
    local param = safe(function() return set_info:call("get_EnemySetParam") end)
    local payload = {
        schema_version = 1,
        policy = "read_only_current_enemy_spawn_contract",
        clock = os.clock(),
        quest_id = self.last_context and self.last_context.quest_no or self.profile.training_quest.id,
        enemy = {
            address = tostring(enemy_address),
            enemy_id = M.read_enemy_id(self, enemy),
        },
        set_info = {
            address = tostring(set_info_address),
            owner_address = tostring(owner_address),
            owner_matches_enemy = enemy_address ~= nil and owner_address == enemy_address,
            em_set_id = safe(function() return set_info:call("get_EmSetId") end),
            em_gen_id = safe(function() return set_info:call("get_EmGenId") end),
            unique_id = safe(function() return set_info:call("get_UniqueId") end),
            set_status = safe(function() return set_info:call("get_SetStatus") end),
            destroy_status = safe(function() return set_info:call("get_DestroyStatus") end),
            repop_num = safe(function() return set_info:call("get_RepopNum") end),
            repop_max = safe(function() return set_info:call("get_RepopMax") end),
        },
        enemy_set_param = param and {
            address = tostring(safe(function() return param:get_address() end)),
            em_type = safe(function() return param:call("get_EmType") end),
            block_no = safe(function() return param:call("get_BlockNo") end),
            sub_type = safe(function() return param:call("get_SubType") end),
            individual_type = safe(function() return param:call("get_IndividualType") end),
            set_position = serializable_vector(safe(function() return param:call("get_SetPos") end), false),
            set_rotation = serializable_vector(safe(function() return param:call("get_SetRot") end), true),
        } or nil,
        registry = inspect_enemy_set_info_registry(set_info_address),
    }
    local written = safe(function()
        json.dump_file("MHRiseMonsterCoach/runtime_enemy_spawn_contract.json", payload)
        self.enemy_spawn_contract_history[#self.enemy_spawn_contract_history + 1] = payload
        while #self.enemy_spawn_contract_history > 16 do
            table.remove(self.enemy_spawn_contract_history, 1)
        end
        json.dump_file("MHRiseMonsterCoach/runtime_enemy_spawn_contract_history.json", {
            schema_version = 1,
            policy = "read_only_enemy_spawn_contract_lifecycle",
            samples = self.enemy_spawn_contract_history,
        })
        return true
    end) == true
    if written then self.enemy_spawn_contract_address = set_info_address end
    return written, written and nil or "Failed to export EnemySetInfo contract"
end

local function same_managed_object(left, right)
    if left == nil or right == nil then return false end
    local left_address = safe(function() return left:get_address() end)
    local right_address = safe(function() return right:get_address() end)
    return left_address ~= nil and left_address == right_address
end

function M.monster_respawn_api(runtime)
    local api = {}

    function api:request_destroy(contract)
        local manager = safe(function() return sdk.get_managed_singleton("snow.enemy.EnemyManager") end)
        if manager == nil or runtime.methods.enemy_destroy == nil
            or runtime.methods.set_info_destroy == nil then
            return false, "Native monster destroy contract unavailable"
        end
        local ok, reason = pcall(function()
            runtime.methods.enemy_destroy:call(manager, contract.enemy)
            runtime.methods.set_info_destroy:call(contract.set_info, 0, 0)
        end)
        if not ok then return false, "Native monster destroy request failed: " .. tostring(reason) end
        clear_enemy(runtime, false)
        return true
    end

    function api:is_enemy_absent(contract)
        local owner = safe(function() return contract.set_info:call("get_OwnerEnemy") end)
        if same_managed_object(owner, contract.enemy) then return false end
        local manager = safe(function() return sdk.get_managed_singleton("snow.enemy.EnemyManager") end)
        if manager == nil or runtime.methods.boss_enemy_count == nil
            or runtime.methods.boss_enemy == nil then return false end
        local count = safe(function() return runtime.methods.boss_enemy_count:call(manager) end)
        if type(count) ~= "number" or count < 0 or count > 8 then return false end
        for index = 0, count - 1 do
            local candidate = safe(function() return runtime.methods.boss_enemy:call(manager, index) end)
            if same_managed_object(candidate, contract.enemy) then return false end
        end
        return true
    end

    function api:request_create(contract)
        return false, "No verified active-quest monster creation entrypoint"
    end

    function api:find_created_enemy(contract, candidate)
        local owner = safe(function() return contract.set_info:call("get_OwnerEnemy") end)
        local resolved = owner or candidate
        if resolved == nil or not M.is_tigrex(runtime, resolved) then return nil end
        local manager = safe(function() return sdk.get_managed_singleton("snow.enemy.EnemyManager") end)
        if manager == nil then return nil end
        local count = safe(function() return runtime.methods.boss_enemy_count:call(manager) end)
        if type(count) ~= "number" or count < 1 or count > 8 then return nil end
        for index = 0, count - 1 do
            local listed = safe(function() return runtime.methods.boss_enemy:call(manager, index) end)
            if same_managed_object(listed, resolved) then return resolved end
        end
        return nil
    end

    return api
end

function M.start_monster_respawn_probe(self)
    local context = self.last_context or {}
    if not context.in_quest or context.is_online
        or tonumber(context.quest_no) ~= self.profile.training_quest.id then
        return false, "Monster respawn probe requires the offline training quest"
    end
    if self.enemy == nil or self.methods.enemy_set_info == nil then
        return false, "Tigrex spawn contract unavailable"
    end
    local set_info = safe(function() return self.methods.enemy_set_info:call(self.enemy) end)
    if set_info == nil then return false, "Tigrex EnemySetInfo unavailable" end
    local enemy_set_param = safe(function() return set_info:call("get_EnemySetParam") end)
    if enemy_set_param == nil then return false, "Tigrex EnemySetParam unavailable" end
    return self.monster_respawn:start({
        enemy = self.enemy,
        set_info = set_info,
        enemy_set_param = enemy_set_param,
        enemy_id = self.enemy_id,
    })
end

function M.update_monster_respawn_probe(self)
    if self.monster_respawn == nil or not self.monster_respawn:is_active() then return false end
    self.monster_respawn:update()
    if self.monster_respawn.state == MonsterRespawn.states.COMPLETE then
        self.enemy = self.monster_respawn.result
        self.enemy_id = M.read_enemy_id(self, self.enemy)
        M.capture_enemy_spawn_contract(self, self.enemy)
    end
    return true
end

function M.monster_respawn_diagnostics(self)
    local respawn = self.monster_respawn
    local contract = respawn and respawn.contract or nil
    local set_info = contract and contract.set_info or nil
    local manager = safe(function() return sdk.get_managed_singleton("snow.enemy.EnemyManager") end)
    local registry = manager and (safe(function() return manager:call("getEnemySetInfoList") end)
        or safe(function() return manager:get_field("_EnemySetInfoList") end)) or nil
    local contains = registry and set_info and safe(function()
        return registry:call("Contains(snow.enemy.EnemySetInfo)", set_info)
    end) or false
    return {
        state = respawn and respawn.state or "unavailable",
        state_frames = respawn and respawn.state_frames or 0,
        set_info_address = set_info and tostring(safe(function() return set_info:get_address() end)) or nil,
        set_status = set_info and safe(function() return set_info:call("get_SetStatus") end) or nil,
        destroy_status = set_info and safe(function() return set_info:call("get_DestroyStatus") end) or nil,
        owner_address = set_info and tostring(safe(function()
            local owner = set_info:call("get_OwnerEnemy")
            return owner and owner:get_address() or nil
        end)) or nil,
        registry_count = registry and safe(function() return registry:call("get_Count") end) or nil,
        registry_contains = contains == true,
        receive_create_enemy = manager and safe(function()
            return manager:get_field("_IsReceiveCreateEnemy")
        end) or nil,
        create_wait_frames = contract and contract.create_wait_frames or nil,
        replacement_created = false,
    }
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

clear_enemy = function(self, clear_anchor)
    self.enemy = nil
    self.enemy_id = nil
    self.enemy_spawn_contract_address = nil
    if clear_anchor then self.enemy_anchor = nil end
end

function M.poll_target_enemy(self, quest_no, is_online)
    if is_online or tonumber(quest_no) ~= self.profile.training_quest.id then
        clear_enemy(self, true)
        return false, "Not in the supported single-player training quest"
    end
    if self.methods.boss_enemy_count == nil or self.methods.boss_enemy == nil then
        clear_enemy(self)
        return false, "EnemyManager boss accessors unavailable"
    end

    local manager = sdk.get_managed_singleton("snow.enemy.EnemyManager")
    if manager == nil then
        clear_enemy(self)
        return false, "EnemyManager unavailable"
    end
    local count = safe(function() return self.methods.boss_enemy_count:call(manager) end)
    if type(count) ~= "number" or count < 0 or count > 8 then
        clear_enemy(self)
        return false, "Invalid boss enemy count"
    end

    for index = 0, count - 1 do
        local enemy = safe(function() return self.methods.boss_enemy:call(manager, index) end)
        if enemy ~= nil and M.is_tigrex(self, enemy) then
            self.enemy = enemy
            self.enemy_id = M.read_enemy_id(self, enemy)
            M.capture_enemy_spawn_contract(self, enemy)
            return true
        end
    end
    clear_enemy(self)
    return false, "Tigrex not available yet"
end

function M.install_quest_list_order_hook(self, quest_ids)
    if self.game_name ~= self.config.supported_game_name
        or self.tdb_version ~= self.config.supported_tdb_version then
        return false, "Quest list ordering disabled for unsupported runtime"
    end

    local make_list = find_method("snow.QuestManager", "makeQuestNoList")
    if make_list == nil then return false, "QuestManager.makeQuestNoList unavailable" end

    local installed, install_error = pcall(function()
        sdk.hook(make_list, function() end, function(retval)
            local managed_list = sdk.to_managed_object(retval)
            if managed_list ~= nil then
                self.pending_quest_list = managed_list
                self.pending_quest_order_ids = quest_ids
                self.pending_quest_order_attempts = 3
                self.pending_quest_order_logged = false
            elseif not self.quest_order_warned then
                self.quest_order_warned = true
                log.warn("[MHRiseMonsterCoach] Quest list return value unavailable")
            end
            return retval
        end)
    end)
    if not installed then
        return false, "Failed to install quest list ordering: " .. tostring(install_error)
    end
    return true
end

function M.flush_quest_list_order(self)
    if self.pending_quest_list == nil or self.pending_quest_order_attempts <= 0 then return end

    local reordered, result = pcall(function()
        local managed_list = self.pending_quest_list
        local adapter = {
            contains = function(_, id)
                return managed_list:call("Contains(System.Int32)", id) == true
            end,
            remove = function(_, id)
                return managed_list:call("Remove(System.Int32)", id) == true
            end,
            add = function(_, id)
                managed_list:call("Add(System.Int32)", id)
            end,
        }
        local moved, order_error = QuestListOrder.move_registered_to_end(adapter, self.pending_quest_order_ids)
        if order_error then error(order_error) end
        return moved
    end)

    self.pending_quest_order_attempts = self.pending_quest_order_attempts - 1
    if reordered and result > 0 and not self.pending_quest_order_logged then
        self.pending_quest_order_logged = true
        log.info("[MHRiseMonsterCoach] Moved training quest block to the end of the custom quest list")
    elseif not reordered and not self.quest_order_warned then
        self.quest_order_warned = true
        log.warn("[MHRiseMonsterCoach] Deferred quest list ordering unavailable: " .. tostring(result))
    end

    if self.pending_quest_order_attempts <= 0 then
        self.pending_quest_list = nil
        self.pending_quest_order_ids = nil
    end
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
    self.player_state_reader:capture(self.player, self.player_data)
    return self.player
end

function M.player_state_probe(self)
    return self.player_state_reader:description()
end

function M.player_combat_state(self)
    return self.player_state_reader.state
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
    local build_supported = self.game_name == self.config.supported_game_name
        and self.tdb_version == self.config.supported_tdb_version
    if in_quest and build_supported and not is_online then
        M.poll_target_enemy(self, quest_no, false)
    else
        clear_enemy(self, true)
    end
    if self.was_in_quest and not in_quest then
        M.restore_time_scale(self)
        clear_enemy(self, true)
        self.player_anchor = nil
        self.dev_probe_creature = nil
        self.dev_probe_session_id = nil
        self.last_player_health = nil
    end
    self.was_in_quest = in_quest
    M.refresh_player(self)
    self.last_context = {
        in_quest = in_quest,
        quest_no = quest_no,
        is_online = is_online,
        target_found = self.enemy ~= nil,
        enemy_id = self.enemy_id,
        reader_ready = self.reader:ready(),
        player_found = self.player ~= nil,
        outcome_tracking = self.config.diagnostic_safe_mode ~= true
            and self.player_data ~= nil and self.fields.player_health ~= nil,
        safe_mode = self.config.diagnostic_safe_mode == true,
        build_supported = build_supported,
        game_name = self.game_name,
        tdb_version = self.tdb_version,
    }
    M.flush_quest_reset_trace(self, self.last_context, false)
    return self.last_context
end

function M.read_action(self)
    if self.enemy == nil then return nil end
    return self.reader:read(self.enemy)
end

function M.behavior_tree_snapshot(self)
    return BehaviorTreeReader.read(self.enemy)
end

function M.think_context_snapshot(self, include_catalog)
    return ThinkContextReader.read(self.enemy, include_catalog == true)
end

local FORCED_ACTION_PROBE_ALLOWLIST = {
    [15] = true, [16] = true, [18] = true,
    [19] = true, [20] = true, [21] = true, [22] = true, [23] = true,
    [26] = true, [29] = true, [5000] = true, [5004] = true, [5005] = true,
}

function M.current_action_snapshot(self)
    local description = self.reader:description() or {}
    return {
        action = tonumber(description.action_no),
        category = tonumber(description.action_category),
        motion_name = description.motion_name,
    }
end

local function issue_forced_action(self, action_no, request_tag)
    action_no = tonumber(action_no)
    local context = self.last_context or {}
    if not context.in_quest or context.is_online or context.build_supported == false
        or tonumber(context.quest_no) ~= tonumber(self.profile.training_quest.id)
        or not context.target_found then
        return false, "Forced action requires the supported offline training quest"
    end
    if self.enemy == nil or self.methods.enemy_request_no_change_action == nil then
        return false, "native action request target is unavailable"
    end
    local hitboxes = self.hitbox_provider:poll(self.enemy)
    if hitboxes and hitboxes.active then
        return false, "Waiting for active monster hitboxes to close", true
    end
    self.action_request_trace.request_tag = request_tag
    local payload = safe(function()
        return sdk.create_instance("snow.enemy.SetupActionData"):add_ref()
    end)
    if payload == nil then
        self.action_request_trace.request_tag = nil
        return false, "Failed to create SetupActionData"
    end
    local ok, reason = pcall(function()
        payload:call(".ctor(snow.enemy.EnemyDef.EmActCategory, System.UInt16)", 4, action_no)
        self.methods.enemy_request_no_change_action:call(self.enemy, payload)
    end)
    safe(function() payload:release() end)
    self.action_request_trace.request_tag = nil
    if not ok then return false, tostring(reason) end
    return true
end

function M.request_forced_action_probe(self, action_no)
    action_no = tonumber(action_no)
    if not FORCED_ACTION_PROBE_ALLOWLIST[action_no] then
        return false, "Action is outside the forced-probe allowlist"
    end
    return issue_forced_action(self, action_no, "forced_probe")
end

function M.request_training_scenario(self, scenario)
    if self.config.forced_action_training_enabled ~= true then
        return false, "Enable specified-move training in the Monster Coach menu first"
    end
    if type(scenario) ~= "table" or type(scenario.actions) ~= "table"
        or #scenario.actions ~= 1 or type(scenario.verification) ~= "table"
        or scenario.verification.status ~= "verified" then
        return false, "Training scenario is not a verified single-action contract"
    end
    local areas = M.area_snapshot(self)
    if areas.combat_layer ~= true then
        return false, "Enter the monster area before starting specified-move training"
    end
    return issue_forced_action(self, scenario.actions[1], "training_scenario")
end

function M.read_hitboxes(self)
    return self.hitbox_provider:poll(self.enemy)
end

function M.hitbox_provider_description(self)
    return self.hitbox_provider:description()
end

function M.set_hitboxviewer_debug_shapes(self, enabled)
    return self.hitbox_provider:set_debug_shapes(enabled)
end

function M.shutdown(self)
    M.restore_time_scale(self)
    if self.quest_restart then self.quest_restart:shutdown() end
    self.reader:shutdown()
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

get_transform = function(component)
    if component == nil then return nil end
    return safe(function()
        local game_object = component:call("get_GameObject")
        return game_object and game_object:call("get_Transform") or nil
    end)
end

get_position = function(transform)
    return transform and safe(function() return transform:call("get_Position") end) or nil
end

local function get_rotation(transform)
    return transform and safe(function() return transform:call("get_Rotation") end) or nil
end

local function copy_position(value)
    if value == nil then return nil end
    return safe(function() return Vector3f.new(value.x, value.y, value.z) end)
end

local function copy_rotation(value)
    if value == nil then return nil end
    return safe(function() return Quaternion.new(value.w, value.x, value.y, value.z) end)
end

read_area_no = function(self, character)
    if character == nil or self.methods.character_area_no == nil then return nil end
    local value = safe(function() return self.methods.character_area_no:call(character) end)
    local numeric = tonumber(value)
    if numeric ~= nil then return numeric end
    return safe(function() return tonumber(value:get_field("value__")) end)
end

function M.area_snapshot(self)
    local player_area = read_area_no(self, self.player)
    local enemy_area = read_area_no(self, self.enemy)
    local player_position = get_position(get_transform(self.player))
    local enemy_position = get_position(get_transform(self.enemy))
    local player_enemy_vertical_gap = nil
    if player_position ~= nil and enemy_position ~= nil then
        local player_y = tonumber(player_position.y)
        local enemy_y = tonumber(enemy_position.y)
        if player_y ~= nil and enemy_y ~= nil then
            player_enemy_vertical_gap = math.abs(player_y - enemy_y)
        end
    end
    local scene = M.get_scene(self)
    local markers = {}
    local marker_candidates = {}
    local nearest_marker = nil
    local nearest_distance_sq = nil
    local seen_markers = {}
    local marker_type_names = {
        "snow.access.QuestAreaMovePopMarker",
        "snow.access.ObjectPopMarker",
    }
    for _, marker_type_name in ipairs(marker_type_names) do
        local marker_type = safe(function() return sdk.typeof(marker_type_name) end)
        local marker_components = scene and marker_type and safe(function()
            return scene:call("findComponents(System.Type)", marker_type)
        end) or nil
        local marker_elements = marker_components and safe(function()
            return marker_components:get_elements()
        end) or nil
        for _, marker in ipairs(type(marker_elements) == "table" and marker_elements or {}) do
            local address = tostring(safe(function() return marker:get_address() end) or marker)
            if not seen_markers[address] then
                seen_markers[address] = true
                local runtime_type = safe(function()
                    return marker:get_type_definition():get_full_name()
                end) or marker_type_name
                local position = get_position(get_transform(marker))
                marker_candidates[#marker_candidates + 1] = {
                    key = address,
                    type_name = runtime_type,
                    position = serializable_vector(position, false),
                }
                if string.find(tostring(runtime_type), "QuestAreaMovePopMarker", 1, true)
                    and position ~= nil then
                    local dx = player_position and tonumber(position.x) - tonumber(player_position.x) or nil
                    local dz = player_position and tonumber(position.z) - tonumber(player_position.z) or nil
                    local distance_sq = dx and dz and (dx * dx + dz * dz) or nil
                    local entry = {
                        key = address,
                        type_name = runtime_type,
                        position = serializable_vector(position, false),
                        distance = distance_sq and math.sqrt(distance_sq) or nil,
                        accessible = safe(function() return marker:call("get_IsAccessible") end) == true,
                    }
                    markers[#markers + 1] = entry
                    self.arena_transfer_marker_cache[entry.key] = {
                        key = entry.key,
                        position = entry.position,
                        accessible = entry.accessible,
                        cached = true,
                    }
                    if distance_sq ~= nil
                        and (nearest_distance_sq == nil or distance_sq < nearest_distance_sq) then
                        nearest_marker = entry
                        nearest_distance_sq = distance_sq
                    end
                end
            end
        end
    end
    if #markers == 0 then
        for _, entry in pairs(self.arena_transfer_marker_cache) do
            local dx = player_position and tonumber(entry.position.x) - tonumber(player_position.x) or nil
            local dz = player_position and tonumber(entry.position.z) - tonumber(player_position.z) or nil
            local distance_sq = dx and dz and (dx * dx + dz * dz) or nil
            markers[#markers + 1] = {
                key = entry.key,
                position = entry.position,
                distance = distance_sq and math.sqrt(distance_sq) or nil,
                accessible = false,
                cached = true,
            }
        end
    end
    nearest_marker = nil
    nearest_distance_sq = nil
    for _, entry in ipairs(markers) do
        local distance = tonumber(entry.distance)
        local distance_sq = distance and distance * distance or nil
        if distance_sq ~= nil and (nearest_distance_sq == nil or distance_sq < nearest_distance_sq) then
            nearest_marker = entry
            nearest_distance_sq = distance_sq
        end
    end
    table.sort(markers, function(a, b)
        return tonumber(a.distance or math.huge) < tonumber(b.distance or math.huge)
    end)

    local camera_forward, camera_right = nil, nil
    local camera = safe(function() return sdk.get_primary_camera() end)
    local camera_matrix = camera and safe(function() return camera:get_WorldMatrix() end) or nil
    local camera_rotation = camera_matrix and safe(function() return camera_matrix:to_quat() end) or nil
    if camera_rotation then
        camera_forward = safe(function()
            return camera_rotation * Vector3f.new(0, 0, -1)
        end)
        camera_right = safe(function()
            return camera_rotation * Vector3f.new(1, 0, 0)
        end)
    end

    return {
        player = player_area,
        enemy = enemy_area,
        same_area = player_area ~= nil and enemy_area ~= nil and player_area == enemy_area,
        -- Area numbers are not reliable in the Forlorn Arena: the live battle
        -- state has reported player 0/1 while Tigrex remains -1.  Both actors
        -- occupying the same vertical scene layer is the stable transfer signal.
        combat_layer = player_enemy_vertical_gap ~= nil and player_enemy_vertical_gap <= 50.0,
        player_enemy_vertical_gap = player_enemy_vertical_gap,
        player_position = serializable_vector(player_position, false),
        enemy_position = serializable_vector(enemy_position, false),
        arena_transfer_ready = self.arena_transfer_focus ~= nil
            and self.arena_transfer_focus.marker ~= nil
            and safe(function() return self.arena_transfer_focus.marker:call("get_IsAccessible") end) == true,
        arena_navigation = {
            markers = markers,
            marker_candidates = marker_candidates,
            target = nearest_marker,
            camera_forward = serializable_vector(camera_forward, false),
            camera_right = serializable_vector(camera_right, false),
            focus_sequence = self.arena_transfer_focus_sequence,
            access_count = self.arena_transfer_access_count,
        },
    }
end

function M.request_arena_transfer(self)
    return false, "Automatic arena transfer disabled pending verified request initialization"
end

function M.capture_anchors(self)
    if self.player == nil or self.enemy == nil then return false, "Player or Tigrex unavailable" end
    local player_transform = get_transform(self.player)
    local enemy_transform = get_transform(self.enemy)
    local player_position = get_position(player_transform)
    local enemy_position = get_position(enemy_transform)
    if player_position == nil or enemy_position == nil then return false, "Transform position unavailable" end
    self.player_anchor = {
        position = copy_position(player_position),
        rotation = copy_rotation(get_rotation(player_transform)),
        quest_no = self.last_context and self.last_context.quest_no or nil,
        area_no = read_area_no(self, self.player),
    }
    self.enemy_anchor = {
        position = copy_position(enemy_position),
        rotation = copy_rotation(get_rotation(enemy_transform)),
    }
    if self.player_anchor.position == nil or self.enemy_anchor.position == nil then
        self.player_anchor = nil
        self.enemy_anchor = nil
        return false, "Failed to copy reset anchor values"
    end
    return true
end

function M.anchors_ready(self)
    return self.player_anchor ~= nil and self.enemy_anchor ~= nil
end

local function restore_anchor(component, anchor, label)
    if component == nil or anchor == nil then return false, label .. " anchor unavailable" end
    local transform = get_transform(component)
    if transform == nil or get_position(transform) == nil then return false, label .. " transform unavailable" end
    local ok = pcall(function()
        transform:call("set_Position", anchor.position)
        if anchor.rotation then transform:call("set_Rotation", anchor.rotation) end
    end)
    return ok, ok and nil or (label .. " position reset failed")
end

function M.restore_player_anchor(self)
    return restore_anchor(self.player, self.player_anchor, "Player")
end

function M.restore_enemy_anchor(self)
    return restore_anchor(self.enemy, self.enemy_anchor, "Tigrex")
end

function M.restore_anchors(self)
    local player_ok, player_error = M.restore_player_anchor(self)
    if not player_ok then return false, player_error end
    return M.restore_enemy_anchor(self)
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

function M.experimental_native_in_place_reset(self)
    if not NATIVE_IN_PLACE_RESET_VALIDATED then
        return false, "Disabled after repeated native engine crashes; use F7 quest restart"
    end
    local context = self.last_context or {}
    if self.config.experimental_in_place_reset_enabled ~= true then
        return false, "Experimental in-place reset is disabled"
    end
    if self.game_name ~= self.config.supported_game_name
        or self.tdb_version ~= self.config.supported_tdb_version then
        return false, "Unsupported runtime"
    end
    if not context.in_quest or context.is_online
        or tonumber(context.quest_no) ~= self.profile.training_quest.id then
        return false, "In-place reset is limited to the single-player training quest"
    end
    if self.player == nil or self.enemy == nil or self.player_anchor == nil then
        return false, "Press F8 at the desired hunter reset position first"
    end
    if self.methods.player_native_warp == nil or self.methods.enemy_native_warp_init == nil then
        return false, "Native character warp methods unavailable"
    end
    local current_area_no = read_area_no(self, self.player)
    if self.player_anchor.area_no == nil or current_area_no == nil then
        return false, "Area identity unavailable; press F8 again in the current area"
    end
    if current_area_no ~= self.player_anchor.area_no then
        return false, string.format(
            "Reset point belongs to area %s; current area is %s. Cross-area native reconstruction is not enabled yet",
            tostring(self.player_anchor.area_no), tostring(current_area_no))
    end
    local safe_now, safe_reason, retry = M.quick_reset_safe(self)
    if not safe_now then return false, safe_reason, retry end

    M.restore_time_scale(self)
    local player_ok = pcall(function()
        self.methods.player_native_warp:call(self.player, self.player_anchor.position)
    end)
    if not player_ok then return false, "Native hunter warp failed" end

    local resources_ok, resources_reason = M.restore_player_resources(self)
    if not resources_ok then return false, resources_reason end

    local enemy_ok = pcall(function() self.methods.enemy_native_warp_init:call(self.enemy) end)
    if not enemy_ok then return false, "Native Tigrex initial-position warp failed" end

    local health_ok, health_reason = M.restore_monster_health(self)
    if not health_ok then return false, health_reason end
    return true
end

function M.quick_reset_safe(self)
    local hitboxes = self.hitbox_provider:poll(self.enemy)
    if hitboxes and hitboxes.active then
        return false, "Waiting for active monster hitboxes to close", true
    end
    return true
end

function M.quick_reset_step(self, stage)
    if stage == 1 then return M.restore_time_scale(self) end
    if stage == 2 then return M.restore_player_resources(self) end
    if stage == 3 then return M.restore_player_anchor(self) end
    if stage == 4 then return M.restore_monster_health(self) end
    if stage == 5 then return M.restore_enemy_anchor(self) end
    return false, "Unknown quick reset stage"
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
