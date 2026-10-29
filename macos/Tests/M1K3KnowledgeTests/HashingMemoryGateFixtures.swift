//
//  HashingMemoryGateFixtures.swift
//  M1K3KnowledgeTests
//
//  #447's held-out set: 40 relevant and 25 unrelated (memory, question) pairs, written on
//  2026-10-29 by an agent that saw no M1K3 code, BEFORE any design existed, and kept from the three
//  designers. It scored the gate once (the failed blind bar Kev overrode); it is a regression
//  fixture now, no longer blind. Positives 1-20 share a content word with their memory; 21-40 need
//  a leap. Negatives include 11 same-word traps (turkey/Turkey, Bath, Amazon…).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.8 (data, verbatim from the blind
//  author's file). Prior: none (new file).
//

enum HashingMemoryGateFixtures {
    static let positives: [(memory: String, question: String)] = [
        ("The user's brother is called Ronan.", "What's my brother's name again?"),
        ("The user is training for a marathon in April.", "How many weeks have I got until my marathon?"),
        ("The user's dog is a beagle named Biscuit.", "What should I get my dog for his birthday?"),
        ("The user's wife, Aoife, has her birthday on 14 March.", "When is my wife's birthday?"),
        ("The user drives a 2019 Nissan Leaf.", "What size tyres does my Nissan take?"),
        ("The user is allergic to peanuts.", "What snacks are safe for my allergy?"),
        ("The user's daughter Saoirse starts secondary school in September.", "What should I buy my daughter before she starts school?"),
        ("The user plays bass guitar in a band called The Low Tides.", "Suggest a name for my band's new EP."),
        ("The user is learning Japanese and is at about JLPT N4 level.", "Recommend a Japanese podcast for my level."),
        ("The user's flat is in Stoneybatter, Dublin.", "Any good coffee spots near my flat?"),
        ("The user's mum is called Bernadette and lives in Galway.", "How long is the drive from Dublin to my mum's?"),
        ("The user works night shifts as an ICU nurse.", "Any tips for sleeping after my shifts?"),
        ("The user's favourite football team is Liverpool.", "Did my team win at the weekend?"),
        ("The user's kitchen is only 2.4 metres wide.", "Will a full-size dishwasher fit in my kitchen?"),
        ("The user's cat Miso needs a thyroid tablet every morning.", "Remind me what my cat takes each morning."),
        ("The user's landlord is called Mr Brennan.", "Draft a message to my landlord about the broken boiler."),
        ("The user's partner, Tom, is vegan.", "What can I cook for my partner on Saturday?"),
        ("The user's laptop is a 2020 MacBook Air with an M1 chip.", "Can my laptop run the latest macOS?"),
        ("The user's company is moving offices to Grand Canal Dock in January.", "When is my company's office move?"),
        ("The user's son, Fionn, is 7 and loves dinosaurs.", "Any gift ideas for my son?"),
        ("Kev is an engineer at Stripe.", "Where do I work?"),
        ("The user is vegetarian.", "Any ideas for dinner tonight?"),
        ("The user lives in Cork.", "Will I need an umbrella tomorrow?"),
        ("The user has coeliac disease.", "Can you suggest a pasta dish for tonight?"),
        ("The user is afraid of flying.", "What's the best way to get from Dublin to Paris?"),
        ("The user's anniversary is on 3 June.", "What date did I tie the knot?"),
        ("The user takes the 46A bus to work.", "How do I usually get to the office?"),
        ("The user is six months pregnant.", "Is it ok for me to have a glass of wine tonight?"),
        ("The user supports Munster in rugby.", "Who should I cheer for in the Champions Cup final?"),
        ("The user is left-handed.", "Which scissors should I buy?"),
        ("The user grew up in Brazil.", "What's the national dish of my home country?"),
        ("The user has type 1 diabetes.", "What should I snack on before a long run?"),
        ("Kev's mortgage is with AIB.", "Which bank is my home loan with?"),
        ("The user hates coriander.", "What should I order at the Thai place tonight?"),
        ("The user is studying for the CFA Level II exam.", "How should I plan my revision this week?"),
        ("The user's sister Niamh lives in Melbourne.", "What time is it where my sibling is?"),
        ("The user's car is a red Toyota Yaris hybrid.", "How much should a service cost for my motor?"),
        ("The user is 1.68 m tall and weighs 72 kg.", "What's my BMI?"),
        ("The user's wedding is on 12 September 2027.", "How long have I got to lose weight before the big day?"),
        ("The user is lactose intolerant.", "Is a milkshake a bad idea for me?"),
    ]

    static let negatives: [(memory: String, question: String)] = [
        ("The user is flying to Turkey for a friend's wedding in Bodrum.", "How long should I roast a turkey for?"),
        ("The user's cousin Ciara is a pilot with Ryanair.", "Why is the sky blue?"),
        ("The user's dog, a terrier, is called Mango.", "How do I tell if a mango is ripe?"),
        ("The user works as a product designer at Apple.", "How many calories are in an apple?"),
        ("The user is learning to play the piano.", "What's 17 times 23?"),
        ("The user's favourite colour is green.", "Tell me a joke."),
        ("The user lives in Bath, in Somerset.", "How hot should a baby's bath be?"),
        ("The user's daughter is called Rose.", "How often should I water my roses?"),
        ("The user has a black belt in judo.", "How do I punch a new hole in my belt?"),
        ("The user is a big fan of the band Queen.", "How long did Queen Elizabeth II reign?"),
        ("The user's flat is on the fifth floor.", "What's the best way to clean a laminate floor?"),
        ("The user is saving for a deposit on a house.", "What's the capital of Australia?"),
        ("The user is training for a triathlon.", "How do I convert Celsius to Fahrenheit?"),
        ("The user's partner, Jordan, is a dentist.", "Who won the 1998 NBA finals?"),
        ("The user's son plays under-10 hurling.", "What's the weather like in Tokyo this week?"),
        ("The user is a night owl who codes best after 10pm.", "What's a good name for a pet owl?"),
        ("The user's sister is a nurse in Leeds.", "How do I boil an egg?"),
        ("The user's favourite film is Paddington 2.", "How do you say 'thank you' in Spanish?"),
        ("The user's office is in Sandyford.", "How do I reset my router?"),
        ("The user's mother tongue is Irish.", "What's the square root of 144?"),
        ("The user is going to a Taylor Swift concert at Wembley in June.", "Why do cats purr?"),
        ("The user drives a Volkswagen Golf.", "Who has won the most golf majors?"),
        ("The user's employer is Amazon.", "How long is the Amazon river?"),
        ("The user's grandmother turns 90 in December.", "Morning! How's it going?"),
        ("The user's bike was stolen last week.", "How many players are on a rugby team?"),
    ]
}
