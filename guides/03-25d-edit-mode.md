# 2.5D Edit Mode

Select a shape and it lifts off the page — right where you drew it — with your
ink riding on its surface. The rest of the drawing stays visible around it.

## Entering

1. Tap the lasso icon to enter Select mode.
2. Circle a shape (lasso) or press-and-hold on it (smart selector).
3. On release, the shape lifts into 2.5D automatically.

## While editing

- **Pen on the shape** — draws ink on its surface; it rotates with the shape.
- **Pen beside the shape** — draws normal flat ink on the canvas.
- **One-finger drag** — rotates the shape (arcball).
- **Two-finger pinch / twist** — scales / rolls the shape.
- **Hold the rotate button + pen** — rotate with the pencil.
- **Hand tool** — distort the mesh with a pressure/speed-sensitive brush;
  ink on the surface deforms with it. Eraser icon toggles smoothing.
- **Eraser (draw mode)** — removes the nearest surface stroke.
- **Expand button** — opens the full 3D workspace: zoom the camera in close,
  switch between objects, or re-infer the shape from its strokes. Closing it
  returns to your drawing with everything you did there in place.

## Leaving

Tap any empty canvas area (or the checkmark). The shape bakes back to flat
ink exactly as you last saw it — rotate a face 30° and the drawing keeps that
30° view. Select the same ink again later to re-lift it and keep editing;
the shape remembers its 3D form and orientation.

## Notes

- One shape lifts at a time.
- Undo covers drawn strokes, deforms, and the bake itself.
- If a selection can't be lifted (no closed shape found), the ink is left
  untouched and a brief message appears.
- A stroke that only partially lifts onto the shape (part of it hangs off the
  mesh) is visibly truncated to the on-shape portion during the session, and
  it commits that way — what you see is what stays.
