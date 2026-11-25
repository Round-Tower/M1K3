// M1K3 — App Store screenshot frames: layout + which real capture each uses.
// Copy lives in strings.js. Captures ("plates") live in plates/<target>/.
//
// Plates are REAL app captures, nothing else. Until you drop yours in,
// `node placeholders.js` writes labelled stand-ins so the set can be reviewed.
//
// Order is deliberate (v2, 2026-10-22). The first three carry the listing: at a sixth of
// full size only the h1 reads, so 01-03 work as three billboards in a row. 01 leads with
// what people search (local / offline / private), 02 is the only card showing a Mac and an
// iPhone together (and the tagline's home), 03 shows what the rest of the row can't (voice).
//
// Portrait layouts (iPhone / iPad):
//   top       type block on top, capture panel below, bleeding off the bottom
//   top-pair  same, two captures side by side (A / B, each labelled)
//   top-grid  same, 2×2 tiles (each labelled)
//   stat      giant pixel-font number, then the type, then a short capture panel
//   duo       a laptop (Mac plate) behind, the phone/pad in front, a dashed Wi-Fi pill
// Landscape layouts (Mac):
//   edge      type column left, laptop right (same geometry as split since 2026-09-23)
//   split     type column left (~40%), laptop right, wholly on canvas (it bled off the edge until 2026-11-25)
//   grid      type column left, 2×2 tiles right
//   stat      giant number left, capture right
//   duo       type column left, laptop + iPhone right, the pill between
//
// Frame keys: targets (only these targets render it), billboard (01-03 legibility: lighter
// dim, 40px eyebrow), h1px (headline size in design px, times the locale's TYPE.h1),
// focus (object-position; a phone/pad screen may also take a crop or bands — a laptop never, 2026-11-25),
// mac / phone / macFocus / phoneFocus (duo plates), lifts (see render.js lift()).

// The iPad onboarding cards a mask must never touch: [x0, y0, x1, y1, radius] in plate px.
const IPAD_CARDS = [[552, 1005, 1512, 1210, 34], [552, 1234, 1512, 1471, 34], [552, 1495, 1512, 1668, 34]];

// The 1.2.1 brain-at-home plates (09:41, 2026-10-23): "Pair with your Mac", a pushed sheet with
// no status-bar defects. iPhone: back button y 186-317, title 380-473, instruction card x 48-1157 /
// y 504-777 (corner ≈94), "No camera? Paste the link" 871-910, paste card 952-1263, "Codes expire
// after about a minute." 1296-1331, then black to 2622. iPad: back 64-151, title 194-255, card
// x 40-2024 / y 276-379, header 441-466, paste card 496-703, footer 726-749, black to 2752 (the
// resize grip at x 2008-2054 / y 2696-2742). The sheet is the top half (iPhone) or fifth (iPad)
// of its plate, so the duo screens are the sheet rows and the device carries the rest (DUO_PORTRAIT).
const BAH_SHEET = {
  // 12 px margin each side of the cards: the sheet ~6% larger, its rows whole
  ios: { x: 36, w: 1134, fill: "#000", bands: [[0, 1360, 0]] },
  ipad: { w: 2064, fill: "#000", bands: [[0, 770, 0]] },
};

