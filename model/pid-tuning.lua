local C = require "constants"

local PidTuning = {}
local function log(m)
    localised_print("[TUNING]: " .. m)
end

PidTuning.state = {
    none = "none",
    rising = "rising",
    falling = "falling",
    done  = "done",
    aborted = "aborted",
}

local defaults = {
    target_cycles = 5,
    settle_cycles = 1,
    max_ticks = 60 * C.ticks_per_second,
    rule = C.pid.rules[1],
    output_min = -60,
    output_max = 60,
    headroom = 0,
}

function PidTuning.new(opts)
    opts = opts or {}
    local output_min = opts.output_min or defaults.output_min
    local output_max = opts.output_max or defaults.output_max
    local headroom = opts.headroom or defaults.headroom
    local mid = (output_min + output_max) / 2
    local half = (output_max - output_min) / 2
    local target = opts.target or 0
    local initial_d = opts.initial_d or half
    if initial_d > half then initial_d = half end
    return {
        state = PidTuning.state.none,
        target = target,
        target_cycles = opts.target_cycles or defaults.target_cycles,
        settle_cycles = opts.settle_cycles or defaults.settle_cycles,
        start_tick = 0,
        max_ticks = opts.max_ticks or defaults.max_ticks,
        rule = opts.rule or defaults.rule,
        output_min = output_min,
        output_max = output_max,
        headroom = headroom,
        cycles = 0,
        bias = mid,
        d = initial_d,
        d_cap = initial_d,
        t_high = 0,
        t_low = 0,
        t1 = 0,
        t2 = 0,
        max_pv = C.pid.output_min,
        min_pv = C.pid.output_max,
        result = { kp = 0, ki = 0, kd = 0, },
    }
end

function PidTuning.loop(session, pv, tick)
    if session.state == PidTuning.state.done then return 0 end
    if session.state == PidTuning.state.none then
        session.state = PidTuning.state.rising
        log("Starting")
        session.start_tick = tick
        session.t1 = tick
        session.t2 = tick
        return session.bias + session.d
    end

    if tick > session.start_tick + session.max_ticks then
        log("Aborted")
        session.state = PidTuning.state.aborted
        return 0
    end
    session.max_pv = math.max(session.max_pv, pv)
    session.min_pv = math.min(session.min_pv, pv)

    if session.state == PidTuning.state.rising then
        if pv > session.target then
            session.state = PidTuning.state.falling
            session.t1 = tick
            session.t_high = session.t1 - session.t2
            session.max_pv = session.target
            log("Down")
            return session.bias - session.d
        end
        return session.bias + session.d
    end

    if session.state == PidTuning.state.falling then
        if pv < session.target then
            session.state = PidTuning.state.rising
            session.t2 = tick
            session.t_low = session.t2 - session.t1

            if session.cycles > 0 then
                local total_t = session.t_high + session.t_low
                -- Finalising
                if session.cycles >= (session.settle_cycles + session.target_cycles) then
                    log("Done")
                    local amplitude = session.max_pv - session.min_pv
                    local ku = (4 * session.d) / (math.pi * amplitude * 0.5)
                    local tu = total_t / C.ticks_per_second

                    local ti = session.rule.nf * tu
                    local td = session.rule.df * tu

                    local kp = session.rule.pf * ku
                    local ki = kp / ti
                    local kd = kp * td

                    session.result = { kp = kp, ki = ki, kd = kd, }
                    session.state = PidTuning.state.done
                    return 0
                end
                -- Bias adjustment
                if total_t > 0 then
                    local delta_t = session.t_high - session.t_low
                    session.bias = session.bias + session.d * delta_t / total_t
                    local low = session.output_min + session.headroom
                    local high = session.output_max - session.headroom
                    if session.bias < low then session.bias = low end
                    if session.bias > high then session.bias = high end
                    session.d = math.min(session.d_cap,
                                         session.output_max - session.bias,
                                         session.bias - session.output_min)
                end
            end
            session.min_pv = session.target
            session.cycles = session.cycles + 1
            log("Up " .. session.cycles)
            return session.bias + session.d
        end
        return session.bias - session.d
    end
end

function PidTuning.is_running(session)
    return session and session.state ~= PidTuning.state.done and session.state ~= PidTuning.state.aborted
end

function PidTuning.is_done(session)
    return session and session.state == PidTuning.state.done
end

return PidTuning
