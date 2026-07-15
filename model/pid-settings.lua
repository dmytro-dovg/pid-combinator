local PidSettings = {}

function PidSettings.defaults()
    return {
        -- PID gains
        kp = 1.0,
        ki = 0.0,
        kd = 0.0,
        -- anti-windup
        anti_windup_limit = 60,
        signals = {
            pv = { name = "signal-V", type = "virtual" },
            sp = { name = "signal-S", type = "virtual" },
            output = { name = "signal-check", type = "virtual" },
        },
        networks = {
            pv = { red = true, green = true, },
            sp = { red = true, green = true, },
            output = { red = true, green = true, },
        },
    }
end

local function copy_signal(signal)
    if not signal then return nil end
    return { name = signal.name, type = signal.type }
end

function PidSettings.copy(source, destination)
    destination.kp = source.kp
    destination.ki = source.ki
    destination.kd = source.kd

    destination.anti_windup_limit = source.anti_windup_limit

    destination.signals = {
        pv = copy_signal(source.signals.pv),
        sp = copy_signal(source.signals.sp),
        output = copy_signal(source.signals.output),
    }

    destination.networks = {
        pv = { red = source.networks.pv.red, green = source.networks.pv.green },
        sp  = { red = source.networks.sp.red, green = source.networks.sp.green },
        output = { red = source.networks.output.red, green = source.networks.output.green },
    }

    destination.last_value = nil
end

return PidSettings
