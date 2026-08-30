# 0003. OKF is an export format, not the memory model

Date: 2026-08-30
Status: ACCEPTED
Deciders: Kev + claude-opus-5

## Context

Google Cloud published the **Open Knowledge Format** (OKF) on 2026-06-12 —
announced on the Cloud blog, specified and reference-implemented under
`GoogleCloudPlatform/knowledge-catalog`. Kev asked whether M1K3 should
integrate it.

What OKF actually is, stripped of the announcement:

- **A directory of markdown files with YAML frontmatter.** No runtime, no SDK,
  no service, no compression.
- **One required field: `type`.** `title`, `description`, `resource`, `tags`,
  `timestamp` are standardised but optional. What types exist and what they
  mean is left to the producer.
- **The graph is markdown links.** `[customers](/tables/customers.md)`. There
  is no edge table, no typed relation vocabulary, no query language.
- **v0.1**, explicitly "a starting point, not a finished standard." Reference
  tools ship as "proofs of concept."
- The pitch is *"what's missing is a format, not another service"* — deliberate
  positioning against RDF/OWL heaviness on one side and proprietary catalogue
  SDKs on the other.

M1K3 already has a memory graph, and it is a different kind of object: atomic
facts as rows in SQLCipher, typed directed edges in `memory_edges`, traversal
by recursive CTE, vectors in `memory_embeddings`, supersession semantics,
FTS5, and a single encrypted file the user can point at and delete.

So the question is not "graph vs. graph." It is: **where, if anywhere, does a
plain-text interchange format belong in a product built on an encrypted local
store?**

## Decision

**Adopt OKF at the export boundary only. It never becomes the internal model,
and it is never a storage format for the user's memories at rest.**

Concretely: ship an `OKFExporter` over `MemoryStore` — each live memory
becomes one `.md` file with frontmatter (`type`, `title`, `timestamp`,
`tags`, `source`), each `MemoryEdge` becomes a markdown link in the body's
relations section, and the whole thing lands in a directory the user chose
from a save panel. Nothing else.

### Why export is the fit, and a good one

M1K3's promise is *"your data, and you can prove it never left."* The second
half of that promise has an unanswered corollary: **and you can take it with
you.** Today the honest answer to "how do I get my memories out?" is "it's a
SQLCipher file" — true, and useless to anyone who isn't us.

An OKF export answers it properly: human-readable, greppable, diffable,
git-committable, openable in any editor, and — because someone else published
the shape — legible to tools we did not write. The frontmatter/link structure
is a near-exact match for `Memory` + `MemoryEdge` already, so the serializer
is small.

That it is Google's format is, for this use, a *feature*: an export format's
whole job is to be read by something other than the thing that wrote it.

### Why it is never the internal model

Four reasons, any one of which is sufficient:

1. **It would break the core promise.** A directory of plaintext markdown
   containing the user's memories is exactly the artefact M1K3 exists not to
   produce. Backup daemons index it, cloud-sync folders swallow it, Spotlight
   reads it. The encrypted single file is not an implementation detail — it is
   the product.
2. **No query, no vectors.** Retrieval is hybrid FTS5 + `sqlite-vec` with RRF
   fusion. OKF has no embedding story at all and no query surface beyond
   walking files.
3. **No supersession.** `superseded_by` and the `supersedes` write path are how
   M1K3 corrects itself. OKF has `timestamp` and nothing else; a corrected
   fact and its correction are two files with no relationship between them.
4. **Typed edges degrade to untyped links.** `about-person`, `caused-by`,
   `part-of` all serialise to the same markdown link. Fine going out — the
   relation name can ride in the link text — but lossy coming back, and a
   round-trip that loses type is not a storage format.

### Why not ingest, yet

Reading OKF bundles as a corpus source is the *second*-best fit and a real
one: `DocumentIngester` could take the frontmatter as citation metadata
(`title` and `resource` are better citations than a filename) and the body as
chunk text. It was considered and deferred, not rejected — it earns its place
when a bundle exists that Kev actually wants ingested. Building an importer
for a format nobody has handed us yet is speculative work.

### Why not serve OKF over MCP

Because that is exporting the user's memories over a wire to a visiting agent,
which is the P2 scoped-tool-palette consent tier plus a security-audit gate,
same as every context tool. The format is not the hard part there and adopting
it does not move the gate.

### Containment

The exporter is a **serializer at the boundary** — a few hundred lines with no
dependency in the other direction. Nothing in `MemoryStore`, retrieval, or the
graph learns the word "OKF". If the format is abandoned — a live possibility
at v0.1, single-vendor, eleven weeks old — the cost of deletion is one file and
one menu item. That containment is the condition of adoption, not a nicety.

## Consequences

**Gained.** A concrete, demonstrable answer to data portability, in a shape
someone else maintains. It is the kind of thing that reads well in the pitch
precisely because it costs the user nothing to verify: export, open the folder,
read your own facts in a text editor.

**A second surface for the same content.** An export is plaintext by
definition, so the save panel is a consent moment, and the exported directory
is outside every guarantee M1K3 makes once it exists. The UI must say that in
one plain sentence rather than in a disclosure triangle.

**Bet size.** v0.1, one vendor, no adoption outside Google's own catalogue yet.
This ADR deliberately takes the smallest position that has value on its own:
the export is useful even if OKF never gets a second implementation, because
markdown-with-frontmatter is readable regardless of whose spec it satisfies.
We are buying the shape, not the ecosystem.

**Adjacent, not committed.** `graphify` already produces a wiki and a
`graph.json` for the codebase; that output is OKF-shaped too, and an emitter
there would make the *code* knowledge graph portable on the same rails. Noted,
not decided.

**Ordering.** The heartbeat's structural pulse tags (2026-08-30) use a
`tags:`-style flat string vocabulary. That was chosen on its own merits, but it
means a pulse export would already be OKF-shaped if it is ever wanted — tags
now, export later, no rework.
