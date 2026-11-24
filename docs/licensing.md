# Licences and source code

iPlay5 is free and open-source software under the [GNU Affero General Public License v3.0](https://github.com/reefbarman/iPlay5/blob/main/LICENSE) (AGPL-3.0-only), the same licence as [chiaki-ng](https://github.com/streetpea/chiaki-ng), which it's built on. This applies however you installed it, whether from the App Store, TestFlight or by sideloading.

## What the licence means for you

- **Use it for anything.** There's no cost and no restriction on how you use the app.
- **Get the source.** The full source for every release is on [GitHub](https://github.com/reefbarman/iPlay5).
- **Change it and share it.** You can modify iPlay5 and share your version, as long as you share its source under the same licence.
- **No warranty.** The app comes as is, as the licence explains in full.

The licence is the same as chiaki-ng's: AGPL-3.0 with an extra permission for linking with OpenSSL. iPlay5 doesn't use OpenSSL (it uses Mbed TLS), so the extra permission makes no practical difference.

## In the app

Open **Settings › About**:

- **Version** shows the version and build number.
- **Source code** opens the source on GitHub for the exact version you have installed. Release builds link to their tag (for example `v0.12.1`). Builds you make yourself link to `main`.
- **Licences** lists everything bundled into iPlay5. Tap one to read its copyright notice and full licence text.
- **Privacy policy** opens the [privacy policy](privacy.md).

## Getting the source for a version

Every release has a tag with the same name as its version, prefixed with `v`. Its source is at `https://github.com/reefbarman/iPlay5/tree/vVERSION`, and each [GitHub release](https://github.com/reefbarman/iPlay5/releases) has a source archive. The bundled libraries are Git submodules, so clone with `--recursive` to get everything:

```sh
git clone --recursive --branch v0.12.1 https://github.com/reefbarman/iPlay5.git
```

## Installing a modified build

The [build from source steps](https://github.com/reefbarman/iPlay5#build-from-source) in the README cover building and running your own version on your iPhone or iPad from Xcode. To build an IPA you can sideload, run `scripts/package-ipa.sh` and install the result with SideStore, AltStore or Sideloadly, signed with your own Apple ID. A free Apple ID works.

## Bundled components

| Component                                                                                                                  | Licence       | What it does                                     |
| -------------------------------------------------------------------------------------------------------------------------- | ------------- | ------------------------------------------------ |
| [iPlay5](https://github.com/reefbarman/iPlay5)                                                                             | AGPL-3.0-only | The app                                          |
| [chiaki-ng](https://github.com/streetpea/chiaki-ng), based on the original [Chiaki](https://git.sr.ht/~thestr4ng3r/chiaki) | AGPL-3.0-only | The PS5 Remote Play protocol                     |
| [P5M](https://github.com/beecrepaldi-afk/P5M-mac)                                                                          | AGPL-3.0      | The source of iPlay5's Takion v20 support        |
| [Mbed TLS](https://github.com/Mbed-TLS/mbedtls)                                                                            | Apache-2.0    | Encryption for the connection to the PS5         |
| [Opus](https://opus-codec.org)                                                                                             | BSD-3-Clause  | Game audio and microphone codec                  |
| [nanopb](https://github.com/nanopb/nanopb)                                                                                 | Zlib          | Stream protocol messages, through chiaki-ng      |
| Jerasure and GF-Complete                                                                                                   | BSD-3-Clause  | Recovering lost video packets, through chiaki-ng |

The full licence texts are in the app under **Settings › About › Licences**, and in [`App/Resources/Licenses`](https://github.com/reefbarman/iPlay5/tree/main/App/Resources/Licenses) in the repository.

Not affiliated with or endorsed by Sony Interactive Entertainment. "PlayStation" and "PS5" are trademarks of Sony Interactive Entertainment Inc.
