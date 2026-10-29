// The A4 poster for Fig 2. Every number and line comes from the figure's caption and the repo it cites.
const station = (...names) => names.map((n) => `[data-station="${n}"]`).join(", ");

export default {
  page: "workshop-light.html",
  out: "workshop",
  reduced: true,
  views: {
    // The evals station after its run: every peg in, both score needles set.
    rest: { actions: [["key", "ArrowLeft"], ["wait", 6800]] },
  },

  name: "M1K3's workshop",
  title: "M1K3's workshop: a resident AI and the machine it keeps",
  number: "M1K3-002",
  tagline: "On-device AI for Mac",
  question: "What does it take for an AI to live on your machine?",
  lead: "M1K3 is a mechanic, and this is his shop: one bench, one machine. The brain runs with no cable plugged in, memory is filed here, everything that can leave goes through one wall, and a new brain wins question by question or not at all.",
  quote: "Just you and the machine",
  numbers: [
    ["0", "cables", "the brain needs to think"],
    ["3 → 1", "steps", "the agent loop when it runs hot"],
    ["0.95", "", "similarity at which a new fact merges"],
    ["+3 / −8", "", "MoE challenger vs 12B, paired"],
  ],
  spec: [
    ["Brain", "MLX, on this machine"],
    ["Weights", "Pinned revision, digests in the repo"],
    ["Cool Head", "Serious: 3 steps · critical: 1"],
    ["Memory", "FACT lines, dedupe at 0.95"],
    ["Egress", "Web (disclosed), Private Cloud (asked once)"],
    ["MCP", "127.0.0.1:4242, access token"],
    ["Evals", "Paired per question, wired like the app"],
  ],
  why: {
    title: "Why a mechanic?",
    text: "A mechanic talks about the machine he keeps running. M1K3 lives on one machine, respects its heat, and remembers who it works for.",
  },

  parts: [
    { id: "cable", name: "Network cable", say: "Coiled on its hook. The brain needs no connection.", select: station("cable") },
    { id: "engine", name: "Engine", say: "The brain, running on this machine's own chip.", select: station("engine") },
    { id: "cart", name: "Weights cartridge", say: "Loads only when its digest matches the one in the repo.", select: '[data-part="cart"]' },
    { id: "governor", name: "Governor and thermometer", say: "Cool Head reads the heat, caps the loop, keeps the brain.", select: station("governor", "thermo"), at: [362, 132] },
    { id: "crt", name: "Face", say: "The pixel face; its rolling band is the heartbeat.", select: station("crt") },
    { id: "still", name: "Still", say: "Distils a finished chat into FACT lines about you.", select: station("still") },
    { id: "cabinet", name: "Card cabinet", say: "Memory: a fact within 0.95 of a card merges, else it's filed.", select: station("cabinet") },
    { id: "tools", name: "Tool board", say: "What M1K3 can reach for. One tool is out on the job.", select: station("tools"), at: [316, 84] },
    { id: "web", name: "Web slot", say: "Searches leave here, counted and disclosed each turn.", select: station("web") },
    { id: "hatch", name: "Private Cloud hatch", say: "Opens only on your pick, and you're asked once.", select: station("hatch") },
    { id: "mcp", name: "MCP socket", say: "Port 4242 for your own apps, behind a token.", select: station("mcp") },
    { id: "dyno", name: "Twin dyno and pegboard", say: "One question tape, two brains; a peg per question won: 8 to 3.", select: station("dyno", "pegboard") },
  ],

  main: { view: "rest" },
};