// Retouches render.js applies to a COPY of a plate (mask.py → out/.plates); captures stay as
// shot. Each removes a capture defect, never adds content. Recaptures retire them.
const PLATE_MASKS = {
  // mac: retired 2026-11-25 with the 1280×800 recapture (the badge reads v1.6.0, Serve is pinned off,
  // the onboarding and voice defects did not recur). Re-derive in 2560×1600 plate px if one returns.
  // The wireframe fox showing in the gaps between the brain cards (re-derived 2026-10-22 on the
  // 1.2.1 recapture, four cards). iPhone: its ear in the Mini/Lil gap (y 1039-1073) and its legs
  // in the Lil/Home gap (y 1477-1512); the Home/PCC gap is clean. "left" keeps the backdrop's
  // gradient (x=38 is clean on every row). iPad: all three gaps carry lattice lines inside the
  // 04 lift's crop (x 551-1513); the head and tail outside the cards stay, as the app draws them.
  // QA r3: the ear's last row is y 1074 (1075 is the Lil card's top highlight), so 36 rows.
  ios: {
    onboarding: [{ rect: [40, 1039, 1130, 36], fill: "left" }, { rect: [40, 1477, 1130, 36], fill: "left" }],
    // QA r3: a solid light-grey face (an "N", x 603-645, y 1362-1414) between the fox's hind legs
    // on the Speaking plate: the site Fox has black faces only. "bright" repaints the face's pixels
    // and nothing darker; the legs ghosting through the glass card below stay, as the app draws them.
    "voice-speaking": [{ rect: [601, 1362, 49, 53], key: "bright", min: 24, fill: [0, 0, 0] }],
    // QA r6: the Phosphor Fox behind the grounded turn runs across the action row and the source
    // chip (x 190-990, y 1111-1575). Below the answer bubble (which ends at y 1110 and is never
    // touched) every NEUTRAL grey pixel goes black: the lattice is neutral (b - r within ±1), the
    // chip text and the icons are tinted (b - r 2-6), so the fox goes and the chip stays whole.
    "ask-documents": [{ rect: [0, 1111, 1206, 470], key: "neutral", fill: [0, 0, 0] }],
  },
  ipad: {
    // QA r3: the gap rects left lattice in the cards' rounded-corner wedges. One rect per backdrop
    // tone now paints everything round the Mini, Lil and Home cards (measured x 552-1512; y 1005-1210,
    // 1234-1471, 1495-1668; corner radius 34), wedges included; the cards themselves are kept.
    onboarding: [
      { rect: [540, 1005, 990, 35], fill: [4, 4, 7], keep: IPAD_CARDS },
      { rect: [540, 1040, 990, 640], fill: [1, 1, 3], keep: IPAD_CARDS },
    ],
    // QA r4: the 1.2.1 fox plates carry solid light-grey faces on the legs (the Speaking plate
    // most, x 700-1120 / y 1450-1770; smaller slivers on Listening, chat and the Fox tile). The
    // site Fox has black faces only. "solid" repaints only regions a 7 px opening keeps (faces),
    // shrunk 2 px so each face's outline stays; the 2-3 px lattice lines are thinner and stay.
    "voice-speaking": [{ rect: [280, 940, 1320, 900], key: "solid", min: 100, open: 7, rim: 2, fill: [0, 0, 0] }],
    "voice-listening": [{ rect: [280, 940, 1320, 900], key: "solid", min: 100, open: 7, rim: 2, fill: [0, 0, 0] }],
    chat: [{ rect: [280, 940, 1320, 900], key: "solid", min: 100, open: 7, rim: 2, fill: [0, 0, 0] }],
    "companion-fox": [{ rect: [280, 940, 1320, 900], key: "solid", min: 100, open: 7, rim: 2, fill: [0, 0, 0] }],
    // QA r5: iPadOS's window-resize grip (a white arc, x 2008-2054 / y 2696-2742) shares rows with
    // the Answer ratings footer that 08 now shows. Black, the list's own background. (The r4 grip
    // mask on brain-at-home is retired: the duo's bands end at y 770.)
    "privacy-label": [{ rect: [2000, 2688, 64, 64], fill: [0, 0, 0] }],
  },
};

