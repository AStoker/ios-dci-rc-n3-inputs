# Hardware test 4: the clean input API (~10 minutes)

The app now opens on the **Input** tab, running on `RCN3Remote` (the API the simulator will use). Install the new build (⌘R). Use **Log › Mark step N** before each step as before.

1. Plug in the remote and power it on. On **Input**, Status should go Waiting → Connecting → **Streaming**. Note the Samples rate (~50-60/s while you move a stick, lower at rest), **Stick poll** (~100/s, ~10 ms) and **Mode/button push** (~7/s).
2. Move each stick in slow circles. Do the dots track smoothly, with no lag you can feel?
3. Gimbal dial both ways; flight mode C → N → S; press each of Pause/RTH, Shutter, Photo/Video (hold about half a second). Does each one light up?
4. Switch **Stick mode** between Mode 1/2/3 and push the left stick up. Throttle should move in Mode 2, Pitch in Modes 1 and 3.
5. **Record samples**, fly the sticks around for ~30 s, then **Stop recording**. Tap ▶︎ on the new recording: does the replay look like what you did? Tap **Share** on it and AirDrop it to me.
6. Unplug the remote, wait 5 s, plug it back in. Does it return to Streaming by itself?
7. Leave the app for 10 s (swipe home), come back. Does it return to Streaming?
8. Switch the engine to **Raw probe** and back to **Input API**. Streaming again?
9. Optional: with DJI Fly open and holding the remote, switch to the probe. Expect "Failed: Couldn't open…". Then force-quit DJI Fly; within ~2 s it should reconnect on its own.

Then **Copy report** + **Share log file** as before, plus the recording from step 5.
