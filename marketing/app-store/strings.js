// M1K3 — App Store screenshot copy, per locale (v2, 2026-10-22).
// frames.js decides layout + which plate; this file decides what it says.
// en-US is the v2 frame plan; the other eleven are the translators' captions, with
// link / labels / tiles / stat fields transcribed from their notes.
//
// Copy rules (from marketing/ios-launch/M1K3-iOS-Launch-Package.md §4.1):
//   • Apple OCRs screenshot text → every headline carries a real keyword
//     (private / offline / on-device / local / voice / notes / PDF).
//   • Dry and factual. The contrast with cloud AI does the work; no names.
//   • Never invent a number. "0 network calls" is what the app's own status
//     line prints; "Data Not Collected" is Apple's label for this app.
//   • The app UI and voice are English-only. Feature names (Brain at Home) and the
//     spoken word "please" stay English, and every non-English voice frame (03, 09)
//     says the voice is English — checked below, loudly.
//
// <dim>…</dim> renders the span in the brand grey (the "Nothing leaves." trick).
// <bdi>…</bdi> isolates a Latin run inside Arabic (ar-SA) so bidi can't reorder it.
// COPY holds every frame id (the Mac-only 06b / 09_you-approve included);
// MAC_OVERRIDES / IPAD_OVERRIDES merge over it for that target.

const LOCALES = ["en-US","en-GB","de-DE","es-ES","es-MX","fr-FR","ja","ko","pt-BR","zh-Hans","ru","ar-SA"];