const PORTRAIT = [
  {
    id: "01_hero",
    layout: "top",
    plate: "chat",
    hero: true,
    billboard: true,
    h1px: 192,
    // The iPad's UI is small in its device frame: lift the moment out (plate pixels).
    // anchor: the lift sits over its own source on the screen, so the moment shows once
    // (QA 2026-10-22: a lift beside its still-visible source read as a doubled render).
    // QA r2: from y=130 the lift also covers the toolbar row, so no half-icons poke above it.
    // 1.2.1 recapture: question y 229-307, reply y 340-460 (x 333-1727), actions y 500-538,
    // toolbar y 67-151. From y=120 the anchored lift still covers the toolbar.
    // QA r4: from y=120 the lift's top 110 rows were dead black. The iPad screen now drops the
    // toolbar row and the empty rows under it (y 60-190, all under the lift anyway), and the lift
    // starts 34 rows above the question, anchored over its own band (img 1).
    focus: { ipad: { w: 2064, fill: "#000", bands: [[0, 60, 0], [190, 2562, 60]] } },
    lifts: { ipad: [{ crop: [300, 195, 1480, 370], w: 1200, anchor: { img: 1 } }] },
  },
  // Replaces v1's 06_brain-at-home. The Mac plate shows "Serve my brain to my devices"
  // OFF and, higher up, the MCP agent picker (a third-party name). The screen shows only
  // the band with the Brain at Home header and label (plate y 1460-1650, x 680-1780): left
  // of the toggle (x≈2050), below the picker, above the caveat paragraph (y≈1655, whose
  // "asks can reach the web" sat under "never the internet"), on the window's own grey.
  // Recapture the Mac with the toggle ON (ideally a paired device listed) before 1.2.1.
  // QA r2: that band alone left ~80% of the screen flat grey. The screen now stacks the
  // window's own header + tabs (Privacy selected) over the Brain at Home header and row, at the
  // window's full width; PLATE_MASKS painted out the OFF switch and the stale v1.0.0 badge.
  // 2026-11-25: the Mac screen is the whole Brain at Home pane (no band; a laptop never crops), and
  // the 1280×800 recapture retired both masks (the badge reads v1.6.0, Serve is pinned off).
  {
    id: "02_your-devices",
    layout: "duo",
    mac: "brain-at-home",
    phone: "brain-at-home",
    macFocus: "50% 0%",
    // QA r5 (1.2.1 plates, 09:41): the status bar is clean, so the r3 status bands are retired.
    // The screen is the sheet's rows (BAH_SHEET); DUO_PORTRAIT sizes the device so the empty
    // black under the sheet runs off the canvas instead of reading as a blank slab.
    phoneFocus: BAH_SHEET,
    billboard: true,
    h1px: 150,
  },
  // The 1.2.1 Speaking plates have no "Mike" (iPhone: "Nobody else is listening." mid-karaoke;
  // iPad: a real reply), so the QA r2 bands that dropped the card are retired: whole screens.
  // iPad: the pair spreads 30u each way so the back one's caption clears the front bezel.
  {
    id: "03_voice",
    layout: "top-pair",
    plates: ["voice-listening", "voice-speaking"],
    // QA r4, iPad: the pixel-font tags sat on the foxes' chests (the r3 bands put each fox at the
    // top of its screen, where .device .tag sits). Each fox now starts lower (dest 760), leaving
    // the tag the empty black above it, and the front device rides 160u higher so its reply card
    // still lands on the canvas (it covers the back screen only right of x≈1580, clear of the fox
    // and the pill).
    // iPhone: the back fox's tail tip (plate x≈880) ran under the front bezel: 25u / 20u apart.
    pairNudge: { ios: { back: [-25, 0], front: [20, 0] }, ipad: { back: [-30, 0], front: [30, -120] } },
    // QA r3, iPad: the front (Speaking) device showed only the fox; its reply card (y 2105-2505)
    // and Interrupt (2550-2640) sat below the canvas. It drops the empty black above the fox
    // (y 200-960) and the haze under it (1840-2090). The back (Listening) device's full-width
    // transcript (y 2155-2350) ran under the front bezel mid-word: it shows the fox (1000-1830),
    // then the "please" pill and mic (2360-2650), which clear the bezel; 09 shows the transcript.
    // QA r4, iPhone: the back (Listening) device's full-width transcript (y 1610-1978) and its
    // "please" pill (2009-2100) ran under the front bezel mid-word ("everything you rememb"). Like
    // the iPad: the back screen keeps the status bar, the close button and the fox (to y 1600),
    // then the mic (2160-2460) drawn just under the fox; 09 shows the transcript and the pill.
    // The front (Speaking) screen stays whole.
    pairFocus: {
      ios: [{ w: 1206, fill: "#000", bands: [[0, 1600, 0], [2160, 300, 1680]] }],
      ipad: [
        { w: 2064, fill: "#000", bands: [[0, 200, 0], [1000, 830, 760], [2360, 290, 1620]] },
        // QA r4: ends at y 2540 under the reply card; Interrupt (2550-2640) only poked in as a sliver.
        { w: 2064, fill: "#000", bands: [[0, 200, 0], [960, 880, 760], [2090, 450, 1660]] },
      ],
    },
    billboard: true,
    h1px: 192,
  },
  // QA r2: the iPad's picker sat small in the bottom third: lift the cards. The wireframe
  // fox in the gaps between cards is painted out (PLATE_MASKS); its blur behind the glass stays.
  // 1.2.1 recapture: four cards (Mini, Lil, Home, Private Cloud Compute), x 553-1511,
  // y 1005-1895 on the iPad. The crop is the cards edge to edge (the fox's head and tail sit
  // outside it), drawn 1000 wide so the taller stack stays under the sub.
  {
    id: "04_pick-a-brain",
    layout: "top",
    plate: "onboarding",
    // QA r3: the 1000-wide stack was clamped up under the canvas, so the source PCC card showed
    // again below it and the status bar peeked over its corners; and the Simulator's PCC card reads
    // "unavailable", its glass showing the fox's legs through its text. The iPad screen now starts
    // at y 700 (the empty gradient; status bar out), drops the PCC card (1668-1900) like a filtered
    // list and keeps "Private by design"; the lift is Mini, Lil and Home (y 1005-1668), centred on
    // its source unclamped. (QA r5: IPAD_04_SUB now names only the device and the Mac.)
    // iPhone: the empty gradient between the status bar and the wordmark (y 200-400) is dropped so
    // the "Private by design" line shows whole above the canvas edge, not sliced.
    // QA r4: "Private by design" landed under the ~1.9× lift and never showed, the resize grip
    // floated mid-screen, and three cards sat under a sub naming four homes. The fourth card is
    // back as shot, unlifted, below the lift: "Private Cloud Compute · unavailable" (the fox's
    // legs through its dimmed glass, as the app draws it) backs "where available", then the
    // lock line. The band ends at y 2010, above the grip.
    focus: {
      ios: { w: 1206, fill: "#000", bands: [[0, 200, 0], [400, 2222, 200]] },
      // QA r5: the Simulator's PCC card reads "unavailable". The iPad screen ends at the Home
      // card (y 1668): PCC and the lock line under it are out, and IPAD_04_SUB names only the
      // device and the Mac. The r4 second band (PCC as shot + "Private by design") is retired.
      ipad: { w: 2064, fill: "#000", bands: [[700, 968, 0]] },
    },
    lifts: { ipad: [{ crop: [553, 1005, 958, 663], w: 1000, anchor: true }] },
  },
  // QA r6 (2026-10-23): the bare Documents list is retired on iPhone/iPad. The plate is a real
  // grounded turn (1.2.1 + #670, Mini answering from the seeded notes): "what do my lair notes say
  // about the roofline?", the answer, the action row, then the source chip "Lair — planning notes"
  // and "Used knowledge search". documents.png stays on disk; the Mac 05 frame is unchanged.
  // The lift is the whole turn, question to "Used knowledge search", anchored over its source, the
  // answer whole and unedited. iPhone: question x 291-1109 / y 432-619, answer x 96-1106 / y
  // 667-1110, actions + chips x 100-800 / y 1111-1415 (24 px margin round the block). The fox
  // lattice behind the action row and chip is keyed out (PLATE_MASKS). iPad: question x 993-1727 /
  // y 228-309, answer x 336-802 / y 341-414, actions 458-490, chips x 338-631 / y 542-614; its fox
  // sits 400 rows lower, clear of the turn.
  {
    id: "05_notes-pdfs",
    layout: "top",
    plate: "ask-documents",
    // The lift is drawn ~1.3× its source, so its top edge sliced the toolbar buttons (compose,
    // voice, settings: iPhone y 186-317, iPad 46-151) into half-icons. The toolbar rows are
    // banded out (the screen's own black in their place), the status bar and the turn stay
    // where the app put them; the lifts map through band 1.
    focus: {
      ios: { w: 1206, fill: "#000", bands: [[0, 125, 0], [330, 2292, 330]] },
      ipad: { w: 2064, fill: "#000", bands: [[0, 44, 0], [165, 2587, 165]] },
    },
    lifts: {
      ios: [{ crop: [72, 408, 1062, 1032], w: 1240, anchor: { img: 1 } }],
      ipad: [{ crop: [312, 204, 1440, 434], w: 1240, anchor: { img: 1 } }],
    },
  },
  // 1.2.1 recapture: no row names a firm any more, so the iPhone band is retired (its screen
  // shows rows 1-7, none naming anyone). The iPad screen reaches row 12, "Niamh Cullen draws
  // the plans…", a person's full name (DemoPersona drops the surname since 2026-11-25; the band
  // stays until the iPad recapture): its band drops that row (y 1716-1849, rows are 134 px
  // apart from the card top at 242) like a filtered list. The iPad lift is rows 1-3 (y 242-644).
  {
    id: "06_memories",
    layout: "top",
    plate: "memories",
    focus: {
      // QA r4, iPhone: the canvas edge sliced row 6's date line. The screen drops the empty black
      // between the title and the card (y 300-450), so row 6 and its separator (y 2310) end ~150
      // rows higher, and the empty card padding under that separator (y 2313-2368, no text) runs on
      // to the canvas edge, repeated, instead of row 7 under the search pill.
      ios: {
        w: 1206,
        fill: "#000",
        bands: [[0, 300, 0], [450, 1918, 300], [2313, 55, 2218], [2313, 55, 2273], [2313, 55, 2328], [2313, 55, 2383], [2313, 55, 2438]],
      },
      // QA r3: the lift (rows 1-3) is drawn a little larger than its source and its bottom edge
      // sliced row 4 through its glyphs: row 4 (y 645-779) is dropped too, so the overhang lands
      // in row 5's top padding. QA r4: the lift's shadow still dimmed row 5: 30 rows of black more.
      ipad: { w: 2064, bands: [[0, 645, 0], [779, 938, 675], [1850, 902, 1613]] },
    },
    lifts: { ipad: [{ crop: [30, 236, 2010, 410], w: 1200, anchor: { dy: -14 } }] },
  },
  // QA r2: a centred cover-crop sliced the iPhone status bar in half.
  // 1.2.1 recapture: the creatures sit lower and smaller. iPhone union x 170-844, y 866-1790,
  // "Listening…" at 1812-1950 (x 400-800, right of a crop that must keep the fox's nose at 170),
  // hint pill 1985-2075. A plain crop put the RTL (ar-SA) label on top of "Listening…", so the
  // iPhone tile is one band, x 150-850 / y 470-1805 (every creature, ≈1.7× the old full-width
  // tile, no close button or status bar), with the plate's black below it for the label.
  // iPad union x 292-1448, y 794-2138: tiles crop 1400 wide from (170, 780); its pill is below.
  {
    id: "07_companion",
    layout: "top-grid",
    // QA r3: the fox's tail sat 4u off the tile edge, the Inkfish's tentacles were cut flat at
    // the band's end and the iPad tiles were unbalanced (the Inkfish touching both edges, the
    // fox small). Each creature now has its own crop: iPhone bands 740 wide centred on the
    // creature (fox x 172-842, gecko 396-776, inkfish 282-818, colobus 350-796), ending at y 1812
    // (the pill starts at 1813) with the last 60 rows faded; iPad crops centred on each union
    // (fox x 294-1374 / y 945-1803, gecko 429-1446 / 1182-1614, inkfish 600-1362 / 795-2136,
    // colobus 627-1359 / 948-1884), the Inkfish wider so it has headroom.
    tileFocus: { ios: { x: 137, w: 740, fill: "#000", bands: [[470, 1342, 0, 60]] }, ipad: [209, 790, 1250] },
    tilePlateFocus: {
      ios: {
        // QA r4: the gecko (x 396-774, y 1212-1450) read half the size of its neighbours in a
        // 740-wide window: 560 wide, centred on it, the band ending at the pill (1812).
        "companion-gecko": { x: 305, w: 560, fill: "#000", bands: [[690, 1122, 0, 60]] },
        "companion-inkfish": { x: 180, w: 740, fill: "#000", bands: [[470, 1342, 0, 60]] },
        "companion-colobus": { x: 203, w: 740, fill: "#000", bands: [[470, 1342, 0, 60]] },
      },
      ipad: {
        "companion-gecko": [312, 814, 1250],
        // QA r4: the tile reached y≈2295, past the "Listening…" pill (y 2239), and the tentacle tip
        // touched the label. An explicit window, rows 730-2230 (head 795, tentacles end 2136, the
        // pill below it), 100 px further right than r3.
        "companion-inkfish": [116, 730, 1530, 1500, "#000"],
        "companion-colobus": [368, 832, 1250],
      },
    },
    plates: [
      "companion-fox",
      "companion-gecko",
      "companion-inkfish",
      "companion-colobus",
    ],
  },
  // The Settings plates carry "Web search in chat" switched ON ("the only thing that sends
  // your conversation to the internet"), right under "Nothing phones home" (QA 2026-10-22),
  // and the iPad's opens on the Face picker. Both start the screen below Grounding: Appearance,
  // Reading, About, "Everything runs on your device." Recapture with web search OFF to show more.
  // QA r2: that crop showed About → "Version 1.0.0 (1)" (1.2.1 ships) and started mid-scroll with
  // "Reading" under the Dynamic Island. The screen is now the status bar + Settings nav bar over
  // Appearance and Reading, as the list reads scrolled there; About (and the iPad's spinner) is out.
  {
    id: "08_data-not-collected",
    layout: "stat",
    plate: "privacy-label",
    // QA r5 (1.2.1 plates, 09:41): the screen is the privacy subject, Content Controls (Declared
    // Age Range) and Grounding (the web search switch and its footer naming DuckDuckGo and PCC),
    // on black like a list scrolled there. The status + nav bars are out (their glass carries
    // blurred list ghosts; the r3/r4 nav-bar masks are retired with the September plates), and so
    // are Voice, Appearance and Reading. iPhone: header y 835, footer ends 1989. iPad: header 1061,
    // Grounding footer ends 1677, then Answer ratings (header 2312, card 2367-2678, footer
    // "They stay on this device unless you export them." 2701-2724).
    focus: {
      ios: { w: 1206, fill: "#000", bands: [[800, 1210, 170]] },
      // iPad: the whole Answer ratings section ran off the canvas (≈880 plate rows show). Its header
      // and its footer show, the card's three rows dropped like a filtered list.
      ipad: { w: 2064, fill: "#000", bands: [[1040, 650, 40], [2290, 62, 690], [2690, 45, 759]] },
    },
  },
  // The claim is the plate's own hint ("End with "please" and M1K3 will take its turn"),
  // which is faint grey in the capture: lift the caption + hint lines.
  // 1.2.1 recapture: iPhone caption card x 115-1091, y 1610-1978, hint pill y 2010-2092: lift
  // both. iPad: the caption is one 1860-px-wide card (y 2154-2349) a lift can't enlarge, so the
  // lift is the hint pill alone (x 768-1296, y 2370-2430), ~3.5× its on-screen size.
  {
    id: "09_hands-free",
    layout: "top",
    plate: "voice-listening",
    targets: ["ios", "ipad"],
    // The device bleeds off the canvas (≈2190 plate rows show on iPhone, ≈1680 on iPad), so the
    // pill sat below the fold and its clamped lift slid over the fox's legs. The screen drops
    // the empty black between the close button and the fox (iPhone y 380-1000, iPad y 200-900,
    // both measured empty) and, on iPad, the empty haze under the fox (y 1860-2140): every band
    // is the app's own pixels, in order, at one scale. The lifts anchor over their band (img).
  // iPad: the pill sits 20 px under a full-width caption card, so its lift is 700 wide (≈2.5×)
  // and nudged 14u down to clear the caption (QA r4).
    focus: {
      ios: { w: 1206, fill: "#000", bands: [[0, 380, 0], [1000, 1622, 380]] },
      ipad: { w: 2064, fill: "#000", bands: [[0, 200, 0], [900, 960, 200], [2140, 300, 1160]] },
    },
    lifts: {
      // QA r3: the iPhone card+pill lift grew over the fox's feet (y 1576) and the mic (2184),
      // and magnified the app's truncated transcript ("…whether any of it h…"). Both targets now
      // lift the claim alone, the hint pill (iPhone x 184-1021 / y 2009-2099, iPad 753-1311 /
      // 2370-2430), bare (its own outline is the edge), nudged down clear of the caption card.
      ios: [{ crop: [176, 2001, 853, 107], w: 1040, bare: true, anchor: { img: 1, dy: -28 } }],
      // QA r4: dy 0 left the pill's halo on the caption card's bottom edge. 14u down clears it and
      // still covers the source pill (at 30u its top edge peeked out above the lift).
      ipad: [{ crop: [745, 2362, 574, 77], w: 700, bare: true, anchor: { img: 2, dy: 14 } }],
    },
  },
  // Every claim is the app's own text (the sheet's "Codes expire after about a minute",
  // the Mac caption's "local network only, encrypted"). Weakest slot: it reuses the duo's
  // phone plate; swap in a fresh capture (Lil reading an image) when one exists.
  // QA 2026-10-22: "One scan." sat over the paste-link fallback. The sheet's own first line
  // says it ("…Pair a Device. Then scan the code it shows."): lift it, which also sets 10
  // apart from the duo's phone. iPad's line is one 2000-px strip that a lift can't enlarge.
  // QA r2: so the iPad set drops 10 (nine frames; the duo already shows its pairing sheet)
  // until there is an iPad capture of the scanner or the Mac's QR.
  {
    id: "10_pairing",
    layout: "top",
    plate: "brain-at-home",
    // QA r5 (1.2.1 plate, 09:41): the status bar stays. The Simulator has no camera, so the sheet
    // shows "No camera? Paste the link" and the paste card (y 860-1270) under "One scan.": that
    // section is dropped like a filtered list, and the sheet's "Codes expire after about a minute."
    // (1296-1331) follows the instruction card. The lift is that card alone (x 48-1157, y 504-777),
    // bare, rounded to its own corner (≈94 plate px), anchored over its band.
    focus: { ios: { w: 1206, fill: "#000", bands: [[0, 830, 0], [1280, 70, 830]] } },
    targets: ["ios"],
    lifts: { ios: [{ crop: [47, 503, 1112, 276], w: 1200, bare: true, radius: 94, anchor: true }] },
  },
];

