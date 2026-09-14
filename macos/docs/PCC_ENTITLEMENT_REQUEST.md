# Private Cloud Compute entitlement — request pack

**Owner:** Kev. Only the account holder can file this. **Status:** GRANTED 2026-09-14 (filed and assigned the same evening).

## What we need

The entitlement key is `com.apple.developer.private-cloud-compute`. It was
found in the macOS 27 dyld shared cache on 2026-09-13. Without it, a
`PrivateCloudComputeLanguageModel` generation fails with
`ModelManagerError 1046`, even though `availability` reports `available`
(ADR 0006, PR #317).

- **App:** M1K3, bundle ID `app.m1k3`, one universal App Store record
  (macOS + iOS + visionOS, ASC app id 6780230835), team `76DJH43A4P`.
- **Where to file (verified 2026-09-14):** the dedicated form at
  <https://developer.apple.com/contact/request/private-cloud-compute/>, linked as
  "Get the entitlement" from <https://developer.apple.com/private-cloud-compute/>.
  It is **not** in an identifier's Capability Requests tab (checked: the tab lists
  "Foundation Model Adapter", which is a different capability, and no PCC).
- **What the form asks for:** name, email and Team ID (account details), and
  one acknowledgment: every app must stay under 2 million first-time App Store
  downloads, and if any app goes over, PCC access is disabled within 6 months.
  There is no free-text field. The pitch below is kept for any follow-up from
  Apple, and for App Review notes.
- **Eligibility:** enrolled in the App Store Small Business Program, and under
  2 million first-time downloads per app. The grant is assigned to the
  *account* and shows up as a capability.

## Draft request text (for follow-up or App Review notes)

> **App:** M1K3 (`app.m1k3`), a private AI companion for Mac, iPhone and iPad
> that runs on device by default: Apple Foundation Models plus its own MLX
> models, with voice, document memory and a local knowledge graph.
>
> **Why Private Cloud Compute:** some requests exceed the on-device model's
> 4,096-token window, such as long documents, multi-step reasoning and image
> questions. Today those requests fail or get truncated. We want to offer PCC
> as an **opt-in**, per-request step up. It will never be the default, and it
> will never be used without the user's explicit action.
>
> **How it's used:**
> - Off by default, behind a dedicated consent setting.
> - Each escalation is a visible user action. Every PCC answer is labelled in
>   the conversation.
> - We show the user exactly what is sent (their message plus any documents
>   or memories they choose to attach).
> - We show quota usage and fall back to on-device on quota or network errors.
> - M1K3 has no servers of its own and does not log or store conversation
>   content anywhere off the device.
>
> **Why PCC and not a third-party cloud:** M1K3 is built on the privacy
> guarantees PCC provides. We would not send user conversations to any
> other cloud model.
>
> **Business:** Round Tower (Ireland), a small developer enrolled in the App
> Store Small Business Program. The app is free for individuals and licensed
> to organisations.

## Tracking

| Date | Event |
|------|-------|
| 2026-09-14 | Pack drafted |
| 2026-09-14 | Route verified: the contact/request/private-cloud-compute form |
| 2026-09-14 | Filed via the form |
| 2026-09-14 20:48 | Granted: "Access to models on Private Cloud Compute" assigned to the account |
| 2026-09-14 | Capability enabled on the `app.m1k3` identifier; profile carries the key = `true` (#333) |

When it's granted: add the key to both entitlement files through `project.yml`,
regenerate the profiles, and run `tools/ci/check_store_targets.py`. The first
probe is one content-free generation on the signed build. It should succeed
where the unentitled probe got 1046.

<!-- Signed: Kev + claude-opus-5, 2026-09-14. Confidence 0.7 (the key name is
     read from the shared cache; the filing route and Apple's review criteria
     are unverified). Prior: Unknown
     Review: Kev + claude-opus-5, 2026-09-14 (later): the filing route was verified in
     the portal (a dedicated form with one acknowledgment, not a Capability Requests
     row). Confidence now 0.85.
     Review: Kev + claude-opus-5, 2026-09-14 (night): granted the same evening; the
     capability is on app.m1k3 and the profile carries the key (#333). Confidence 0.9. -->
