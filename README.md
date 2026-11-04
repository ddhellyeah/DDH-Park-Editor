# DDH Park Editor (Quick Drop+)

Works with skate.'s own Quick Drop. Drop objects as normal, then press **F6** to fine-tune them with handles, like the DDH Object Maker's 3D maker.

- **W** move: drag the red / green / blue arrows (they face the way the object does), or the coloured squares to slide along a side
- **E** turn: drag the ring
- **R** size: drag the green cubes
- The object follows as often as the game takes edits, and lands exactly where you let go
- Click another placed object to pick it. Drag empty space to turn the view, right-drag to slide it, scroll to zoom, arrows and PgUp / PgDn to fly it
- **G** snap (0.25 m, 15°, 0.1), **Shift** bigger steps, **Ctrl+Z** undo, **F** look at the object, **Esc** done
- The panel (ReSkate 2.1.4+) has folding sections:
  - **Move and turn**: click the X, Y, Z, Turn or Size number and type a new one (it's used when you stop typing). `+2` adds 2, `+-0.5` takes 0.5 off, a comma works as the decimal point. Below that, nudge buttons with Fine / Normal / Big steps (0.01 m · 1° to 1 m · 45°)
  - **Handles**: Move / Turn / Size and steps while dragging
  - **Objects in this park**: a scrolling list of every placed object, with a search box and All / Near the view / DDH filters. Click one to pick it and fly to it
  - **Park locked** and **Controls**
- On older ReSkate the panel falls back to the old sliders

Without opening it: hold **Ctrl** and use [ ] (turn), PgUp / PgDn (height), Z / X (size), arrows (slide) on the last dropped object.

Placed objects only turn about up: the game allows no tilt for plugins. To tilt an object, use ReSkate's own park editor (ReSkate menu > BUILD > PARK EDITOR). Turning a tilted object here makes it flat again; moving it keeps the tilt.

A park with objects from a mod that is off or not installed cannot be changed at all, by this or by Quick Drop: turn that mod back on.

Needs ReSkate 2.1.4 or newer for the full panel (older versions get a simpler one).

## Install

Unzip into ReSkate's `Mods` folder, so you get `Mods\DDH Park Editor\`. Start the game, and if F6 does nothing, approve DDH Park Editor in the ReSkate menu under Plugins.