const LANDSCAPE = [
  // 2026-11-24 (Kev, 1.6): NO lifts on the Mac. The 09-23 redesign floated a zoomed copy of each
  // frame's moment over the laptop; Kev: "removing the overlayed elements as they look poor".
  // The laptop and the type carry each frame now. Portrait lifts are unchanged.
  {
    id: "01_hero",
    layout: "edge",
    plate: "chat",
    focus: "50% 0%",
    scrim: "bottom-left",
    hero: true,
    billboard: true,
    // QA r2: placed at the bottom, the exchange showed twice (its source stays on the screen).
  },
  // Replaces the Mac 06_brain-at-home split. Same plate flags as the portrait duo; the
  // column h1 runs at .9 (144) so the 18-char tagline line doesn't wrap into a 4th.
  {
    id: "02_your-devices",
    layout: "duo",
    mac: "brain-at-home",
    phone: "brain-at-home",
    macFocus: "50% 0%",
    billboard: true,
    h1px: 144,
  },
  {
    id: "03_voice",
    layout: "edge",
    plate: "voice-speaking",
    focus: "50% 50%",
    scrim: "bottom-left",
    billboard: true,
    // The caption card alone (no half bubble, no fox legs), anchored over itself and nudged
    // up so it also covers the "I am Mike." / "I live entirely…" bubbles above it. 2026-11-25:
    // the whole window on the laptop, a burst frame mid-sentence; the ghost marquee did not recur.
  },
  {
    id: "04_pick-a-brain",
    layout: "split",
    // The real brain picker (Mini, Lil, Big), not onboarding (Kev, 2026-11-24): the onboarding
    // plate launched at the brain step (`-onboarding.startAtBrain YES`, capture-direct.sh).
    plate: "brain-picker",
    focus: "50% 0%",
  },
  {
    id: "05_notes-pdfs",
    layout: "split",
    // 2026-11-25: a real grounded turn (the ask-documents plate, Mac lane since 11-25): the question,
    // the answer from the lair notes and its source chip, whole window. Was the Documents list
    // zoomed 1.9× onto an empty window (Kev: "stretched").
    plate: "ask-documents",
    focus: "50% 0%",
  },
  {
    id: "06_memories",
    layout: "edge",
    plate: "memories",
    scrim: "bottom-left",
    // 2026-11-25: the whole Memories window, as captured (the old bands dropped two rows). A row the
    // frame must not show is fixed in DemoPersona.memories, not cut out of the plate.
    focus: "50% 0%",
  },
  // The memory field in its own window (Kev, 2026-09-15). v1's "05b", renamed "06b" so it
  // sorts right after 06_memories ('_' < 'b'). Shot at 1280×748 pt content since 2026-11-25 (it was a
  // 1280×1024 px plate blown up 2.2×); its title bar makes it 2560×1560, so the laptop trims ~2.5%.
  {
    id: "06b_constellation",
    layout: "edge",
    plate: "constellation",
    focus: "50% 50%",
    scrim: "bottom-left",
    targets: ["mac"],
  },
  {
    id: "07_companion",
    layout: "grid",
    plates: [
      "companion-fox",
      "companion-gecko",
      "companion-inkfish",
      "companion-colobus",
    ],
  },
  {
    id: "08_data-not-collected",
    layout: "stat",
    plate: "privacy-label",
    // 2026-11-25: Settings ▸ Privacy whole, at the shipped defaults (PCC off, Context senses off),
    // as a new owner sees it. Was two stitched bands at 1.4× (Kev: "cropping oddly").
    focus: "50% 0%",
  },
  // The claim is the Scripts section's own caption ("only the exact approved bytes ever run").
  // 2026-11-25: the agent-scripts plate (Settings ▸ Privacy scrolled to the scripts by the harness;
  // the brain-at-home plate stopped showing them when Settings grew panes). Since 11-25 the whole
  // window: the Context switches above the scripts launch at their shipped OFF (the recipe).
  {
    id: "09_you-approve",
    layout: "split",
    plate: "agent-scripts",
    focus: "50% 0%",
    targets: ["mac"],
  },
];

