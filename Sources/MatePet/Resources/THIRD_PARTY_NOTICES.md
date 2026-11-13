# MatePet third-party notices

The MatePet module vendors the following runtime dependencies so the pet works
offline (no CDN, no Electron):

| File | Project | License | Source |
| --- | --- | --- | --- |
| `vendor/three.module.js`, `vendor/three.core.js`, `vendor/jsm/**` | three.js r180 | MIT | https://github.com/mrdoob/three.js |
| `vendor/three-vrm.module.js` | @pixiv/three-vrm 3.4.2 | MIT | https://github.com/pixiv/three-vrm |
| `Zome.vrm` | Zome (ゾメちゃん) by **Yorshka** | **Redistribution_Prohibited** (VRM meta) | extracted from the Mate-Engine reference project in this repo |
| `VRMKit`, `VRMRealityKit` (SwiftPM dependency) | VRMKit 0.11.0 | MIT | https://github.com/tattn/VRMKit |
| `vendor/three-vrm-animation.module.js` | @pixiv/three-vrm-animation 3.4.2 | MIT | https://github.com/pixiv/three-vrm |

The full MIT texts are in `vendor/licenses/THREE-LICENSE.txt` and
`vendor/licenses/THREE-VRM-LICENSE.txt`.

## Important: Zome.vrm license

`Zome.vrm` embeds VRM 0.x metadata:

```json
{ "title": "ゾメちゃん", "author": "Yorshka", "licenseName": "Redistribution_Prohibited" }
```

It is included because the user's Mate-Engine reference copy contains it and
the pet is currently a local/private build. **Do not redistribute a public
binary that contains this model without replacing it with a VRM whose license
allows redistribution.** The renderer is model-agnostic: drop any VRM 0.x/1.0
file at `Sources/MatePet/Resources/` and update the `./Zome.vrm` path in
`mate-pet.html`.