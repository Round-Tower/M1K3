# Resolution Center reply — 2026-09-23 (Mac 1.0.0)

Answers three items: 5.2.5 (Mac in fr/pt subtitles), 2.1 screen recording, 2.1 Calendar/Location alerts.
Paste everything under the line.

---

Hello, and thank you for the detailed questions.

GUIDELINE 5.2.5: "Mac" in the French and Portuguese metadata
We removed it. The fr-FR subtitle is now "Intelligence punk, en local" and the pt-BR subtitle is "Inteligência punk, no aparelho". The app name in every locale is "M1K3" followed by a translation of "Local AI Agent", with no Apple product names.

GUIDELINE 2.1: screen recording
• Features: only one, optional call recording. The user starts a recording and affirms they have consent to record. M1K3 records two audio channels, the microphone and the Mac's audio output (the other side of the call), so the transcript can tell the speakers apart. In this build, macOS provides that system audio only through ScreenCaptureKit, which is why the Screen Recording permission appears.
• Data collected: audio only. The stream is configured to deliver audio (capturesAudio = true). The video track is set to the 2×2-pixel, 1 fps minimum and every video frame is discarded unread. No screen image is ever saved, shown, or analysed.
• Purpose: to transcribe and summarise that call on the user's Mac (WhisperKit and the on-device model). No other use.
• Third parties: none. The audio and the transcript never leave the Mac. M1K3 has no server, account, analytics, or telemetry.
• Storage: the audio file is written inside the app's sandbox container and deleted once it has been transcribed. The transcript and summary are stored in an encrypted database (key in the user's Keychain), and the user can delete any call from the Calls list.
• Privacy policy: https://m1k3.app/privacy#call-recording, section "Which macOS permissions does M1K3 ask for, and why?", which says:
  "It captures audio only: M1K3 never captures, records, or stores what is on your screen. The audio is used for one purpose, to transcribe and summarise that call on your Mac with WhisperKit and the on-device brain. It is never sent to Round Tower, Apple, or any third party. The recording is written to the app's sandbox container, kept only until it has been transcribed, and then deleted; the transcript and summary are stored encrypted at rest, and you can delete any call from the Calls list. If you decline the permission, M1K3 records your microphone only."
• Next build: your question showed us that Screen Recording was the wrong permission for this. We have moved the capture to a Core Audio process tap, which uses only the "System Audio Recording" permission (NSAudioCaptureUsageDescription) and never touches the screen. Our next build will not request Screen Recording at all.

GUIDELINE 2.1: Calendar and Location alerts
Yes, that is expected in this build. Calendar and Location are optional context features and are OFF by default, so the app requests nothing at launch. In this build, macOS shows its alert the first time M1K3 actually reads the data, not when the switch is turned on. To see both alerts:
1. Open Settings (⌘,) > Privacy > Context.
2. Switch Calendar on, then in the chat ask: "What's on my calendar today?" The Calendars alert appears.
3. Switch Location on, then ask: "Where am I right now?" The Location Services alert appears.
We agree the alert should appear as soon as the switch is turned on. Our next build does that, and turns the switch back off if permission is declined.

Thank you. We're happy to provide anything else you need.
