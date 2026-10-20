# Personal questions: Apple's tool pick, 2026-10-20

**Why.** Over MCP, "What did Kev decide about which brain fronts by default, and why?" was picked to
`lookup_fact` twice on build 538 (Lil). The dispatch prompt carries only the tool's output ("2003 in
music"), not the stored ruling, so Lil read the egress clause as the user's pick and answered "You
picked Private Cloud Compute".

**Setup.** `M1K3_AFM_EVAL=1 tools/dev/tdd.sh M1K3ChatTests MiniPersonalPick` (macOS 27, M1 Max).
This uses Apple's picker at temperature 0, one trial per question, chains on as the Mac ships
(`toolChain`, on when unset). Two palettes are tested. "mcp" is the MCP ask's 8 reads, as the live
log's prefix lists them. "chat" is the chat's reads, which add `recent_activity` and the device
tools. Each row shows master's `search_knowledge` menu line → this branch's →
after `ToolDispatch.corrected`.

| palette | master → branch → corrected | question |
|---|---|---|
| chat | web_search → search_knowledge → search_knowledge | What did Kev decide about which brain fronts by default, and why? |
| chat | recent_activity → search_knowledge → search_knowledge | What did I decide about the default brain, and why? |
| chat | list_documents → search_knowledge → search_knowledge | Which embedder did I pick for the iPad build? |
| chat | recent_activity+calendar_peek (unchanged) | What did we agree on for the launch date? |
| chat | recent_activity → search_knowledge → search_knowledge | What have I told you about my sister's wedding? |
| chat | recent_activity (unchanged) | Do you remember what I said about the trip to Kerry? |
| mcp | web_search → search_knowledge → search_knowledge | What did Kev decide about which brain fronts by default, and why? |
| mcp | search_knowledge (unchanged) | What did I decide about the default brain, and why? |
| mcp | search_knowledge (unchanged) | Which embedder did I pick for the iPad build? |
| mcp | calendar_peek → search_knowledge → search_knowledge | What did we agree on for the launch date? |
| mcp | search_knowledge (unchanged) | What have I told you about my sister's wedding? |
| mcp | search_knowledge (unchanged) | Do you remember what I said about the trip to Kerry? |
| both | lookup_fact (unchanged) | What did the Supreme Court decide in Roe v Wade? |
| both | web_search (unchanged) | Who won the All-Ireland hurling final this year? |
| both | web_search (unchanged) | Should I pick an iPhone or a Pixel? |
| both | lookup_fact (unchanged) | When was Cork founded? |

In an earlier unchained run, the chat palette picked lookup_fact for the hurling question, and `recencyCorrected` sent it to the web.

**Read.**
- The menu line does the work: five personal picks that went elsewhere now reach the store, the
  third-person repro included, and no world question moved.
- `personalCorrected` didn't need to fire here. It is the backstop for the live `lookup_fact`
  pick, which this harness doesn't reproduce. The live turn's question carried the MCP ask's
  context, and Apple's pick varies with it.
- Still open: `recent_activity` keeps "what did we agree" and "what I said about Kerry" in the chat
  palette. That reads this chat's history, not the store, and is a judgment call left out of this
  change.
