# Hardware test 3: the leftovers (~15 minutes)

Install the new build (⌘R). Plug in the remote and power it on. Use **Mark step N** before each step.

## Update rate check (DUML tab)

1. Poll sticks on, **Fixed rate, 100 Hz** (now the default). Waggle both sticks quickly for 10 s. Note **Fresh values** and **Median time between new values** (expect ~16-20 ms).

## Customizable button

2. Hold the **Customizable** button down and keep holding it. With it held, use **Custom DUML frame** (Receiver `06`, Cmd type `40`, Cmd set `06`) to send each of these Cmd ids in turn: `4c`, `2e`, `50`. Then release the button.
3. Send the same three again with the button **not** held. (I'll compare the replies' payloads in the log. The reply lines under the requests show whether each one answered.)
4. Optional, if you have the aircraft: power it on, wait for the remote to link, then press Customizable twice (hold ~1 s each). Note whether the gimbal moves or the probe shows anything new.

## Idle alert

5. Poll sticks **off**. Leave the remote connected with the probe open and the phone awake, hands off, for **5 minutes**. Does the remote beep or switch itself off? (The manual says it does that when no aircraft or DJI Fly is connected.)

## DJI Fly interplay

6. Unplug the remote. Open **DJI Fly**, plug the remote in, let DJI Fly see it. Switch to the probe **without** closing DJI Fly. Do the sessions open, or say "EASession init returned nil"?
7. Force-quit DJI Fly. In the probe's Overview tap **Open** on the protocol if it isn't open. Does it work now?
8. Unplug and replug with DJI Fly installed but not running. Does iOS offer to open DJI Fly, or does the probe keep the remote?

Then **Copy report** + **Share log file** as before, plus what you heard from the remote in step 5.
