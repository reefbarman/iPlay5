# Controller model

`App/Resources/DualSense.usdz` is the Controller Test screen's 3D controller.

It comes from "Sony DualSense" in [CasperH2O/3DControllerModels](https://github.com/CasperH2O/3DControllerModels), released under CC0 1.0 (public domain). Thanks to CasperH2O.

## Re-exporting

```sh
git clone https://github.com/CasperH2O/3DControllerModels /tmp/ctrlmodels
/Applications/Blender.app/Contents/MacOS/Blender --background --disable-autoexec \
  "/tmp/ctrlmodels/Sony DualSense.blend" --python scripts/controller-model/export.py -- App/Resources/DualSense.usdz
```

The export puts +X to the right, +Y towards the triggers and +Z out of the face, 2 units wide, with the touchpad as its own part. Materials are dropped because `App/Views/ControllerScene.swift` builds its own.

## Previewing on the Mac

```sh
swiftc -O App/Views/ControllerScene.swift scripts/controller-model/preview/main.swift -o /tmp/controller-preview
/tmp/controller-preview App/Resources/DualSense.usdz /tmp/controller-preview-out
```

This writes rest, pressed and turned PNGs.
