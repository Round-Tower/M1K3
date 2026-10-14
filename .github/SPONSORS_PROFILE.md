# GitHub Sponsors: the Round-Tower profile (paste-ready)

`.github/FUNDING.yml` and the "SPONSOR ♥" link in every m1k3.app footer point at
`github.com/sponsors/Round-Tower`. The org has no Sponsors listing yet (GitHub API, 2026-10-14:
`hasSponsorsListing: false`), so that URL redirects to the org page. This file holds what goes
into the listing. The account steps (bank, tax, approval) are Kev's.

The copy keeps the house rules:

- **Free:** M1K3 is free for humans, forever. Sponsorship funds the work and never gates a
  feature (`FUNDING.yml`, README § License).
- **Licence:**
  - M1K3 is source-available under FSL-1.1-ALv2, and the copy never calls it open source.
  - MurphySig (Unlicense) and Púca (MIT) are Round Tower's open-source work.
- **Claims:** "No data centers required", never an unconditional "no cloud". Web search is on by
  default, and Private Cloud Compute is a brain you opt into.
- **Organisations:** those that want M1K3 on their own hardware license M1K3 for Teams.
  Sponsorship is support, not a licence.

## Kev's setup on github.com, in this order

1. Turn on two-factor authentication on the account that owns Round-Tower. GitHub requires it.
2. **Sign up.** Go to github.com/sponsors → **Get sponsored** → **Join the waitlist** next to
   Round-Tower.
   - Fill in the contact details.
   - Add the bank account: Round Tower Software Ltd's, in Ireland. The person setting it up must
     live in the bank's region.
   - Submit. GitHub may need to send an invitation before the rest opens.
3. **Profile.** In the Dashboard, open **Profile** and paste the short bio and introduction below.
   For featured work, add M1K3, murphysig and puca.
4. **Tiers.** In the Dashboard, open **Tiers** and create them from the table below. A published
   tier's price can't be edited; you'd have to retire it and make a new one. So settle the prices
   first.
5. **Stripe Connect.** In the Dashboard, open **Stripe Connect account**. Check the company
   details before you submit: GitHub says identity details are hard to change afterwards.
6. **Tax.** In the Dashboard, go to **Overview**, then tax forms, and file a **W-8BEN-E** for
   Round Tower Software Ltd. Use the registered legal name, matching the bank account.
7. **Request approval.**
   - GitHub says review "may take a few days".
   - The profile goes live on approval.
   - The site's links and the repo's Sponsor button then work by themselves.

GitHub's eligibility line reads "Any organization that contributes to an open source project".
If review asks, the honest answer has three parts:

- MurphySig and Púca are open source.
- M1K3's history before 2026-09-09 is Apache-2.0.
- Every M1K3 version becomes Apache-2.0 two years after release.

## Short bio

```text
Round Tower Software builds M1K3, a local AI agent for Mac, iPhone and iPad. Punk intelligence: no account, no telemetry, no data centers required.
```

## Introduction

```markdown
## Punk intelligence, on hardware you already own

M1K3 (friends call it Mike) is a local AI agent. Its brains, your memory and its voice run on your own Mac, iPhone or iPad: no account, no telemetry, no data centers required.

M1K3 is **free for humans, forever**. Its source is public under the Functional Source License (FSL-1.1-ALv2), and every version becomes Apache-2.0 two years after release. Sponsorship is optional: it funds the work and never gates a feature.

### What your sponsorship pays for

- Brains that feel fast on the devices you already own: evals, quantisation and speed work.
- A voice, a memory and vision that stay on your device.
- The local MCP server and `m1k3` command-line tool your coding agents use.
- Open tools along the way. [MurphySig](https://murphysig.dev) is the provenance convention M1K3's code is signed with. [Púca](https://github.com/Round-Tower/puca) is a white-hat security testing kit.

### Who we are

Round Tower Software Ltd is a small studio in Ireland. M1K3 is built in the open, human and AI together, with signed provenance on every change.

Running M1K3 for a team on your own hardware? That's [M1K3 for Teams](https://m1k3.app/teams).
```

## Tiers

The prices are Kev's call, and they're final once published. Turn custom amounts on, with a
minimum of US$1.

| Kind | Name | Price | Description |
|---|---|---|---|
| Monthly | The Lil | $3 | You help keep a local AI free for everyone. Thank you. |
| Monthly | The Big | $10 | You fund real work every month: a brain eval, a voice fix, a release. |
| Monthly | The Lair | $50 | For a company that runs on M1K3. Your name or logo goes on a sponsors line in M1K3's README, if you'd like it. |
| One-time | A pumpkin for the Fox | $5 | A seasonal thank-you. |
| One-time | A round for the lair | $25 | The Irish way to say thanks. |

Use this welcome message on every tier:

```text
Thank you. You're keeping a local AI free for everyone. — Kev and M1K3
```

For the goal, set 25 monthly sponsors, with this description:

```text
Twenty-five monthly sponsors keep M1K3's brains getting better every month, free for everyone.
```

<!--
Signed: Kev + claude-opus-5-5, 2026-10-14, Confidence 0.75
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: none (new).
Context: written when Kev asked to set up the Sponsors page that FUNDING.yml and the site footers already link to.
  - The setup steps follow GitHub's docs as read on 2026-10-14 ("Setting up GitHub Sponsors for your organization",
    "Managing your sponsorship tiers").
  - The licence facts come from the repos' LICENSE files: murphysig is Unlicense, puca is MIT, and M1K3 is
    FSL-1.1-ALv2 per its README.
Open:
  - The tier prices, The Lair's README line, the welcome message's signature and the goal are proposals for Kev.
  - If The Lair keeps its perk, M1K3's README owes a sponsors line.
-->
