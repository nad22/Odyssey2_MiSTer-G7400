# G7400 Image Positioning and Scaling

This guide describes EF9340 image positioning and the active display crop in
G7400 mode. The values are changed in RTL; there is currently no dedicated
MiSTer OSD control for them.

## Core Settings

The settings are in the G7400/EF9340 section of `rtl/vp_console.vhd`:

```vhdl
ef_hpos_s <= std_logic_vector(unsigned(hpos_s) - 13);
ef_vpos_s <= std_logic_vector(unsigned(vpos_s) - 2);

hblank_o <= '1' when ef_crop_s = '1' and
                     (unsigned(hpos_s) < 10 or unsigned(hpos_s) > 329)
            else hblank_vdc_s;
vblank_o <= '1' when ef_crop_s = '1' and
                     (unsigned(vpos_s) < 12 or unsigned(vpos_s) > 230)
            else vblank_vdc_s;
```

The values above match the current working-tree settings. The crop boundaries
are **inclusive**: the blanking condition applies before and after the active
range.

### Moving the Image

`ef_hpos_s` and `ef_vpos_s` map raster positions to EF9340 coordinates:

```text
EF-X = raster-X - horizontal offset
EF-Y = raster-Y - vertical offset
```

- EF source pixel 0 appears at raster-X equal to the horizontal offset.
  The current value is `13`, so EF-X=0 is at raster-X=13.
- EF line 0 appears at raster-Y equal to the vertical offset.
  The current value is `2`.
- Increase an offset value to move the image right or down; decrease it to
  move the image left or up.

When changing the image position, move the crop boundaries as well if the
visible image size should stay the same. Changing only an offset may crop
image content on the left/top or expose empty border pixels on the
right/bottom.

### Changing the Visible Crop

The `hblank_o` and `vblank_o` conditions define which raster area is passed to
MiSTer as the active image. The current ranges are:

| Axis | Active raster range | Size |
|---|---:|---:|
| Horizontal | 10–329 | 320 pixels |
| Vertical | 12–230 | 219 lines |

The size is `maximum - minimum + 1`. For example, `10..329` gives a width of
320 pixels. Moving the boundaries farther apart reveals more raster content;
moving them closer together crops content.

Changing these boundaries **does not scale EF pixels in RTL**. It changes the
active crop and therefore the image geometry received by the MiSTer scaler.
EF cropping is enabled only when G7400 mode is active and the game has
programmed the mix table (`ef_crop_s`).

### Actual Stretching / Aspect Ratio

The MiSTer scaler's **Aspect Ratio** setting controls the display aspect
ratio. The core reports 4:3 by default; `VIDEO_ARX` and `VIDEO_ARY` are set
in `Odyssey2.sv`. This setting affects the entire core image, not just the
EF9340 overlay.

There is currently no separate horizontal or vertical scaling for the EF9340
image. That would require coordinate scaling to map EF pixels to a different
raster width or height. Do not change the `hblank_o`/`vblank_o` boundaries to
perform scaling; that only changes the crop.

## Build and Verification

After an RTL change, rebuild the core with Quartus and check both the G7400
boot screen and a Plus game. The boot screen and games may have different EF
content near the image edges.
