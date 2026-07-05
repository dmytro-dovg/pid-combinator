![Icon](thumbnail.png)

# PID Combinator

A combinator that runs a PID controller - the standard feedback algorithm for holding a value at a target level.

The most obvious use in Factorio is to control space platform's speed.

[Example blueprint](examples/example-blueprint-1)

## Quickstart

Follow these steps to wire up a space platform to fly at a set speed. You don't need to control the flow of both ![thruster-fuel](docs/thruster-fuel_16.png)fuel and ![thruster-oxidizer](docs/thruster-oxidizer_16.png)oxidizer - just pick either one. It doesn't matter which.

1. Craft and place the PID combinator.
2. Wire the space platform hub to the **input** side of the combinator.
   a. In the hub's GUI, check `Read speed`. This is your process variable ![signal-V](docs/signal_V_16.png).
3. Wire the **setpoint** source to the input side too, on a *different* signal. A constant combinator with ![signal-S](docs/signal_S_16.png) **= 100** works fine.
4. Wire PID combinator's **output** side to a pump.
   a. In the pump's GUI, check `Enable if` and set the condition to ![signal-check](docs/signal-checked-green_16.png) **> 0**.
5. Open the combinator's GUI. On the **Variables** tab, make sure your process, setpoint and output signals match.
6. On the **Tuning** tab, start with `Kp = 1, Ki = 0, Kd = 0` and iterate.

## Pulse-width modulation

Quickstart setup gets the platform traveling at roughly the setpoint speed, but the speed will fluctuate because control over the pump is binary. Any positive output signal from the combinator, however small, makes the pump transfer fuel at its full rate of 1200/s. Because the thruster has a significant buffer, it has to burn through that entire amount before the speed can stabilise.

This is where PWM (pulse-width modulation) comes in. It lets us control the pump proportionally to the PID combinator's output. The pump's throughput doesn't change, but it's switched on and off in controlled bursts to limit how much fuel it transfers.

1. Craft and place a decider combinator. This will be our clock.
   a. Short circuit the combinator by connecting the **output** to its **input** with a single wire.
   b. Set the following condition ![signal-clock](docs/signal-clock_16.png) **< 60**; set output to ![signal-clock](docs/signal-clock_16.png) **Input count**.
   c. Wire a constant combinator to the decider's **input** with ![signal-clock](docs/signal-clock_16.png) **= 1**. Once done, you will see that the decider combinator will cycle from 0 to 59 every second.
2. Connect the output of the "clock" combinator to the pump we built earlier.
   a. Change `Enable if` condition to ![signal-check](docs/signal-checked-green_16.png) **>** ![signal-clock](docs/signal-clock_16.png).

## Further improvements

PWM setup gets us mostly there, but we can still improve the responsiveness of the system by adding a second pump, which will empty the thruster's internal buffer when the PID combinator's output is negative. For this we need two extra pumps and a storage tank.

Build a fuel supply system according to the following schematic:
```
[fuel source]┈[pump "input"]>┈[storage tank]┈┬┈┈[pump "in"]>┈┬┈[thruster]
                                             ┊               ┊
                                             └┄<[pump "out"]┄┘
```
The **out** pump needs to activate when the control signal is negative, but our clock is positive and we cannot directly compare the two. In order to make this work we need to invert either ![signal-clock](docs/signal-clock_16.png) or ![signal-check](docs/signal-checked-green_16.png). For this example let's invert ![signal-check](docs/signal-checked-green_16.png).

1. Wire **input** pump to the **storage tank**.
   a. In the pump's GUI, check `Enable if` and set the condition to ![thruster-fuel](docs/thruster-fuel_16.png) **< 1000**. The number is arbitrary.
2. Build an additional arithmetic combinator.
   a. Set it to the following operation: ![signal-check](docs/signal-checked-green_16.png) **\* -1**.
   b. Connect its **input** to PID combinator's **output**, and its **output** to the **out** pump.
   c. In the **out** pump's GUI, check `Enable if` and set the condition to ![signal-check](docs/signal-checked-green_16.png) **>** ![signal-clock](docs/signal-clock_16.png).

## Tuning tips

Tune with the combinator's GUI open and pinned. The green line on the graph is the current speed, the light blue line is the setpoint. What you want to see after changing the setpoint is the green line rising to meet the blue line, without wild swings, within roughly 30 seconds.

A space platform is a slow system: fuel already in the thruster's buffer takes a bit of time to burn off, so every gain change you make takes a while to show up. Be patient - wait 10-20 seconds between tweaks and watch the graph.

1. **Kp first**, with Ki = 0 and Kd = 0. Set the setpoint well away from the current speed (e.g. current 0, target 100) and let the platform accelerate.
   - Speed climbs smoothly and *nearly* reaches the setpoint but rests a few units short: Kp is roughly right - move on to Ki.
   - Speed overshoots the setpoint and oscillates around it: Kp is too high. Halve it.
   - Speed climbs painfully slowly: Kp is too low. Double it.

2. **Ki next**, to close the steady-state gap. Start at Ki = 0.05 and raise slowly.
   - The speed should drift onto the setpoint over 10-30 seconds and stay there.
   - Speed overshoots after a setpoint change and takes a long time to come back: either Ki is too aggressive or the integral has wound up. Halve Ki, or lower the **Integral clamp** on the tuning tab. Because the PWM output saturates around 60, a much larger clamp just means the integral takes forever to unwind after a disturbance.

3. **Kd, if the speed keeps swinging.** Kd reacts to the rate of change of error, so it damps overshoots and smooths transitions between setpoints. Add it last - start at Kd = 0.1 and raise until residual oscillation flattens out. Because platform speed is reported as an integer it wobbles by +/-1 tick to tick, and Kd amplifies that jitter straight into the pump duty, so keep it modest and stop as soon as the swing is gone.
