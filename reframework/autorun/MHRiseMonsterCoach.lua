local ok, app_or_error = pcall(require, "MHRiseMonsterCoach.app")

if not ok then
    log.error("[MHRiseMonsterCoach] startup failed: " .. tostring(app_or_error))
    return
end

app_or_error.start()
