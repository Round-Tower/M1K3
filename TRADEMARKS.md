# M1K3 Trademark and Brand Policy

The code in this repository is source-available under the
[Functional Source License, FSL-1.1-ALv2](./LICENSE) (Apache-2.0 for
revisions before 2026-09-09 — see `NOTICE`). The *identity* of M1K3 is not
part of either grant. The FSL's Trademarks clause says so explicitly — it
grants no right to use our trademarks, trade names, service marks, or product
names beyond identifying us as the origin of the Software — and Section 6 of
the Apache License said the same for the earlier revisions.

## What is protected

The following are trademarks and brand assets of Kevin Murphy / Round Tower
("the M1K3 marks"), whether or not registered:

- The names **M1K3**, **M1K3 Voice**, **Lil M1K3**, and **Brain at Home**.
- The **M mark** (the 5×7 phosphor pixel M — `site/favicon.svg`, its
  tile-less nav cut `site/mark.svg`, the app icon, and the screensaver glyph).
- The **pixel face** and the **CRT look** as M1K3's trade dress: the pixel
  face itself, the phosphor treatment (the shader that turns a model into a
  glowing wireframe on a dark tile), and the way the companions are presented
  as M1K3. **Not the companion models.** The creatures are other people's
  work, used under their own licences, and no trademark or copyright in them
  is claimed here: the Fox (also the mesh under Phosphor Fox) is the Khronos
  glTF sample asset — model by PixelMannen (CC0), rigging and animations by
  tomkranis (CC-BY 4.0); Colobus, Gecko, Inkfish and Sparrow are from
  Quaternius's Quirky Series (CC0). Their authors are credited in `NOTICE`,
  in the app's Third-party licenses screen, and on m1k3.app.
- The app icons, the `og.png` / `readme-hero.png` artwork, the App Store
  screenshots, and the m1k3.app site design.
- The M1K3 spoken voice as configured and shipped in the app (a sound mark
  is claimed as intent; it earns protection through use in commerce, and
  this is stated so nobody mistakes it for a settled right today).

The **names and marks** are outside the licence grant by the LICENSE's own
Trademarks clause (Section 6 of the Apache License for earlier revisions). The **brand-asset files** (the M mark files, the site artwork, the
brand plates, the app icon and App Store artwork) are excluded from the grant
by the notice in [`NOTICE`](./NOTICE), from the commit that added it onward;
they are all rights reserved. The companion model files
(`macos/Sources/M1K3Avatar/Companions/**`) are not ours to license either way:
they remain under their authors' licences (CC0 / CC-BY 4.0, listed in
`NOTICE`), and only their *presentation as M1K3* — the phosphor treatment and
the pixel face beside them — is restricted below.

Most of these marks are unregistered. Unregistered marks are real but narrower
than a registration: they reach the markets M1K3 has actually reached, and
carry no presumption of validity. Registration is a separate step.

## What you may do without asking

- Build, run, fork, and modify the code for yourself and inside your own
  organisation (that is the licence grant; offering it to others as a
  competing commercial product is not — see `LICENSE`).
- Say truthfully that your work is "based on M1K3" or "built from the M1K3
  source", with a link to this repository.
- Use the name M1K3 to refer to this project in articles, talks, package
  managers, and issue trackers.

## What you may not do

- Publish, distribute, or sell a build of this code, modified or not, **under
  the name M1K3** or any confusingly similar name, on any app store, download
  site, or package registry. That includes the Mac App Store, TestFlight,
  Homebrew, Setapp, and direct DMG downloads.
- Ship the M mark, the app icon, the artwork, or the M1K3 voice in any
  product that is not the official M1K3 build.
- Use the pixel face, the CRT look, or the M1K3 voice as the
  source-identifying face of another product — trade dress that makes a fork
  look like, or pass for, the official M1K3. (Using the same CC0 / CC-BY
  creatures in your own product, under their authors' terms and with their
  attribution, is fine — they were never ours.)
- Present a fork as the official M1K3, or imply endorsement by Kevin Murphy
  or Round Tower.

If you distribute a fork, give it its own name and its own icon, remove the
M1K3 marks and the brand-asset files excluded in `NOTICE` (the companion
models may stay — they are their authors' work; keep their attribution and
don't present them as M1K3), and keep the `LICENSE` and `NOTICE` files as the
License requires.

## The official builds

The only official M1K3 builds are the ones signed and distributed by Round
Tower: the App Store / TestFlight app with bundle identifier `app.m1k3`, and
the signed DMGs linked from <https://m1k3.app>.

## Asking

Want to use a mark in a way this policy does not cover — a community port, a
tutorial series, a distribution package that keeps the name? Open an issue or
write to kevin@round-tower.ie. The answer is usually yes when the use is
truthful and does not confuse people about what the official app is.

---

*Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 (the policy
follows the Apache 2.0 §6 carve-out and the shape used by other open-core
Mac apps; the list of marks is complete as of the App Store submission race.
Prior: Unknown)*
*Review: claude-fable-5.1, 2026-09-07 — PR #242 review 1: a policy doc cannot
claw back files the root LICENSE already grants, so the brand-asset file
exclusion now lives in NOTICE (forward from that commit, earlier revisions
stay granted); companion faces scoped to trade-dress use, not redistribution
(their provenance is not all first-party); sound-mark and unregistered-scope
caveats added. Confidence now 0.85.*
*Review: Kev + claude-fable-5.1, 2026-09-09 — the relicense (ADR 0005): the
code moved from Apache-2.0 to FSL-1.1-ALv2 from this commit on, so the policy
now leans on the FSL's own Trademarks clause and names Apache §6 only for the
earlier revisions; the "what you may do" grant no longer says "commercially"
— competing commercial use is the one thing the FSL withholds. Marks list
unchanged; `site/mark.svg` (new, the nav cut of the M) added to the marks list
and to NOTICE's file exclusion (code-quality review catch). Confidence now 0.85.*
*Review: Kev + claude-fable-5.1, 2026-09-09 (later) — Kev's catch: the companion USDZ meshes
were listed as brand assets, but they are third-party work (Khronos Fox: PixelMannen CC0 +
tomkranis CC-BY 4.0; Quaternius creatures CC0). A trademark covers what identifies US, not
what we borrowed. Protected now = the pixel face + the phosphor/CRT treatment as trade dress;
the models are explicitly disclaimed and credited (NOTICE, in-app licences screen, site).
Confidence now 0.85.*
