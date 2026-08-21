package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path
local MonsterRespawn = require("MHRiseMonsterCoach.monster_respawn")

local calls, absent, created = {}, false, nil
local api = {}
function api:request_destroy(contract)
    calls[#calls + 1] = "destroy:" .. contract.id
    return true
end
function api:is_enemy_absent() return absent end
function api:request_create(contract)
    calls[#calls + 1] = "create:" .. contract.id
    created = { id = "new-tigrex" }
    return true, created
end
function api:find_created_enemy(_, candidate) return candidate end

local respawn = MonsterRespawn.new(api, { stable_frames = 2, timeout_frames = 20 })
local contract = { id = "tigrex", enemy = {}, set_info = {} }
assert(respawn:start(contract) == true, "verified contract starts the lifecycle")
respawn:update()
assert(respawn.state == "wait_absent", "destroy is requested once")
respawn:update()
assert(respawn.state == "wait_absent", "creation waits while the old enemy remains")
absent = true
respawn:update()
respawn:update()
assert(respawn.state == "request_create", "absence must remain stable before creation")
respawn:update()
assert(respawn.state == "wait_present", "create is requested once")
respawn:update()
respawn:update()
assert(respawn.state == "complete" and respawn.result == created,
    "new enemy must remain discoverable before completion")
assert(table.concat(calls, ",") == "destroy:tigrex,create:tigrex",
    "lifecycle never repeats a destructive request")

local invalid = MonsterRespawn.new(api)
assert(invalid:start({}) == false, "missing runtime handles are rejected")

local timeout_api = {}
function timeout_api:request_destroy() return true end
function timeout_api:is_enemy_absent() return false end
function timeout_api:request_create() error("must not create before absence") end
function timeout_api:find_created_enemy() return nil end
local timed = MonsterRespawn.new(timeout_api, { timeout_frames = 2 })
assert(timed:start(contract))
timed:update()
timed:update()
timed:update()
timed:update()
assert(timed.state == "failed" and timed.error == "timeout in wait_absent",
    "a stuck native lifecycle fails closed")

print("test_monster_respawn.lua: PASS")
