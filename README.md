# DDH Park Editor (Quick Drop+)

Works with skate.'s own Quick Drop. Drop objects as normal, then press **F6** to fine-tune them with handles, like the DDH Object Maker's 3D maker.

- **W** move: drag the red / green / blue arrows (they face the way the object does), or the coloured squares to slide along a side
- **E** turn: drag the green ring. The red ring tilts it forward and back, the blue ring to the side (also Tilt X / Tilt Z in the panel; Level puts it flat)
- **R** size: drag a corner of the green box
- The object follows as often as the game takes edits, and lands exactly where you let go
- Click another placed object to pick it. Drag empty space to turn the view, right-drag to slide it, scroll to zoom, arrows and PgUp / PgDn to fly it
- **G** steps (0.25 m, 15°, 0.1), **Shift** bigger steps, **Ctrl+Z** undo, **F** look at the object, **Esc** done
- **T** snap to objects (on to begin with): while you drag, the object's sides meet or line up with the objects near it, and the turn ring catches their turn. What it snapped to is outlined in blue. Hold **Ctrl** to drag without it. Side by side, they share height: an object that meets another side to side takes its height (bottoms level, or tops level when that's less of a move, up to 1 m), whichever handle moves it. Among several objects the closest one comes first, and it keeps to the one it snapped to (no flicking) until another is clearly closer. Objects snap by their outlines: the shape they fill seen from above (a curved bench is a curve, not a box), side to side, and they turn to meet a side flat. Outlines come from the model itself where it can: the Object Maker's models (built in), or the game's model found by the object's name. Anything else is measured with rays to about half a millimetre, and after a snap the seam is checked and the outline fitted to the real side. When it meets an object that is turned, it takes that object's turn so the sides meet flat (pull it away and its own turn comes back). Works with objects from any mod: the Object Maker's sizes are built in (`plugin/sizes.lua`); anything else is measured with rays the first time it is near the picked object (keep it still a moment) and remembered from then on. If a size comes out wrong, pick the object and press **Measure it again**. Objects you can't skate on (no collision) can't be measured and snap by their middle point
- The panel (ReSkate 2.1.4+) has folding sections:
  - **Move and turn**: click the X, Y, Z, Turn or Size number and type a new one (it's used when you stop typing). `+2` adds 2, `+-0.5` takes 0.5 off, a comma works as the decimal point. Below that, nudge buttons with Fine / Normal / Big steps (0.01 m · 1° to 1 m · 45°)
  - **Handles**: Move / Turn / Size and steps while dragging
  - **Objects in this park**: a scrolling list of every placed object, with a search box and All / Near the view / DDH filters. Click one to pick it and fly to it
  - **Park locked** and **Controls**
- On older ReSkate the panel falls back to the old sliders

**Controller** (Xbox or PlayStation), like Quick Drop: **LB+RB** opens it.
- Not holding anything: the left stick flies around freely, **RT / LT** up / down, **D-pad up / down** zoom, **D-pad left / right** next object. The cross in the middle shows which object **A** picks up
- **A** picks it up, **A** again puts it down. **B** cancels (it goes back where it was); with nothing held **B** closes
- Holding: left stick moves it, **RT / LT** raise / lower, **LB / RB** turn (15°), **D-pad up / down** size; it snaps to objects (keep pushing to go past)
- **X**: not holding, copies the object the cross is on and hands you the copy (**B** right away takes the copy back); holding, drops a copy where it is (tilt and all) and keeps the original in hand. **Y** twice removes the object the cross is on (or the one held)
- Right stick: not holding, looks around where the view stands (like Quick Drop); holding, circles round the object. (Controls: "Invert look up/down" and "left/right" switches), **R3** looks at the object, **View** undo, **Menu** steps on / off, hold **L3** for fine (1°, 0.01, slow)

Without opening it: hold **Ctrl** and use [ ] (turn), PgUp / PgDn (height), Z / X (size), arrows (slide) on the last dropped object.

Online: press **Save as park mod (for online)** in the panel. It writes the whole park on this map, tilts and all, as a park mod and opens its folder: copy that folder into ReSkate's `Mods` folder, then Build > Park mods > Load (in multiplayer the host loads it, and everyone sees the tilts). Park mods only work on the game's own maps.

Tilting: the game saves only a turn about up, so this plugin holds tilted objects itself (fixed, skateable) and remembers each tilt per map, putting it back whenever the park loads. Offline only, at most 32 tilted objects, and only while this plugin runs; while you move a tilted object it shows flat for a moment. Tilted objects snap too, face to face: brought against a tilted object (its side or its top), an object takes its tilt so the two sit flat, and gets its own back when pulled away. A park with objects from a mod that is not installed cannot be changed at all, by this or by Quick Drop.

Needs ReSkate 2.1.2 or newer. Unzip into ReSkate's `Mods` folder.
