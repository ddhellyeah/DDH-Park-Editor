# DDH Park Editor (Quick Drop+)

Works with skate.'s own Quick Drop. Drop objects as normal, then press **F6** to fine-tune them with handles, like the DDH Object Maker's 3D maker.

- **W** move: drag the red / green / blue arrows (they face the way the object does), or the coloured squares to slide along a side
- **E** turn: drag the ring
- **R** size: drag a corner of the green box
- The object follows as often as the game takes edits, and lands exactly where you let go
- Click another placed object to pick it. Drag empty space to turn the view, right-drag to slide it, scroll to zoom, arrows and PgUp / PgDn to fly it
- **G** steps (0.25 m, 15°, 0.1), **Shift** bigger steps, **Ctrl+Z** undo, **F** look at the object, **Esc** done
- **T** snap to objects (on to begin with): while you drag, the object's sides meet or line up with the objects near it, and the turn ring catches their turn. What it snapped to is outlined in blue. Hold **Ctrl** to drag without it. Among several objects it fits against the ones it really sits beside first. Objects snap by their outlines: the shape they fill seen from above (a curved bench is a curve, not a box), side to side, and they turn to meet a side flat. Outlines come from the model itself where it can: the Object Maker's models (built in), or the game's model found by the object's name. Anything else is measured with rays to about half a millimetre, and after a snap the seam is checked and the outline fitted to the real side. When it meets an object that is turned, it takes that object's turn so the sides meet flat (pull it away and its own turn comes back). Works with objects from any mod: the Object Maker's sizes are built in (`plugin/sizes.lua`); anything else is measured with rays the first time it is near the picked object (keep it still a moment) and remembered from then on. If a size comes out wrong, pick the object and press **Measure it again**. Objects you can't skate on (no collision) can't be measured and snap by their middle point
- The panel (ReSkate 2.1.4+) has folding sections:
  - **Move and turn**: click the X, Y, Z, Turn or Size number and type a new one (it's used when you stop typing). `+2` adds 2, `+-0.5` takes 0.5 off, a comma works as the decimal point. Below that, nudge buttons with Fine / Normal / Big steps (0.01 m · 1° to 1 m · 45°)
  - **Handles**: Move / Turn / Size and steps while dragging
  - **Objects in this park**: a scrolling list of every placed object, with a search box and All / Near the view / DDH filters. Click one to pick it and fly to it
  - **Park locked** and **Controls**
- On older ReSkate the panel falls back to the old sliders

**Controller** (Xbox or PlayStation): **LB+RB** opens it, **B** closes.
- Left stick slides the object (the way the view faces), **RT / LT** raise / lower it (it snaps to objects too; keep pushing to go past)
- **LB / RB** turn (15°), **D-pad up / down** size, **D-pad left / right** pick the next placed object
- Right stick turns the view, hold **Y** + right stick to zoom, **R3** looks at the object
- **A** snap (stick then moves in 0.25 m steps), **View** undo, hold **X** for fine steps (1°, 0.01, slow slide)

Without opening it: hold **Ctrl** and use [ ] (turn), PgUp / PgDn (height), Z / X (size), arrows (slide) on the last dropped object.

Placed objects only turn about up (the game allows no tilt for plugins). A park with objects from a mod that is not installed cannot be changed at all, by this or by Quick Drop.

Needs ReSkate 2.1.2 or newer. Unzip into ReSkate's `Mods` folder.