const COPY = {
  "en-US": {
    "01_hero": {
      "eyebrow": "On-device AI · no account",
      "h1": "Local AI.<br>Works offline.<br><dim>Stays private.</dim>",
      "sub": "Chat, voice and memory. On your iPhone."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "Your AI.<br>Your devices.<br><dim>Private by design.</dim>",
      "sub": "Your iPhone borrows your Mac's brain. Over your own Wi-Fi, never the internet.",
      "link": "Your own Wi-Fi"
    },
    "03_voice": {
      "eyebrow": "Live voice · on-device",
      "h1": "Talk to it.<br><dim>It talks back.</dim>",
      "sub": "Speech in and out, on the iPhone.",
      "labelA": "Listening",
      "labelB": "Speaking"
    },
    "04_pick-a-brain": {
      "eyebrow": "Free · no account · no sign-up",
      "h1": "Pick a brain.<br><dim>Not a plan.</dim>",
      "sub": "On the device, on your Mac, or Apple's private cloud. Switch any time."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notes · PDFs · on-device",
      "h1": "Ask your<br>PDFs and notes.<br><dim>On your iPhone.</dim>",
      "sub": "Answers from your own files. Searched on the phone."
    },
    "06_memories": {
      "eyebrow": "Memory · on-device",
      "h1": "It remembers.<br><dim>You can read<br>every memory.</dim>",
      "sub": "See and search everything it keeps."
    },
    "07_companion": {
      "eyebrow": "Optional · 3D companion",
      "h1": "A companion,<br><dim>if you want one.</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "Private by design",
      "h1": "No account.<br>No tracking.<br><dim>Nothing phones home.</dim>",
      "sub": "Apple's label: Data Not Collected.",
      "big": "0",
      "bigUnit": "bytes collected by us.",
      "corner": "No data centers were harmed."
    },
    "09_hands-free": {
      "eyebrow": "Voice · hands-free",
      "h1": "Say \"please.\"<br><dim>It takes<br>its turn.</dim>",
      "sub": "Finish with \"please\" and it answers. Speech stays on the iPhone."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · pairing",
      "h1": "One scan.<br><dim>Encrypted.<br>Your Wi-Fi only.</dim>",
      "sub": "Pair with your Mac by QR code. Codes expire in about a minute."
    },
    "06b_constellation": {
      "eyebrow": "Memory · on-device",
      "h1": "Your memory,<br><dim>as a sky.</dim>",
      "sub": "Every mote is something you told it. All&nbsp;of&nbsp;it stays on this Mac."
    },
    "09_you-approve": {
      "eyebrow": "Agent scripts · on this Mac",
      "h1": "It proposes.<br><dim>You approve.</dim>",
      "sub": "Only the exact bytes you approved ever run."
    }
  },
  "en-GB": {
    "01_hero": {
      "eyebrow": "On-device AI · no account",
      "h1": "Local AI.<br>Works offline.<br><dim>Stays private.</dim>",
      "sub": "Chat, voice and memory. On your iPhone."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "Your AI.<br>Your devices.<br><dim>Private by design.</dim>",
      "sub": "Your iPhone borrows your Mac's brain. Over your own Wi-Fi, never the internet.",
      "link": "Your own Wi-Fi"
    },
    "03_voice": {
      "eyebrow": "Live voice · on-device",
      "h1": "Talk to it.<br><dim>It talks back.</dim>",
      "sub": "Speech in and out, on the iPhone.",
      "labelA": "Listening",
      "labelB": "Speaking"
    },
    "04_pick-a-brain": {
      "eyebrow": "Free · no account · no sign-up",
      "h1": "Pick a brain.<br><dim>Not a plan.</dim>",
      "sub": "On the device, on your Mac, or Apple's private cloud. Switch any time."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notes · PDFs · on-device",
      "h1": "Ask your<br>PDFs and notes.<br><dim>On your iPhone.</dim>",
      "sub": "Answers from your own files. Searched on the phone."
    },
    "06_memories": {
      "eyebrow": "Memory · on-device",
      "h1": "It remembers.<br><dim>You can read<br>every memory.</dim>",
      "sub": "See and search everything it keeps."
    },
    "07_companion": {
      "eyebrow": "Optional · 3D companion",
      "h1": "A companion,<br><dim>if you want one.</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "Private by design",
      "h1": "No account.<br>No tracking.<br><dim>Nothing phones home.</dim>",
      "sub": "Apple's label: Data Not Collected.",
      "big": "0",
      "bigUnit": "bytes collected by us.",
      "corner": "No data centres were harmed."
    },
    "09_hands-free": {
      "eyebrow": "Voice · hands-free",
      "h1": "Say \"please\".<br><dim>It takes<br>its turn.</dim>",
      "sub": "Finish with \"please\" and it answers. Speech stays on the iPhone."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · pairing",
      "h1": "One scan.<br><dim>Encrypted.<br>Your Wi-Fi only.</dim>",
      "sub": "Pair with your Mac by QR code. Codes expire in about a minute."
    },
    "06b_constellation": {
      "eyebrow": "Memory · on-device",
      "h1": "Your memory,<br><dim>as a sky.</dim>",
      "sub": "Every mote is something you told it. All&nbsp;of&nbsp;it stays on this Mac."
    },
    "09_you-approve": {
      "eyebrow": "Agent scripts · on this Mac",
      "h1": "It proposes.<br><dim>You approve.</dim>",
      "sub": "Only the exact bytes you approved ever run."
    }
  },
  "de-DE": {
    "01_hero": {
      "eyebrow": "KI auf dem Gerät · kein Konto",
      "h1": "Lokale KI.<br>Läuft offline.<br><dim>Bleibt privat.</dim>",
      "sub": "Chat, Stimme und Gedächtnis. Auf deinem iPhone."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "Deine KI.<br>Deine Geräte.<br><dim>Privat aus Prinzip.</dim>",
      "sub": "Dein iPhone leiht sich das Hirn deines Macs. Über dein eigenes WLAN, nie übers Internet.",
      "link": "Dein eigenes WLAN"
    },
    "03_voice": {
      "eyebrow": "Sprachmodus · Englisch · auf dem Gerät",
      "h1": "Du sprichst.<br><dim>M1K3 antwortet.</dim>",
      "sub": "Spracherkennung und Stimme, auf dem iPhone.",
      "labelA": "Hört zu",
      "labelB": "Spricht"
    },
    "04_pick-a-brain": {
      "eyebrow": "Kostenlos · kein Konto · keine Anmeldung",
      "h1": "Wähl ein Hirn.<br><dim>Kein Abo.</dim>",
      "sub": "Auf dem Gerät, auf deinem Mac oder in Apples privater Cloud. Jederzeit wechseln."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notizen · PDFs · auf dem Gerät",
      "h1": "Frag deine<br>PDFs & Notizen.<br><dim>Auf dem iPhone.</dim>",
      "sub": "Antworten aus deinen eigenen Dateien, durchsucht direkt auf dem iPhone."
    },
    "06_memories": {
      "eyebrow": "Gedächtnis · auf dem Gerät",
      "h1": "Mit Gedächtnis.<br><dim>Und du siehst<br>jede Erinnerung.</dim>",
      "sub": "Alles Gemerkte: sichtbar und durchsuchbar."
    },
    "07_companion": {
      "eyebrow": "Optional · 3D-Begleiter",
      "h1": "Ein Begleiter,<br><dim>wenn du magst.</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "Privat aus Prinzip",
      "h1": "Kein Konto.<br>Kein Tracking.<br><dim>Nichts funkt heim.</dim>",
      "sub": "App-Datenschutz: Keine Daten erfasst.",
      "big": "0",
      "bigUnit": "Bytes von uns erfasst.",
      "corner": "Keine Rechenzentren kamen zu Schaden."
    },
    "09_hands-free": {
      "eyebrow": "Sprachmodus · freihändig · Englisch",
      "h1": "Sag \"please\".<br><dim>Dann ist<br>M1K3 dran.</dim>",
      "sub": "Sag am Ende „please“, und M1K3 antwortet. Deine Stimme bleibt auf dem iPhone."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · Kopplung",
      "h1": "Ein Scan.<br><dim>Verschlüsselt.<br>Nur dein WLAN.</dim>",
      "sub": "Per QR-Code mit deinem Mac koppeln. Codes verfallen nach etwa einer Minute."
    },
    "06b_constellation": {
      "eyebrow": "Gedächtnis · auf dem Gerät",
      "h1": "Dein Gedächtnis<br><dim>als Sternbild.</dim>",
      "sub": "Jeder Lichtpunkt ist etwas, das du M1K3 erzählt hast. Alles bleibt auf diesem Mac."
    },
    "09_you-approve": {
      "eyebrow": "Agent-Skripte · auf diesem Mac",
      "h1": "M1K3 schlägt vor.<br><dim>Du gibst frei.</dim>",
      "sub": "Es laufen nur genau die Bytes, die du freigegeben hast."
    }
  },
  "es-ES": {
    "01_hero": {
      "eyebrow": "IA en el dispositivo · sin cuenta",
      "h1": "IA local<br>sin conexión.<br><dim>Y privada.</dim>",
      "sub": "Chat, voz y memoria. En tu iPhone."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "Tu IA.<br>Tus dispositivos.<br><dim>Privada por diseño.</dim>",
      "sub": "Tu iPhone usa el cerebro de tu Mac. Por tu propia wifi, nunca por internet.",
      "link": "Tu propia wifi"
    },
    "03_voice": {
      "eyebrow": "Voz en inglés · en el dispositivo",
      "h1": "Háblale.<br><dim>Te responde<br>en voz alta.</dim>",
      "sub": "Te escucha y te habla, en el iPhone.",
      "labelA": "Escuchando",
      "labelB": "Hablando"
    },
    "04_pick-a-brain": {
      "eyebrow": "Gratis · sin cuenta · sin registro",
      "h1": "Elige tu IA.<br><dim>No una tarifa.</dim>",
      "sub": "En el dispositivo, en tu Mac o en la nube privada de Apple. Cambia cuando quieras."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notas · PDF · en el dispositivo",
      "h1": "Pregunta a<br>tus PDF y notas.<br><dim>En tu iPhone.</dim>",
      "sub": "Respuestas de tus propios archivos. La búsqueda, en el iPhone."
    },
    "06_memories": {
      "eyebrow": "Memoria · en el dispositivo",
      "h1": "Tiene memoria.<br><dim>Y puedes leer<br>cada recuerdo.</dim>",
      "sub": "Mira y busca todo lo que guarda."
    },
    "07_companion": {
      "eyebrow": "Opcional · compañero 3D",
      "h1": "Un compañero,<br><dim>si te apetece.</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "Privado por diseño",
      "h1": "Sin cuenta.<br>Sin rastreo.<br><dim>Nada llama a casa.</dim>",
      "sub": "Etiqueta de Apple: Datos no recopilados.",
      "big": "0",
      "bigUnit": "bytes recopilados por nosotros.",
      "corner": "Ningún centro de datos resultó herido."
    },
    "09_hands-free": {
      "eyebrow": "Voz en inglés · manos libres",
      "h1": "Di \"please\".<br><dim>Y te contesta.</dim>",
      "sub": "Termina con \"please\" y te responde. Tu voz se queda en el iPhone."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · emparejamiento",
      "h1": "Un escaneo.<br><dim>Cifrado.<br>Solo tu wifi.</dim>",
      "sub": "Empareja con tu Mac por código QR. Los códigos caducan en un minuto, más o menos."
    },
    "06b_constellation": {
      "eyebrow": "Memoria · en el dispositivo",
      "h1": "Tu memoria,<br><dim>como un cielo.</dim>",
      "sub": "Cada destello es algo que le contaste. Todo se queda en este Mac."
    },
    "09_you-approve": {
      "eyebrow": "Scripts del agente · en este Mac",
      "h1": "Propone.<br><dim>Tú apruebas.</dim>",
      "sub": "Solo se ejecutan los bytes exactos que apruebas."
    }
  },
  "es-MX": {
    "01_hero": {
      "eyebrow": "IA en el dispositivo · sin cuenta",
      "h1": "IA local.<br>Sin internet.<br><dim>Y privada.</dim>",
      "sub": "Chat, voz y memoria. En tu iPhone."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "Tu IA.<br>Tus dispositivos.<br><dim>Privada por diseño.</dim>",
      "sub": "Tu iPhone toma prestado el cerebro de tu Mac. Por tu propia red Wi-Fi, nunca por internet.",
      "link": "Tu propia red Wi-Fi"
    },
    "03_voice": {
      "eyebrow": "Voz (inglés) · en el dispositivo",
      "h1": "Háblale.<br><dim>Te responde<br>en voz alta.</dim>",
      "sub": "Escucha y habla en inglés, en el iPhone.",
      "labelA": "Escuchando",
      "labelB": "Hablando"
    },
    "04_pick-a-brain": {
      "eyebrow": "Elige tu cerebro · sin cuenta · sin registro",
      "h1": "IA gratis.<br><dim>Sin suscripción.</dim>",
      "sub": "En el dispositivo, en tu Mac o en la nube privada de Apple. Cambia cuando quieras."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notas · PDF · en el dispositivo",
      "h1": "Consulta<br>tus PDF y notas.<br><dim>En tu iPhone.</dim>",
      "sub": "Respuestas con base en tus propios archivos. Se buscan en el celular."
    },
    "06_memories": {
      "eyebrow": "Memoria · en el dispositivo",
      "h1": "Tiene memoria.<br><dim>Puedes leer<br>cada recuerdo.</dim>",
      "sub": "Mira y busca todo lo que guarda."
    },
    "07_companion": {
      "eyebrow": "Opcional · compañero 3D",
      "h1": "Un compañero,<br><dim>si quieres uno.</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "Privada por diseño",
      "h1": "Sin cuenta.<br>Sin rastreo.<br><dim>Nada nos llega.</dim>",
      "sub": "Etiqueta de Apple: Datos no recopilados.",
      "big": "0",
      "bigUnit": "bytes recopilados por nosotros.",
      "corner": "Ningún centro de datos fue lastimado."
    },
    "09_hands-free": {
      "eyebrow": "Voz · manos libres",
      "h1": "Di \"please\"<br><dim>y te responde.</dim>",
      "sub": "Habla en inglés, termina con \"please\" y te responde. Tu voz no sale del iPhone."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · emparejamiento",
      "h1": "Un escaneo.<br><dim>Cifrado.<br>Solo tu Wi-Fi.</dim>",
      "sub": "Empareja con tu Mac mediante un código QR. Los códigos vencen en alrededor de un minuto."
    },
    "06b_constellation": {
      "eyebrow": "Memoria · en el dispositivo",
      "h1": "Tu memoria,<br><dim>como un cielo.</dim>",
      "sub": "Cada destello es algo que le contaste. Todo se queda en esta Mac."
    },
    "09_you-approve": {
      "eyebrow": "Scripts del agente · en esta Mac",
      "h1": "La IA propone.<br><dim>Tú apruebas.</dim>",
      "sub": "Solo se ejecutan los bytes exactos que aprobaste."
    }
  },
  "fr-FR": {
    "01_hero": {
      "eyebrow": "IA sur l’appareil · sans compte",
      "h1": "IA locale.<br>Hors ligne.<br><dim>Et privée.</dim>",
      "sub": "Conversation, voix et mémoire. Sur ton iPhone."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "Ton IA.<br>Tes appareils.<br><dim>Privée par design.</dim>",
      "sub": "Ton iPhone emprunte le cerveau de ton Mac. Via ton propre Wi-Fi, jamais par Internet.",
      "link": "Ton propre Wi-Fi"
    },
    "03_voice": {
      "eyebrow": "Voix en anglais · sur l’appareil",
      "h1": "Parle-lui.<br><dim>Il répond<br>à voix haute.</dim>",
      "sub": "Il t’écoute et te parle, sur l’iPhone.",
      "labelA": "Il écoute",
      "labelB": "Il parle"
    },
    "04_pick-a-brain": {
      "eyebrow": "Gratuit · sans compte · sans inscription",
      "h1": "Choisis<br>ton cerveau.<br><dim>Sans abonnement.</dim>",
      "sub": "Sur l’appareil, sur ton Mac ou dans le cloud privé d’Apple. Change quand tu veux."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notes · PDF · sur l’appareil",
      "h1": "Interroge<br>tes PDF et notes.<br><dim>Sur ton iPhone.</dim>",
      "sub": "Des réponses tirées de tes fichiers. La recherche reste sur le téléphone."
    },
    "06_memories": {
      "eyebrow": "Mémoire · sur l’appareil",
      "h1": "Il se souvient.<br><dim>Tu peux lire<br>chaque souvenir.</dim>",
      "sub": "Vois et cherche tout ce qu’il garde."
    },
    "07_companion": {
      "eyebrow": "En option · compagnon 3D",
      "h1": "Un compagnon,<br><dim>si ça te dit.</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "Privée par design",
      "h1": "Pas de compte.<br>Pas de suivi.<br><dim>Aucun mouchard.</dim>",
      "sub": "Étiquette Apple : Données non collectées.",
      "big": "0",
      "bigUnit": "octet collecté par nous.",
      "corner": "Aucun data center n’a été blessé."
    },
    "09_hands-free": {
      "eyebrow": "Voix en anglais · mains libres",
      "h1": "Dis \"please\".<br><dim>Il prend<br>la parole.</dim>",
      "sub": "Termine par \"please\" et il répond. Ta voix reste sur l’iPhone."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · appairage",
      "h1": "Un scan.<br><dim>Chiffré.<br>Réseau local.</dim>",
      "sub": "Associe ton Mac par QR code. Les codes expirent en une minute environ."
    },
    "06b_constellation": {
      "eyebrow": "Mémoire · sur l’appareil",
      "h1": "Ta mémoire,<br><dim>en ciel étoilé.</dim>",
      "sub": "Chaque point lumineux est une chose que tu lui as dite. Tout reste sur ce Mac."
    },
    "09_you-approve": {
      "eyebrow": "Scripts d’agent · sur ce Mac",
      "h1": "Il propose.<br><dim>Tu approuves.</dim>",
      "sub": "Seul ce que tu as approuvé, à l’octet près, s’exécute."
    }
  },
  "ja": {
    "01_hero": {
      "eyebrow": "オンデバイスAI · アカウント不要",
      "h1": "ローカルAI。<br>ネット不要。<br><dim>プライベート。</dim>",
      "sub": "チャット、音声、記憶。あなたのiPhoneで。"
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "あなたのAI。<br>あなたのデバイス。<br><dim>プライバシー重視。</dim>",
      "sub": "iPhoneがMacの頭脳を借りる。インターネットを通さず、自宅のWi-Fiで。",
      "link": "自宅のWi-Fi"
    },
    "03_voice": {
      "eyebrow": "ライブ音声 · オンデバイス（英語）",
      "h1": "話しかけて。<br><dim>音声で答える。</dim>",
      "sub": "聞くのも話すのも、iPhoneの中で。",
      "labelA": "聞いている",
      "labelB": "話している"
    },
    "04_pick-a-brain": {
      "eyebrow": "無料 · アカウント不要 · 登録不要",
      "h1": "選ぶのは頭脳。<br><dim>プランじゃない。</dim>",
      "sub": "この端末、Mac、またはAppleのプライベートクラウド。いつでも切り替えられる。"
    },
    "05_notes-pdfs": {
      "eyebrow": "メモ · PDF · オンデバイス",
      "h1": "PDFやメモに<br>質問できる。<br><dim>iPhoneの中で。</dim>",
      "sub": "答えは自分のファイルから。検索もiPhoneの中で。"
    },
    "06_memories": {
      "eyebrow": "記憶 · オンデバイス",
      "h1": "覚えている。<br><dim>記憶はすべて<br>読める。</dim>",
      "sub": "覚えたことは、すべて見て検索できる。"
    },
    "07_companion": {
      "eyebrow": "オプション · 3Dコンパニオン",
      "h1": "コンパニオン、<br><dim>お好みで。</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "プライバシー重視の設計",
      "h1": "アカウント不要。<br>追跡なし。<br><dim>開発元に送らない。</dim>",
      "sub": "Appleのラベル：データの収集なし。",
      "big": "0",
      "bigUnit": "バイト。私たちが集めるデータの量。",
      "corner": "データセンターは一切傷ついていません。"
    },
    "09_hands-free": {
      "eyebrow": "音声 · ハンズフリー（英語）",
      "h1": "「please」で<br><dim>返事の合図。</dim>",
      "sub": "最後に「please」と言えば答える。音声はiPhoneの中に留まる。"
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · ペアリング",
      "h1": "スキャン1回。<br><dim>暗号化。<br>自宅Wi-Fiだけ。</dim>",
      "sub": "QRコードでMacとペアリング。コードは約1分で失効する。"
    },
    "06b_constellation": {
      "eyebrow": "記憶 · オンデバイス",
      "h1": "あなたの記憶を、<br><dim>星空に。</dim>",
      "sub": "光の粒ひとつひとつが、あなたが話したこと。すべてこのMacの中に。"
    },
    "09_you-approve": {
      "eyebrow": "エージェントスクリプト · このMacで",
      "h1": "提案はAI。<br><dim>承認はあなた。</dim>",
      "sub": "実行されるのは、あなたが承認したとおりのコードだけ。1バイトも変えずに。"
    }
  },
  "ko": {
    "01_hero": {
      "eyebrow": "온디바이스 AI · 계정 없음",
      "h1": "로컬 AI.<br>오프라인 작동.<br><dim>비공개 그대로.</dim>",
      "sub": "채팅, 음성, 기억. 네 iPhone에서."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "너의 AI.<br>너의 기기.<br><dim>프라이버시 중심 설계.</dim>",
      "sub": "iPhone이 Mac의 두뇌를 빌려 써. 인터넷이 아닌, 집 Wi-Fi로만.",
      "link": "집 Wi-Fi"
    },
    "03_voice": {
      "eyebrow": "실시간 음성(영어) · 온디바이스",
      "h1": "말로 물어봐.<br><dim>음성으로 답해.</dim>",
      "sub": "듣고 말하는 것 모두 iPhone 안에서.",
      "labelA": "듣는 중",
      "labelB": "말하는 중"
    },
    "04_pick-a-brain": {
      "eyebrow": "무료 · 계정 없음 · 가입 없음",
      "h1": "두뇌를 골라.<br><dim>요금제 말고.</dim>",
      "sub": "이 기기, 네 Mac, 또는 Apple의 프라이빗 클라우드. 언제든 바꿔."
    },
    "05_notes-pdfs": {
      "eyebrow": "메모 · PDF · 온디바이스",
      "h1": "PDF와 메모에<br>물어봐.<br><dim>iPhone 안에서.</dim>",
      "sub": "네 파일에서 찾은 답. 검색도 폰 안에서."
    },
    "06_memories": {
      "eyebrow": "기억 · 온디바이스",
      "h1": "기억하는 AI.<br><dim>모든 기억을<br>직접 읽어 봐.</dim>",
      "sub": "기억한 건 전부 보고 검색할 수 있어."
    },
    "07_companion": {
      "eyebrow": "선택 사항 · 3D 컴패니언",
      "h1": "컴패니언,<br><dim>원한다면.</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "프라이버시 중심 설계",
      "h1": "계정 없음.<br>추적 없음.<br><dim>몰래 전송 없음.</dim>",
      "sub": "Apple 라벨: 데이터가 수집되지 않음.",
      "big": "0",
      "bigUnit": "우리가 수집하는 바이트.",
      "corner": "데이터 센터는 하나도 다치지 않았어."
    },
    "09_hands-free": {
      "eyebrow": "음성(영어) · 핸즈프리",
      "h1": "\"please\"라고<br>말해 봐.<br><dim>그럼 대답할게.</dim>",
      "sub": "끝에 \"please\"라고 하면 대답할게. 음성은 iPhone 안에 머물러."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · 페어링",
      "h1": "한 번 스캔.<br><dim>암호화.<br>집 Wi-Fi에서만.</dim>",
      "sub": "QR 코드로 Mac과 페어링해. 코드는 약 1분 뒤 만료돼."
    },
    "06b_constellation": {
      "eyebrow": "기억 · 온디바이스",
      "h1": "너의 기억이<br><dim>밤하늘이 돼.</dim>",
      "sub": "반짝이는 점 하나하나가 네가 말해 준 것. 전부 이 Mac에 남아."
    },
    "09_you-approve": {
      "eyebrow": "에이전트 스크립트 · 이 Mac에서",
      "h1": "제안은 AI가.<br><dim>승인은 네가.</dim>",
      "sub": "네가 승인한 바이트 그대로만 실행돼."
    }
  },
  "pt-BR": {
    "01_hero": {
      "eyebrow": "IA no aparelho · sem conta",
      "h1": "IA local.<br>Roda offline.<br><dim>E privada.</dim>",
      "sub": "Chat, voz e memória. No seu iPhone."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "Sua IA.<br>Seus aparelhos.<br><dim>Privada por design.</dim>",
      "sub": "Seu iPhone usa o cérebro do seu Mac. Pela sua rede Wi-Fi, nunca pela internet.",
      "link": "Sua rede Wi-Fi"
    },
    "03_voice": {
      "eyebrow": "Voz em inglês · no aparelho",
      "h1": "Fale com ele.<br><dim>Ele responde.</dim>",
      "sub": "Ouve e fala, no próprio iPhone.",
      "labelA": "Ouvindo",
      "labelB": "Falando"
    },
    "04_pick-a-brain": {
      "eyebrow": "Grátis · sem conta · sem cadastro",
      "h1": "Escolha<br>um cérebro.<br><dim>Não um plano.</dim>",
      "sub": "No aparelho, no seu Mac ou na nuvem privada da Apple. Troque quando quiser."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notas · PDFs · no aparelho",
      "h1": "Consulte seus<br>PDFs e notas.<br><dim>No seu iPhone.</dim>",
      "sub": "Respostas dos seus próprios arquivos. Buscadas no próprio celular."
    },
    "06_memories": {
      "eyebrow": "Memória · no aparelho",
      "h1": "Ele lembra.<br><dim>Você pode ler<br>cada memória.</dim>",
      "sub": "Veja e busque tudo o que ele guarda."
    },
    "07_companion": {
      "eyebrow": "Opcional · companheiro 3D",
      "h1": "Um mascote 3D,<br><dim>se você quiser.</dim>",
      "tiles": [
        "Fox",
        "Gecko",
        "Inkfish",
        "Colobus"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "Privacidade por design",
      "h1": "Sem conta.<br>Sem telemetria.<br><dim>Sem rastreamento.</dim>",
      "sub": "Rótulo da Apple: Dados não coletados.",
      "big": "0",
      "bigUnit": "bytes coletados por nós.",
      "corner": "Nenhum data center foi ferido."
    },
    "09_hands-free": {
      "eyebrow": "Voz em inglês · mãos livres",
      "h1": "Diga \"please\".<br><dim>E é a vez<br>dele falar.</dim>",
      "sub": "Termine com \"please\" (em inglês) e ele responde. Sua fala fica no iPhone."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · pareamento",
      "h1": "Um QR code.<br><dim>Criptografado.<br>Só no seu Wi-Fi.</dim>",
      "sub": "Pareie com seu Mac por QR code. Os códigos expiram em cerca de um minuto."
    },
    "06b_constellation": {
      "eyebrow": "Memória · no dispositivo",
      "h1": "Sua memória,<br><dim>como um céu.</dim>",
      "sub": "Cada pontinho é algo que você contou a ele. Tudo fica neste Mac."
    },
    "09_you-approve": {
      "eyebrow": "Scripts de agente · neste Mac",
      "h1": "Ele propõe.<br><dim>Você aprova.</dim>",
      "sub": "Só rodam os bytes exatos que você aprovou."
    }
  },
  "zh-Hans": {
    "01_hero": {
      "eyebrow": "端侧 AI · 无需账户",
      "h1": "本地 AI。<br>离线可用。<br><dim>始终私密。</dim>",
      "sub": "聊天、语音与记忆，就在你的 iPhone 上。"
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "你的 AI。<br>你的设备。<br><dim>天生私密。</dim>",
      "sub": "你的 iPhone 借用 Mac 的大脑。<br>走你自己的 Wi-Fi，绝不经过互联网。",
      "link": "你自己的 Wi-Fi"
    },
    "03_voice": {
      "eyebrow": "实时语音 · 设备端（英语）",
      "h1": "开口就聊。<br><dim>它会语音回话。</dim>",
      "sub": "语音输入与输出，都在 iPhone 上。",
      "labelA": "聆听中",
      "labelB": "说话中"
    },
    "04_pick-a-brain": {
      "eyebrow": "免费 · 无需账户 · 无需注册",
      "h1": "挑个大模型，<br><dim>不挑套餐。</dim>",
      "sub": "本机、你的 Mac 或 Apple 私有云，随时切换。"
    },
    "05_notes-pdfs": {
      "eyebrow": "笔记 · PDF · 设备端",
      "h1": "问问你的<br>PDF 和笔记。<br><dim>就在 iPhone 上。</dim>",
      "sub": "答案来自你自己的文件，搜索在手机上完成。"
    },
    "06_memories": {
      "eyebrow": "记忆 · 设备端",
      "h1": "它会记住。<br><dim>每条记忆<br>你都能看。</dim>",
      "sub": "它记下的一切，你都能查看和搜索。"
    },
    "07_companion": {
      "eyebrow": "可选 · 3D 伙伴",
      "h1": "一个伙伴，<br><dim>想要就有。</dim>",
      "tiles": [
        "狐狸",
        "壁虎",
        "墨鱼",
        "疣猴"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "天生私密",
      "h1": "无需账户。<br>没有追踪。<br><dim>从不回传。</dim>",
      "sub": "Apple 隐私标签：未收集数据。",
      "big": "0",
      "bigUnit": "字节：我们收集的全部数据。",
      "corner": "运行过程中没有数据中心受到伤害。"
    },
    "09_hands-free": {
      "eyebrow": "语音 · 免提（英语）",
      "h1": "说“please”，<br><dim>它就接话。</dim>",
      "sub": "以“please”结尾，它就会回答。语音留在 iPhone 上。"
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · 配对",
      "h1": "扫一下。<br><dim>加密传输。<br>只走你的 Wi-Fi。</dim>",
      "sub": "扫二维码与 Mac 配对。配对码约一分钟后失效。"
    },
    "06b_constellation": {
      "eyebrow": "记忆 · 设备端",
      "h1": "你的记忆，<br><dim>化作星空。</dim>",
      "sub": "每个光点都是你告诉过它的事。全部留在这台 Mac 上。"
    },
    "09_you-approve": {
      "eyebrow": "智能体脚本 · 在这台 Mac 上",
      "h1": "智能体提议。<br><dim>你来批准。</dim>",
      "sub": "只运行你批准过的原样内容，一个字节都不差。"
    }
  },
  "ru": {
    "01_hero": {
      "eyebrow": "ИИ на устройстве · без аккаунта",
      "h1": "Локальный ИИ.<br>Без интернета.<br><dim>Приватный.</dim>",
      "sub": "Чат, голос и память. На твоём iPhone."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone",
      "h1": "Твой ИИ.<br>Твои устройства.<br><dim>Приватный по замыслу.</dim>",
      "sub": "iPhone берёт взаймы мозг твоего Mac. Только по твоему Wi-Fi, не через интернет.",
      "link": "Твой Wi-Fi"
    },
    "03_voice": {
      "eyebrow": "Голос на устройстве · на английском",
      "h1": "Спроси голосом.<br><dim>Он ответит.</dim>",
      "sub": "Распознавание и синтез речи — прямо на iPhone.",
      "labelA": "Слушаю",
      "labelB": "Говорю"
    },
    "04_pick-a-brain": {
      "eyebrow": "Бесплатно · без аккаунта · без регистрации",
      "h1": "Выбери мозг.<br><dim>Не тариф.</dim>",
      "sub": "На устройстве, на твоём Mac или в частном облаке Apple. Меняй когда угодно."
    },
    "05_notes-pdfs": {
      "eyebrow": "Заметки · PDF · на устройстве",
      "h1": "Чат с PDF<br>и заметками.<br><dim>На iPhone.</dim>",
      "sub": "Ответы по твоим файлам. Поиск — прямо на телефоне."
    },
    "06_memories": {
      "eyebrow": "Память · на устройстве",
      "h1": "ИИ с памятью.<br><dim>Читай всё,<br>что он помнит.</dim>",
      "sub": "Смотри и ищи всё, что он сохранил."
    },
    "07_companion": {
      "eyebrow": "По желанию · 3D-компаньон",
      "h1": "Компаньон —<br><dim>если хочешь.</dim>",
      "tiles": [
        "Лис",
        "Геккон",
        "Каракатица",
        "Колобус"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "Приватность по замыслу",
      "h1": "Без аккаунта.<br>Без слежки.<br><dim>Без телеметрии.</dim>",
      "sub": "Метка Apple: «Данные не собираются».",
      "big": "0",
      "bigUnit": "байт собрано нами.",
      "corner": "Ни один дата-центр не пострадал."
    },
    "09_hands-free": {
      "eyebrow": "Голос на английском · без рук",
      "h1": "Скажи «please».<br><dim>Теперь<br>его ход.</dim>",
      "sub": "Закончи фразу словом «please» — и он ответит. Речь остаётся на iPhone."
    },
    "10_pairing": {
      "eyebrow": "Brain at Home · сопряжение",
      "h1": "Один скан.<br><dim>Шифрование.<br>Только твой Wi-Fi.</dim>",
      "sub": "Сопряжение с Mac по QR-коду. Код действует около минуты."
    },
    "06b_constellation": {
      "eyebrow": "Память · на устройстве",
      "h1": "Твоя память —<br><dim>звёздное небо.</dim>",
      "sub": "Каждая искорка — что-то из твоих рассказов. И всё остаётся на этом Mac."
    },
    "09_you-approve": {
      "eyebrow": "Скрипты агента · на этом Mac",
      "h1": "Он предлагает.<br><dim>Решаешь ты.</dim>",
      "sub": "Запускается только одобренное тобой — байт в байт."
    }
  },
  "ar-SA": {
    "01_hero": {
      "eyebrow": "ذكاء على الجهاز · بلا حساب",
      "h1": "ذكاء اصطناعي<br>بدون إنترنت.<br><dim>خاص ومحلي.</dim>",
      "sub": "دردشة وصوت وذاكرة. على <bdi>iPhone</bdi>."
    },
    "02_your-devices": {
      "eyebrow": "<bdi>Brain at Home</bdi> · <bdi>Mac</bdi> + <bdi>iPhone</bdi>",
      "h1": "ذكاؤك الاصطناعي.<br>أجهزتك.<br><dim>خصوصية بالتصميم.</dim>",
      "sub": "يستعير <bdi>iPhone</bdi> عقل جهاز <bdi>Mac</bdi>. عبر شبكة <bdi>Wi-Fi</bdi> الخاصة بك، لا&nbsp;عبر&nbsp;الإنترنت.",
      "link": "شبكة <bdi>Wi-Fi</bdi> لديك"
    },
    "03_voice": {
      "eyebrow": "صوت مباشر · على الجهاز · بالإنجليزية",
      "h1": "محادثة صوتية.<br><dim>ويرد بصوته.</dim>",
      "sub": "يسمع ويتكلّم، على <bdi>iPhone</bdi> نفسه.",
      "labelA": "يستمع",
      "labelB": "يتكلّم"
    },
    "04_pick-a-brain": {
      "eyebrow": "مجاني · بلا حساب · بلا تسجيل",
      "h1": "العقل باختيارك.<br><dim>لا اشتراك.</dim>",
      "sub": "على الجهاز، أو على جهاز <bdi>Mac</bdi>، أو في سحابة <bdi>Apple</bdi> الخاصة. والتبديل في أي وقت."
    },
    "05_notes-pdfs": {
      "eyebrow": "ملاحظات · <bdi>PDF</bdi> · على الجهاز",
      "h1": "إجابات من<br><bdi>PDF</bdi> وملاحظاتك.<br><dim>على <bdi>iPhone</bdi>.</dim>",
      "sub": "من ملفاتك أنت، والبحث فيها على الهاتف نفسه."
    },
    "06_memories": {
      "eyebrow": "ذاكرة · على الجهاز",
      "h1": "يتذكر.<br><dim>وكل ذكرى<br>بين يديك.</dim>",
      "sub": "ويمكنك رؤية كل ما يحفظه والبحث فيه."
    },
    "07_companion": {
      "eyebrow": "اختياري · رفيق ثلاثي الأبعاد",
      "h1": "رفيق،<br><dim>إن أردت.</dim>",
      "tiles": [
        "الثعلب",
        "السحلية",
        "الحبّار",
        "الكولوبس"
      ]
    },
    "08_data-not-collected": {
      "eyebrow": "خصوصية بالتصميم",
      "h1": "بلا حساب.<br>بلا تتبع.<br><dim>لا شيء يصلنا.</dim>",
      "sub": "ملصق <bdi>Apple</bdi>: «لا تُجمع أي بيانات».",
      "big": "0",
      "bigUnit": "بايت نجمعه نحن.",
      "corner": "لم يتضرّر أي مركز بيانات."
    },
    "09_hands-free": {
      "eyebrow": "صوت · دون استخدام اليدين · بالإنجليزية",
      "h1": "كلمة «<bdi>please</bdi>»<br><dim>تمنحه دوره.</dim>",
      "sub": "يكفي أن تنتهي الجملة بكلمة «<bdi>please</bdi>» ليجيب. والكلام يبقى على&nbsp;<bdi>iPhone</bdi>."
    },
    "10_pairing": {
      "eyebrow": "<bdi>Brain at Home</bdi> · الربط",
      "h1": "رمز <bdi>QR</bdi> واحد.<br><dim>مشفر.<br>على شبكتك فقط.</dim>",
      "sub": "الربط مع جهاز <bdi>Mac</bdi> برمز <bdi>QR</bdi>. والرمز تنتهي صلاحيته خلال دقيقة تقريبًا."
    },
    "06b_constellation": {
      "eyebrow": "ذاكرة · على الجهاز",
      "h1": "ذاكرتك،<br><dim>كأنها سماء.</dim>",
      "sub": "كل نقطة ضوء شيء أخبرته به. وكلها تبقى على جهاز <bdi>Mac</bdi> هذا."
    },
    "09_you-approve": {
      "eyebrow": "سكربتات الوكيل · على جهاز <bdi>Mac</bdi> هذا",
      "h1": "يقترح.<br><dim>والقرار لك.</dim>",
      "sub": "لا يعمل إلا ما وافقت عليه، بايتًا ببايت."
    }
  }
};

// Per-locale type scale (1 = designed size) and line-height factor (× the title's .84).
// dir:"rtl" goes on the caption blocks only.
const TYPE = {
  "en-US": {
    "h1": 1,
    "sub": 1,
    "lh": 1
  },
  "en-GB": {
    "h1": 1,
    "sub": 1,
    "lh": 1
  },
  "de-DE": {
    "h1": 0.86,
    "sub": 0.9,
    "lh": 1
  },
  "es-ES": {
    "h1": 0.92,
    "sub": 0.92,
    "lh": 1
  },
  "es-MX": {
    "h1": 0.88,
    "sub": 0.92,
    "lh": 1
  },
  "fr-FR": {
    "h1": 0.86,
    "sub": 0.92,
    "lh": 1
  },
  "ja": {
    "h1": 0.78,
    "sub": 0.85,
    "lh": 1.35
  },
  "ko": {
    "h1": 0.8,
    "sub": 0.9,
    "lh": 1.35
  },
  "pt-BR": {
    "h1": 0.92,
    "sub": 0.95,
    "lh": 1
  },
  "zh-Hans": {
    "h1": 0.8,
    "sub": 0.85,
    "lh": 1.35
  },
  "ru": {
    "h1": 0.8,
    "sub": 0.9,
    "lh": 1.3
  },
  "ar-SA": {
    "h1": 0.8,
    "sub": 0.95,
    "lh": 1.2,
    "dir": "rtl"
  }
};

// Mac-specific copy (the Mac listing says "Mac", not "iPhone").
const MAC_OVERRIDES = {
  "en-US": {
    "01_hero": {
      "eyebrow": "On-device AI · no account",
      "h1": "Local AI.<br>Works offline.<br><dim>Stays private.</dim>",
      "sub": "Chat, voice and memory. On&nbsp;your&nbsp;Mac."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "Your AI.<br>Your devices.<br><dim>Private by design.</dim>",
      "sub": "Your Mac lends its brain to your iPhone and iPad. Over your own Wi-Fi."
    },
    "03_voice": {
      "eyebrow": "Live voice · on-device",
      "h1": "Talk to it.<br><dim>It talks back.</dim>",
      "sub": "Speech in and out, on the Mac."
    },
    "04_pick-a-brain": {
      "eyebrow": "Free · no account · no sign-up",
      "h1": "Pick a brain.<br><dim>Not a plan.</dim>",
      "sub": "Three local models. Switch any time."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notes · PDFs · on-device",
      "h1": "Ask your<br>PDFs and notes.<br><dim>On your Mac.</dim>",
      "sub": "Answers from your own files. Searched on&nbsp;the&nbsp;Mac."
    },
    "06_memories": {
      "eyebrow": "Memory · on-device",
      "h1": "It remembers.<br><dim>You can read<br>every memory.</dim>",
      "sub": "See and search everything it keeps."
    },
    "07_companion": {
      "eyebrow": "Optional · 3D companion",
      "h1": "A companion,<br><dim>if you want one.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "Private by design",
      "h1": "No account.<br>No tracking.<br><dim>Nothing phones home.</dim>",
      "sub": "Apple's label: Data Not Collected."
    }
  },
  "en-GB": {
    "01_hero": {
      "eyebrow": "On-device AI · no account",
      "h1": "Local AI.<br>Works offline.<br><dim>Stays private.</dim>",
      "sub": "Chat, voice and memory. On&nbsp;your&nbsp;Mac."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "Your AI.<br>Your devices.<br><dim>Private by design.</dim>",
      "sub": "Your Mac lends its brain to your iPhone and iPad. Over your own Wi-Fi."
    },
    "03_voice": {
      "eyebrow": "Live voice · on-device",
      "h1": "Talk to it.<br><dim>It talks back.</dim>",
      "sub": "Speech in and out, on the Mac."
    },
    "04_pick-a-brain": {
      "eyebrow": "Free · no account · no sign-up",
      "h1": "Pick a brain.<br><dim>Not a plan.</dim>",
      "sub": "Three local models. Switch any time."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notes · PDFs · on-device",
      "h1": "Ask your<br>PDFs and notes.<br><dim>On your Mac.</dim>",
      "sub": "Answers from your own files. Searched on&nbsp;the&nbsp;Mac."
    },
    "06_memories": {
      "eyebrow": "Memory · on-device",
      "h1": "It remembers.<br><dim>You can read<br>every memory.</dim>",
      "sub": "See and search everything it keeps."
    },
    "07_companion": {
      "eyebrow": "Optional · 3D companion",
      "h1": "A companion,<br><dim>if you want one.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "Private by design",
      "h1": "No account.<br>No tracking.<br><dim>Nothing phones home.</dim>",
      "sub": "Apple's label: Data Not Collected."
    }
  },
  "de-DE": {
    "01_hero": {
      "eyebrow": "KI auf dem Gerät · kein Konto",
      "h1": "Lokale KI.<br>Läuft offline.<br><dim>Bleibt privat.</dim>",
      "sub": "Chat, Stimme und Gedächtnis. Auf deinem&nbsp;Mac."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "Deine KI.<br>Deine Geräte.<br><dim>Privat aus Prinzip.</dim>",
      "sub": "Dein Mac leiht iPhone und iPad sein Hirn. Über dein eigenes WLAN."
    },
    "03_voice": {
      "eyebrow": "Sprachmodus · Englisch · auf dem Gerät",
      "h1": "Du sprichst.<br><dim>M1K3 antwortet.</dim>",
      "sub": "Spracherkennung und Stimme, auf dem Mac."
    },
    "04_pick-a-brain": {
      "eyebrow": "Kostenlos · kein Konto · keine Anmeldung",
      "h1": "Wähl ein Hirn.<br><dim>Kein Abo.</dim>",
      "sub": "Drei lokale Modelle. Jederzeit wechseln."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notizen · PDFs · auf dem Gerät",
      "h1": "Frag deine<br>PDFs & Notizen.<br><dim>Auf dem Mac.</dim>",
      "sub": "Antworten aus deinen eigenen Dateien, durchsucht direkt auf dem Mac."
    },
    "06_memories": {
      "eyebrow": "Gedächtnis · auf dem Gerät",
      "h1": "Mit Gedächtnis.<br><dim>Und du siehst<br>jede Erinnerung.</dim>",
      "sub": "Alles Gemerkte: sichtbar und durchsuchbar."
    },
    "07_companion": {
      "eyebrow": "Optional · 3D-Begleiter",
      "h1": "Ein Begleiter,<br><dim>wenn du magst.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "Privat aus Prinzip",
      "h1": "Kein Konto.<br>Kein Tracking.<br><dim>Nichts funkt heim.</dim>",
      "sub": "App-Datenschutz: Keine Daten erfasst."
    }
  },
  "es-ES": {
    "01_hero": {
      "eyebrow": "IA en el dispositivo · sin cuenta",
      "h1": "IA local<br>sin conexión.<br><dim>Y privada.</dim>",
      "sub": "Chat, voz y memoria. En tu Mac."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "Tu IA.<br>Tus dispositivos.<br><dim>Privada por diseño.</dim>",
      "sub": "Tu Mac presta su cerebro a tu iPhone y tu iPad. Por tu propia wifi."
    },
    "03_voice": {
      "eyebrow": "Voz en inglés · en el dispositivo",
      "h1": "Háblale.<br><dim>Te responde<br>en voz alta.</dim>",
      "sub": "Te escucha y te habla, en el Mac."
    },
    "04_pick-a-brain": {
      "eyebrow": "Gratis · sin cuenta · sin registro",
      "h1": "Elige tu IA.<br><dim>No una tarifa.</dim>",
      "sub": "Tres modelos locales. Cambia cuando quieras."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notas · PDF · en el dispositivo",
      "h1": "Pregunta a<br>tus PDF y notas.<br><dim>En tu Mac.</dim>",
      "sub": "Respuestas de tus propios archivos. La búsqueda, en el Mac."
    },
    "06_memories": {
      "eyebrow": "Memoria · en el dispositivo",
      "h1": "Tiene memoria.<br><dim>Y puedes leer<br>cada recuerdo.</dim>",
      "sub": "Mira y busca todo lo que guarda."
    },
    "07_companion": {
      "eyebrow": "Opcional · compañero 3D",
      "h1": "Un compañero,<br><dim>si te apetece.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "Privado por diseño",
      "h1": "Sin cuenta.<br>Sin rastreo.<br><dim>Nada llama a casa.</dim>",
      "sub": "Etiqueta de Apple: Datos no recopilados."
    }
  },
  "es-MX": {
    "01_hero": {
      "eyebrow": "IA en el dispositivo · sin cuenta",
      "h1": "IA local.<br>Sin internet.<br><dim>Y privada.</dim>",
      "sub": "Chat, voz y memoria. En tu Mac."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "Tu IA.<br>Tus dispositivos.<br><dim>Privada por diseño.</dim>",
      "sub": "Tu Mac le presta su cerebro a tu iPhone y tu iPad. Por tu propia red Wi-Fi."
    },
    "03_voice": {
      "eyebrow": "Voz (inglés) · en el dispositivo",
      "h1": "Háblale.<br><dim>Te responde<br>en voz alta.</dim>",
      "sub": "Escucha y habla en inglés, en la Mac."
    },
    "04_pick-a-brain": {
      "eyebrow": "Elige tu cerebro · sin cuenta · sin registro",
      "h1": "IA gratis.<br><dim>Sin suscripción.</dim>",
      "sub": "Tres modelos locales. Cambia cuando quieras."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notas · PDF · en el dispositivo",
      "h1": "Consulta<br>tus PDF y notas.<br><dim>En tu Mac.</dim>",
      "sub": "Respuestas con base en tus propios archivos. Se buscan en la Mac."
    },
    "06_memories": {
      "eyebrow": "Memoria · en el dispositivo",
      "h1": "Tiene memoria.<br><dim>Puedes leer<br>cada recuerdo.</dim>",
      "sub": "Mira y busca todo lo que guarda."
    },
    "07_companion": {
      "eyebrow": "Opcional · compañero 3D",
      "h1": "Un compañero,<br><dim>si quieres uno.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "Privada por diseño",
      "h1": "Sin cuenta.<br>Sin rastreo.<br><dim>Nada nos llega.</dim>",
      "sub": "Etiqueta de Apple: Datos no recopilados."
    }
  },
  "fr-FR": {
    "01_hero": {
      "eyebrow": "IA sur l’appareil · sans compte",
      "h1": "IA locale.<br>Hors ligne.<br><dim>Et privée.</dim>",
      "sub": "Conversation, voix et mémoire. Sur ton Mac."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "Ton IA.<br>Tes appareils.<br><dim>Privée par design.</dim>",
      "sub": "Ton Mac prête son cerveau à ton iPhone et ton iPad. Via ton propre Wi-Fi."
    },
    "03_voice": {
      "eyebrow": "Voix en anglais · sur l’appareil",
      "h1": "Parle-lui.<br><dim>Il répond<br>à voix haute.</dim>",
      "sub": "Il t’écoute et te parle, sur le Mac."
    },
    "04_pick-a-brain": {
      "eyebrow": "Gratuit · sans compte · sans inscription",
      "h1": "Choisis<br>ton cerveau.<br><dim>Sans abonnement.</dim>",
      "sub": "Trois modèles locaux. Change quand tu veux."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notes · PDF · sur l’appareil",
      "h1": "Interroge<br>tes PDF et notes.<br><dim>Sur ton Mac.</dim>",
      "sub": "Des réponses tirées de tes fichiers. La recherche reste sur le Mac."
    },
    "06_memories": {
      "eyebrow": "Mémoire · sur l’appareil",
      "h1": "Il se souvient.<br><dim>Tu peux lire<br>chaque souvenir.</dim>",
      "sub": "Vois et cherche tout ce qu’il garde."
    },
    "07_companion": {
      "eyebrow": "En option · compagnon 3D",
      "h1": "Un compagnon,<br><dim>si ça te dit.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "Privée par design",
      "h1": "Pas de compte.<br>Pas de suivi.<br><dim>Aucun mouchard.</dim>",
      "sub": "Étiquette Apple : Données non collectées."
    }
  },
  "ja": {
    "01_hero": {
      "eyebrow": "オンデバイスAI · アカウント不要",
      "h1": "ローカルAI。<br>ネット不要。<br><dim>プライベート。</dim>",
      "sub": "チャット、音声、記憶。あなたのMacで。"
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "あなたのAI。<br>あなたのデバイス。<br><dim>プライバシー重視。</dim>",
      "sub": "MacがiPhoneとiPadに頭脳を貸す。自宅のWi-Fiだけで。"
    },
    "03_voice": {
      "eyebrow": "ライブ音声 · オンデバイス（英語）",
      "h1": "話しかけて。<br><dim>音声で答える。</dim>",
      "sub": "聞くのも話すのも、Macの中で。"
    },
    "05_notes-pdfs": {
      "eyebrow": "メモ · PDF · オンデバイス",
      "h1": "PDFやメモに<br>質問できる。<br><dim>Macの中で。</dim>",
      "sub": "答えは自分のファイルから。検索もMacの中で。"
    },
    "04_pick-a-brain": {
      "sub": "3つのローカルモデル。いつでも切り替えられる。"
    }
  },
  "ko": {
    "01_hero": {
      "eyebrow": "온디바이스 AI · 계정 없음",
      "h1": "로컬 AI.<br>오프라인 작동.<br><dim>비공개 그대로.</dim>",
      "sub": "채팅, 음성, 기억. 네 Mac에서."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "너의 AI.<br>너의 기기.<br><dim>프라이버시 중심 설계.</dim>",
      "sub": "Mac이 iPhone과 iPad에 두뇌를 빌려줘. 집 Wi-Fi로만."
    },
    "03_voice": {
      "eyebrow": "실시간 음성(영어) · 온디바이스",
      "h1": "말로 물어봐.<br><dim>음성으로 답해.</dim>",
      "sub": "듣고 말하는 것 모두 Mac 안에서."
    },
    "04_pick-a-brain": {
      "eyebrow": "무료 · 계정 없음 · 가입 없음",
      "h1": "두뇌를 골라.<br><dim>요금제 말고.</dim>",
      "sub": "로컬 모델 세 가지. 언제든 바꿔."
    },
    "05_notes-pdfs": {
      "eyebrow": "메모 · PDF · 온디바이스",
      "h1": "PDF와 메모에<br>물어봐.<br><dim>Mac 안에서.</dim>",
      "sub": "네 파일에서 찾은 답. 검색도 Mac 안에서."
    },
    "06_memories": {
      "eyebrow": "기억 · 온디바이스",
      "h1": "기억하는 AI.<br><dim>모든 기억을<br>직접 읽어 봐.</dim>",
      "sub": "기억한 건 전부 보고 검색할 수 있어."
    },
    "07_companion": {
      "eyebrow": "선택 사항 · 3D 컴패니언",
      "h1": "컴패니언,<br><dim>원한다면.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "프라이버시 중심 설계",
      "h1": "계정 없음.<br>추적 없음.<br><dim>몰래 전송 없음.</dim>",
      "sub": "Apple 라벨: 데이터가 수집되지 않음."
    }
  },
  "pt-BR": {
    "01_hero": {
      "eyebrow": "IA no dispositivo · sem conta",
      "h1": "IA local.<br>Roda offline.<br><dim>E privada.</dim>",
      "sub": "Chat, voz e memória. No seu Mac."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "Sua IA.<br>Seus aparelhos.<br><dim>Privada por design.</dim>",
      "sub": "Seu Mac empresta o cérebro ao seu iPhone e iPad. Pela sua rede Wi-Fi."
    },
    "03_voice": {
      "eyebrow": "Voz em inglês · no dispositivo",
      "h1": "Fale com ele.<br><dim>Ele responde.</dim>",
      "sub": "Ouve e fala, no próprio Mac."
    },
    "04_pick-a-brain": {
      "eyebrow": "Grátis · sem conta · sem cadastro",
      "h1": "Escolha<br>um cérebro.<br><dim>Não um plano.</dim>",
      "sub": "Três modelos locais. Troque quando quiser."
    },
    "05_notes-pdfs": {
      "eyebrow": "Notas · PDFs · no dispositivo",
      "h1": "Consulte seus<br>PDFs e notas.<br><dim>No seu Mac.</dim>",
      "sub": "Respostas dos seus próprios arquivos. Buscadas no próprio Mac."
    },
    "06_memories": {
      "eyebrow": "Memória · no dispositivo",
      "h1": "Ele lembra.<br><dim>Você pode ler<br>cada memória.</dim>",
      "sub": "Veja e busque tudo o que ele guarda."
    },
    "07_companion": {
      "eyebrow": "Opcional · companheiro 3D",
      "h1": "Um mascote 3D,<br><dim>se você quiser.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "Privacidade por design",
      "h1": "Sem conta.<br>Sem telemetria.<br><dim>Sem rastreamento.</dim>",
      "sub": "Rótulo da Apple: Dados não coletados."
    }
  },
  "zh-Hans": {
    "01_hero": {
      "eyebrow": "端侧 AI · 无需账户",
      "h1": "本地 AI。<br>离线可用。<br><dim>始终私密。</dim>",
      "sub": "聊天、语音与记忆，就在你的 Mac 上。"
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "你的 AI。<br>你的设备。<br><dim>天生私密。</dim>",
      "sub": "你的 Mac 把大脑借给 iPhone 和 iPad。走你自己的 Wi-Fi。"
    },
    "03_voice": {
      "eyebrow": "实时语音 · 设备端（英语）",
      "h1": "开口就聊。<br><dim>它会语音回话。</dim>",
      "sub": "语音输入与输出，都在 Mac 上。"
    },
    "04_pick-a-brain": {
      "eyebrow": "免费 · 无需账户 · 无需注册",
      "h1": "挑个大模型，<br><dim>不挑套餐。</dim>",
      "sub": "三个本地模型，随时切换。"
    },
    "05_notes-pdfs": {
      "eyebrow": "笔记 · PDF · 设备端",
      "h1": "问问你的<br>PDF 和笔记。<br><dim>就在 Mac 上。</dim>",
      "sub": "答案来自你自己的文件，搜索在 Mac 上完成。"
    },
    "06_memories": {
      "eyebrow": "记忆 · 设备端",
      "h1": "它会记住。<br><dim>每条记忆<br>你都能看。</dim>",
      "sub": "它记下的一切，你都能查看和搜索。"
    },
    "07_companion": {
      "eyebrow": "可选 · 3D 伙伴",
      "h1": "一个伙伴，<br><dim>想要就有。</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "天生私密",
      "h1": "无需账户。<br>没有追踪。<br><dim>从不回传。</dim>",
      "sub": "Apple 隐私标签：未收集数据。"
    }
  },
  "ru": {
    "01_hero": {
      "eyebrow": "ИИ на устройстве · без аккаунта",
      "h1": "Локальный ИИ.<br>Без интернета.<br><dim>Приватный.</dim>",
      "sub": "Чат, голос и память. На твоём Mac."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPhone + iPad",
      "h1": "Твой ИИ.<br>Твои устройства.<br><dim>Приватный по замыслу.</dim>",
      "sub": "Твой Mac делится мозгом с iPhone и iPad. Только по твоему Wi-Fi."
    },
    "03_voice": {
      "eyebrow": "Голос на устройстве · на английском",
      "h1": "Спроси голосом.<br><dim>Он ответит.</dim>",
      "sub": "Распознавание и синтез речи — прямо на Mac."
    },
    "04_pick-a-brain": {
      "eyebrow": "Бесплатно · без аккаунта · без регистрации",
      "h1": "Выбери мозг.<br><dim>Не тариф.</dim>",
      "sub": "Три локальные модели. Меняй когда угодно."
    },
    "05_notes-pdfs": {
      "eyebrow": "Заметки · PDF · на устройстве",
      "h1": "Чат с PDF<br>и заметками.<br><dim>На Mac.</dim>",
      "sub": "Ответы по твоим файлам. Поиск — прямо на Mac."
    },
    "06_memories": {
      "eyebrow": "Память · на устройстве",
      "h1": "ИИ с памятью.<br><dim>Читай всё,<br>что он помнит.</dim>",
      "sub": "Смотри и ищи всё, что он сохранил."
    },
    "07_companion": {
      "eyebrow": "По желанию · 3D-компаньон",
      "h1": "Компаньон —<br><dim>если хочешь.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "Приватность по замыслу",
      "h1": "Без аккаунта.<br>Без слежки.<br><dim>Без телеметрии.</dim>",
      "sub": "Метка Apple: «Данные не собираются»."
    }
  },
  "ar-SA": {
    "01_hero": {
      "eyebrow": "ذكاء على الجهاز · بلا حساب",
      "h1": "ذكاء اصطناعي<br>بدون إنترنت.<br><dim>خاص ومحلي.</dim>",
      "sub": "دردشة وصوت وذاكرة. على جهاز <bdi>Mac</bdi>."
    },
    "02_your-devices": {
      "eyebrow": "<bdi>Brain at Home</bdi> · <bdi>Mac</bdi> + <bdi>iPhone</bdi> + <bdi>iPad</bdi>",
      "h1": "ذكاؤك الاصطناعي.<br>أجهزتك.<br><dim>خصوصية بالتصميم.</dim>",
      "sub": "يُعير جهاز <bdi>Mac</bdi> عقله إلى <bdi>iPhone</bdi> و<bdi>iPad</bdi>. عبر شبكة <bdi>Wi-Fi</bdi> الخاصة بك."
    },
    "03_voice": {
      "eyebrow": "صوت مباشر · على الجهاز · بالإنجليزية",
      "h1": "محادثة صوتية.<br><dim>ويرد بصوته.</dim>",
      "sub": "يسمع ويتكلّم، على جهاز <bdi>Mac</bdi> نفسه."
    },
    "04_pick-a-brain": {
      "eyebrow": "مجاني · بلا حساب · بلا تسجيل",
      "h1": "العقل باختيارك.<br><dim>لا اشتراك.</dim>",
      "sub": "ثلاثة نماذج محلية. والتبديل في أي وقت."
    },
    "05_notes-pdfs": {
      "eyebrow": "ملاحظات · <bdi>PDF</bdi> · على الجهاز",
      "h1": "إجابات من<br><bdi>PDF</bdi> وملاحظاتك.<br><dim>على <bdi>Mac</bdi>.</dim>",
      "sub": "من ملفاتك أنت، والبحث فيها على جهاز <bdi>Mac</bdi> نفسه."
    },
    "06_memories": {
      "eyebrow": "ذاكرة · على الجهاز",
      "h1": "يتذكر.<br><dim>وكل ذكرى<br>بين يديك.</dim>",
      "sub": "ويمكنك رؤية كل ما يحفظه والبحث فيه."
    },
    "07_companion": {
      "eyebrow": "اختياري · رفيق ثلاثي الأبعاد",
      "h1": "رفيق،<br><dim>إن أردت.</dim>"
    },
    "08_data-not-collected": {
      "eyebrow": "خصوصية بالتصميم",
      "h1": "بلا حساب.<br>بلا تتبع.<br><dim>لا شيء يصلنا.</dim>",
      "sub": "ملصق <bdi>Apple</bdi>: «لا تُجمع أي بيانات»."
    }
  }
};

// iPad-specific copy (the iPad listing says "iPad", not "iPhone").
const IPAD_OVERRIDES = {
  "en-US": {
    "01_hero": {
      "sub": "Chat, voice and memory. On your iPad."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "Your iPad borrows your Mac's brain. Over your own Wi-Fi, never the internet."
    },
    "03_voice": {
      "sub": "Speech in and out, on the iPad."
    },
    "05_notes-pdfs": {
      "h1": "Ask your<br>PDFs and notes.<br><dim>On your iPad.</dim>",
      "sub": "Answers from your own files. Searched on the iPad."
    },
    "09_hands-free": {
      "sub": "Finish with \"please\" and it answers. Speech stays on the iPad."
    }
  },
  "en-GB": {
    "01_hero": {
      "sub": "Chat, voice and memory. On your iPad."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "Your iPad borrows your Mac's brain. Over your own Wi-Fi, never the internet."
    },
    "03_voice": {
      "sub": "Speech in and out, on the iPad."
    },
    "05_notes-pdfs": {
      "h1": "Ask your<br>PDFs and notes.<br><dim>On your iPad.</dim>",
      "sub": "Answers from your own files. Searched on the iPad."
    },
    "09_hands-free": {
      "sub": "Finish with \"please\" and it answers. Speech stays on the iPad."
    }
  },
  "de-DE": {
    "01_hero": {
      "sub": "Chat, Stimme und Gedächtnis. Auf deinem iPad."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "Dein iPad leiht sich das Hirn deines Macs. Über dein eigenes WLAN, nie übers Internet."
    },
    "03_voice": {
      "sub": "Spracherkennung und Stimme, auf dem iPad."
    },
    "05_notes-pdfs": {
      "h1": "Frag deine<br>PDFs & Notizen.<br><dim>Auf dem iPad.</dim>",
      "sub": "Antworten aus deinen eigenen Dateien, durchsucht direkt auf dem iPad."
    },
    "09_hands-free": {
      "sub": "Sag am Ende „please“, und M1K3 antwortet. Deine Stimme bleibt auf dem iPad."
    }
  },
  "es-ES": {
    "01_hero": {
      "sub": "Chat, voz y memoria. En tu iPad."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "Tu iPad usa el cerebro de tu Mac. Por tu propia wifi, nunca por internet."
    },
    "03_voice": {
      "sub": "Te escucha y te habla, en el iPad."
    },
    "05_notes-pdfs": {
      "h1": "Pregunta a<br>tus PDF y notas.<br><dim>En tu iPad.</dim>",
      "sub": "Respuestas de tus propios archivos. La búsqueda, en el iPad."
    },
    "09_hands-free": {
      "sub": "Termina con \"please\" y te responde. Tu voz se queda en el iPad."
    }
  },
  "es-MX": {
    "01_hero": {
      "sub": "Chat, voz y memoria. En tu iPad."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "Tu iPad toma prestado el cerebro de tu Mac. Por tu propia red Wi-Fi, nunca por internet."
    },
    "03_voice": {
      "sub": "Escucha y habla en inglés, en el iPad."
    },
    "05_notes-pdfs": {
      "h1": "Consulta<br>tus PDF y notas.<br><dim>En tu iPad.</dim>",
      "sub": "Respuestas con base en tus propios archivos. Se buscan en el iPad."
    },
    "09_hands-free": {
      "sub": "Habla en inglés, termina con \"please\" y te responde. Tu voz no sale del iPad."
    }
  },
  "fr-FR": {
    "01_hero": {
      "sub": "Conversation, voix et mémoire. Sur ton iPad."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "Ton iPad emprunte le cerveau de ton Mac. Via ton propre Wi-Fi, jamais par Internet."
    },
    "03_voice": {
      "sub": "Il t’écoute et te parle, sur l’iPad."
    },
    "05_notes-pdfs": {
      "h1": "Interroge<br>tes PDF et notes.<br><dim>Sur ton iPad.</dim>",
      "sub": "Des réponses tirées de tes fichiers. La recherche reste sur l’iPad."
    },
    "09_hands-free": {
      "sub": "Termine par \"please\" et il répond. Ta voix reste sur l’iPad."
    }
  },
  "ja": {
    "01_hero": {
      "sub": "チャット、音声、記憶。あなたのiPadで。"
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "iPadがMacの頭脳を借りる。インターネットを通さず、自宅のWi-Fiで。"
    },
    "03_voice": {
      "sub": "聞くのも話すのも、iPadの中で。"
    },
    "05_notes-pdfs": {
      "h1": "PDFやメモに<br>質問できる。<br><dim>iPadの中で。</dim>",
      "sub": "答えは自分のファイルから。検索もiPadの中で。"
    },
    "09_hands-free": {
      "sub": "最後に「please」と言えば答える。音声はiPadの中に留まる。"
    }
  },
  "ko": {
    "01_hero": {
      "sub": "채팅, 음성, 기억. 네 iPad에서."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "iPad가 Mac의 두뇌를 빌려 써. 인터넷이 아닌, 집 Wi-Fi로만."
    },
    "03_voice": {
      "sub": "듣고 말하는 것 모두 iPad 안에서."
    },
    "05_notes-pdfs": {
      "h1": "PDF와 메모에<br>물어봐.<br><dim>iPad 안에서.</dim>",
      "sub": "네 파일에서 찾은 답. 검색도 iPad 안에서."
    },
    "09_hands-free": {
      "sub": "끝에 \"please\"라고 하면 대답할게. 음성은 iPad 안에 머물러."
    }
  },
  "pt-BR": {
    "01_hero": {
      "sub": "Chat, voz e memória. No seu iPad."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "Seu iPad usa o cérebro do seu Mac. Pela sua rede Wi-Fi, nunca pela internet."
    },
    "03_voice": {
      "sub": "Ouve e fala, no próprio iPad."
    },
    "05_notes-pdfs": {
      "h1": "Consulte seus<br>PDFs e notas.<br><dim>No seu iPad.</dim>",
      "sub": "Respostas dos seus próprios arquivos. Buscadas no próprio iPad."
    },
    "09_hands-free": {
      "sub": "Termine com \"please\" (em inglês) e ele responde. Sua fala fica no iPad."
    }
  },
  "zh-Hans": {
    "01_hero": {
      "eyebrow": "端侧 AI · 无需账户",
      "h1": "本地 AI。<br>离线可用。<br><dim>始终私密。</dim>",
      "sub": "聊天、语音与记忆，就在你的 iPad 上。"
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "h1": "你的 AI。<br>你的设备。<br><dim>天生私密。</dim>",
      "sub": "你的 iPad 借用 Mac 的大脑。<br>走你自己的 Wi-Fi，绝不经过互联网。"
    },
    "03_voice": {
      "eyebrow": "实时语音 · 设备端（英语）",
      "h1": "开口就聊。<br><dim>它会语音回话。</dim>",
      "sub": "语音输入与输出，都在 iPad 上。"
    },
    "05_notes-pdfs": {
      "eyebrow": "笔记 · PDF · 设备端",
      "h1": "问问你的<br>PDF 和笔记。<br><dim>就在 iPad 上。</dim>",
      "sub": "答案来自你自己的文件，搜索在 iPad 上完成。"
    },
    "09_hands-free": {
      "eyebrow": "语音 · 免提（英语）",
      "h1": "说“please”，<br><dim>它就接话。</dim>",
      "sub": "以“please”结尾，它就会回答。语音留在 iPad 上。"
    }
  },
  "ru": {
    "01_hero": {
      "sub": "Чат, голос и память. На твоём iPad."
    },
    "02_your-devices": {
      "eyebrow": "Brain at Home · Mac + iPad",
      "sub": "iPad берёт взаймы мозг твоего Mac. Только по твоему Wi-Fi, не через интернет."
    },
    "03_voice": {
      "sub": "Распознавание и синтез речи — прямо на iPad."
    },
    "05_notes-pdfs": {
      "h1": "Чат с PDF<br>и заметками.<br><dim>На iPad.</dim>",
      "sub": "Ответы по твоим файлам. Поиск — прямо на iPad."
    },
    "09_hands-free": {
      "sub": "Закончи фразу словом «please» — и он ответит. Речь остаётся на iPad."
    }
  },
  "ar-SA": {
    "01_hero": {
      "sub": "دردشة وصوت وذاكرة. على <bdi>iPad</bdi>."
    },
    "02_your-devices": {
      "eyebrow": "<bdi>Brain at Home</bdi> · <bdi>Mac</bdi> + <bdi>iPad</bdi>",
      "sub": "يستعير <bdi>iPad</bdi> عقل جهاز <bdi>Mac</bdi>. عبر شبكة <bdi>Wi-Fi</bdi> الخاصة بك، لا&nbsp;عبر&nbsp;الإنترنت."
    },
    "03_voice": {
      "sub": "يسمع ويتكلّم، على <bdi>iPad</bdi> نفسه."
    },
    "05_notes-pdfs": {
      "h1": "إجابات من<br><bdi>PDF</bdi> وملاحظاتك.<br><dim>على <bdi>iPad</bdi>.</dim>",
      "sub": "من ملفاتك أنت، والبحث فيها على <bdi>iPad</bdi> نفسه."
    },
    "09_hands-free": {
      "sub": "يكفي أن تنتهي الجملة بكلمة «<bdi>please</bdi>» ليجيب. والكلام يبقى على&nbsp;<bdi>iPad</bdi>."
    }
  }
};

// 04 (QA r3): the Simulator iPad shows Private Cloud Compute "unavailable" (no Apple
// Intelligence), and the sub says the private cloud is there where the device supports it.
// QA r4: the iPad frame shows the PCC card as shot ("unavailable") under the lifted three, and
// the iPhone takes the same hedged sub: PCC (and Mini) need an Apple Intelligence device there
// too. zh-Hans breaks before 随时切换 (it was a one-word last line).
// QA r5: this hedged line is now the iPhone's (COPY) alone; the iPad has its own below.
const PHONE_04_SUB = {
  "en-US": "On the device, on your Mac, or Apple's private cloud where available. Switch any time.",
  "en-GB": "On the device, on your Mac, or Apple's private cloud where available. Switch any time.",
  "de-DE": "Auf dem Gerät, auf deinem Mac oder, wo verfügbar, in Apples privater Cloud. Jederzeit wechseln.",
  "es-ES": "En el dispositivo, en tu Mac o, donde esté disponible, en la nube privada de Apple. Cambia cuando quieras.",
  "es-MX": "En el dispositivo, en tu Mac o, donde esté disponible, en la nube privada de Apple. Cambia cuando quieras.",
  "fr-FR": "Sur l’appareil, sur ton Mac ou, si disponible, dans le cloud privé d’Apple. Change quand tu veux.",
  ja: "この端末、Mac、または対応機種ならAppleのプライベートクラウド。いつでも切り替えられる。",
  ko: "이 기기, 네 Mac, 또는 지원 기기에선 Apple의 프라이빗 클라우드. 언제든 바꿔.",
  "pt-BR": "No aparelho, no seu Mac ou, onde houver, na nuvem privada da Apple. Troque quando quiser.",
  "zh-Hans": "本机、你的 Mac，或支持的机型上的 Apple 私有云。<br>随时切换。",
  ru: "На устройстве, на твоём Mac или, где доступно, в частном облаке Apple. Меняй когда угодно.",
  "ar-SA": "على الجهاز، أو على جهاز <bdi>Mac</bdi>، أو في سحابة <bdi>Apple</bdi> الخاصة حيث تتوفر. والتبديل في أي وقت.",
};
for (const [loc, sub] of Object.entries(PHONE_04_SUB)) COPY[loc]["04_pick-a-brain"] = { ...COPY[loc]["04_pick-a-brain"], sub };

// QA r5 (2026-10-23): the iPad frame shows only Mini, Lil and Home (frames.js bands the
// Simulator's "unavailable" PCC card out), so its sub names only the device and the Mac. Same
// register and punctuation as each locale's frame-04 sub; Wi-Fi as that locale's frame 02 says it.
const IPAD_04_SUB = {
  "en-US": "On the device, or on your Mac over your own Wi-Fi. Switch any time.",
  "en-GB": "On the device, or on your Mac over your own Wi-Fi. Switch any time.",
  "de-DE": "Auf dem Gerät oder auf deinem Mac über dein eigenes WLAN. Jederzeit wechseln.",
  "es-ES": "En el dispositivo o en tu Mac, por tu propia red Wi-Fi. Cambia cuando quieras.",
  "es-MX": "En el dispositivo o en tu Mac, por tu propia red Wi-Fi. Cambia cuando quieras.",
  "fr-FR": "Sur l’appareil, ou sur ton Mac via ton propre Wi-Fi. Change quand tu veux.",
  ja: "この端末、または自宅のWi-FiでつないだMac。いつでも切り替えられる。",
  ko: "이 기기, 또는 집 Wi-Fi로 연결한 네 Mac. 언제든 바꿔.",
  "pt-BR": "No aparelho ou no seu Mac, pela sua rede Wi-Fi. Troque quando quiser.",
  "zh-Hans": "本机，或走你自己的 Wi-Fi 连上你的 Mac。<br>随时切换。",
  ru: "На устройстве или на твоём Mac по твоему Wi-Fi. Меняй когда угодно.",
  "ar-SA": "على الجهاز، أو على جهاز <bdi>Mac</bdi> عبر شبكة <bdi>Wi-Fi</bdi> الخاصة بك. والتبديل في أي وقت.",
};
for (const [loc, sub] of Object.entries(IPAD_04_SUB))
  (IPAD_OVERRIDES[loc] ||= {})["04_pick-a-brain"] = { ...IPAD_OVERRIDES[loc]?.["04_pick-a-brain"], sub };
if (Object.keys(IPAD_04_SUB).length !== LOCALES.length) throw new Error("strings.js: IPAD_04_SUB must cover every locale");

// ── loud checks at load: a gap throws here, never renders as "undefined" ─────
const ENGLISH = {
  "de-DE": /Englisch/, "es-ES": /inglés/, "es-MX": /inglés/, "fr-FR": /anglais/, "pt-BR": /inglês/,
  ja: /英語/, ko: /영어/, "zh-Hans": /英语/, ru: /английск/, "ar-SA": /الإنجليزية/,
};
for (const loc of LOCALES) {
  if (!COPY[loc]) throw new Error(`strings.js: ${loc} is in LOCALES but has no COPY`);
  const t = TYPE[loc];
  if (!t || [t.h1, t.sub, t.lh].some((n) => typeof n !== "number"))
    throw new Error(`strings.js: ${loc} has no complete TYPE {h1, sub, lh}`);
  const re = ENGLISH[loc];
  if (!re) continue;
  const variants = [
    ["03_voice", COPY[loc]["03_voice"]],
    ["09_hands-free", COPY[loc]["09_hands-free"]],
    ["ipad:03_voice", { ...COPY[loc]["03_voice"], ...IPAD_OVERRIDES[loc]?.["03_voice"] }],
    ["ipad:09_hands-free", { ...COPY[loc]["09_hands-free"], ...IPAD_OVERRIDES[loc]?.["09_hands-free"] }],
    ["mac:03_voice", { ...COPY[loc]["03_voice"], ...MAC_OVERRIDES[loc]?.["03_voice"] }],
  ];
  for (const [id, c] of variants)
    if (!c || !re.test(`${c.eyebrow} ${c.sub} ${c.h1}`))
      throw new Error(`strings.js: ${loc} ${id} must say the voice is English (${re})`);
}

module.exports = { LOCALES, COPY, TYPE, MAC_OVERRIDES, IPAD_OVERRIDES };