// What each plate should be a capture OF. This doubles as the capture shot list.
const PLATE_BRIEF = {
  chat: "Chat screen mid-conversation. A real, useful exchange (not 'hello'). Status line showing the brain + '0 network calls' if visible. Airplane mode ON in the status bar is worth a thousand words.",
  onboarding:
    "First-run 'Pick a brain.' screen with the lock line 'Everything runs on your device' and the three tiers visible.",
  "brain-picker":
    "Mac: the brain picker (Settings → Change brain…) with Mini, Lil and Big and their sizes. Captured by capture-direct.sh as the onboarding plate at the brain step.",
  "voice-listening":
    "Voice mode while listening — the avatar/waveform reacting to speech.",
  "voice-speaking":
    "Voice mode while speaking — karaoke captions mid-sentence.",
  documents:
    "Documents screen with a few real-looking (but not personal) PDFs/notes imported, ideally one answer grounded in them.",
  memories:
    "Memories screen — a handful of dated, believable memories. Nothing personal to you.",
  constellation:
    "The Memory Constellation window (Window ▸ Memory Constellation) over the same seeded memories — the 3D field, settled, motes and threads visible. Mac lane.",
  "brain-at-home":
    "Brain at Home pairing/connected state — the QR pairing sheet or the 'connected to <Mac>' state. Mac: Settings ▸ Privacy, with 'Serve my brain to my devices' ON (the 2026-10 plate has it OFF).",
  "companion-fox": "Companion picker / avatar surface showing the Fox.",
  "companion-gecko": "Same, Gecko.",
  "companion-inkfish": "Same, Inkfish.",
  "companion-colobus": "Same, Colobus.",
  "privacy-label":
    "The App Store privacy card for M1K3 ('Data Not Collected') — capture from the live listing once it's up, or from App Store Connect's preview. Until then, Settings → Privacy in-app.",
};

module.exports = { PORTRAIT, LANDSCAPE, PLATE_BRIEF, PLATE_MASKS };
