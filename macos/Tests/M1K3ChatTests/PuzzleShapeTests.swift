//
//  PuzzleShapeTests.swift
//  M1K3ChatTests
//
//  The speed tiers (Mini, Lil) think only on an explicit "explain / step by step" ask, so a
//  multi-step puzzle answers fast and wrong: on 2026-11-19 Lil scored 74/78 thinking on the
//  routed reasoning fixtures and 38/52 on Auto, where none of them earned a think phase.
//  `PuzzleShape` names the shape (two or more quantities and a counting / timing ask, a chain of
//  comparisons, an explicit riddle) so an A/B arm can think, or reason in steps, on exactly those.
//  These cases are the TUNING set (the chateval reasoning prompts plus hand-picked negatives); the
//  blind set that scores it lives in Resources/puzzle-shape-blind.json (#713 rule).
//
//  Signed: Kev + claude-opus-5-5, 2026-11-20, Confidence 0.7 (a lexical heuristic; its real
//  precision is the blind set's number, not these). Prior: none (new file).

import Foundation
@testable import M1K3Chat
import Testing

struct PuzzleShapeTests {
    static let fixturePuzzles = [
        "A shop has 12 apples. It sells 5 in the morning and buys 8 more in the afternoon. How many apples does it have at the end of the day? Give the number.",
        "Mary is twice as old as her brother. Her brother is 9. How old is Mary? Answer with the number.",
        "Tom is taller than Sara. Sara is taller than Liam. Who is the shortest? Answer with the name.",
        "A meeting is on a Wednesday. What day of the week is 5 days after the meeting? Answer with the day.",
        "A train travels 60 km in 1 hour. How far does it travel in 2.5 hours at the same speed? Give the number of km.",
        "You have 14 sweets to share equally among 4 children. How many are left over? Answer with the number.",
        "A bat and a ball cost $1.10 together. The bat costs $1.00 more than the ball. How much does the ball cost, in cents? Answer with the number.",
        "A doctor gives you 3 pills and tells you to take one every half hour, starting now. How many minutes until you have taken them all? Answer with the number.",
        "A patch of lily pads doubles in size every day. It takes 48 days to cover the whole lake. How many days does it take to cover half the lake? Answer with the number.",
        "A parcel ships on a Tuesday. What day of the week is it 100 days later? Answer with the day.",
        "How many times is the digit 7 written when you write out every whole number from 1 to 100? Answer with the number.",
        "What is the smaller angle, in degrees, between the hour and minute hands of a clock at 3:40? Answer with the number.",
        "A snail is at the bottom of a 10 metre well. Each day it climbs up 3 metres and each night it slides back 2 metres. On which day does it first reach the top? Answer with the number.",
        "You drive 60 km at 30 km/h, then another 60 km at 60 km/h. What is your average speed for the whole trip, in km/h? Answer with the number.",
        "A drawer holds 10 red socks and 10 blue socks, mixed, and the room is dark. How many socks must you take out to be sure of a matching pair? Answer with the number.",
        "A straight fence is 50 metres long with a post every 5 metres, including a post at each end. How many posts are there? Answer with the number.",
        "A price rises by 50% and then falls by 50%. By what percent is the final price lower than the original? Answer with the number.",
        "Seven people meet and each shakes hands once with every other person. How many handshakes happen? Answer with the number.",
        "Of 30 students, 18 play football, 15 play tennis and 6 play neither. How many play both? Answer with the number.",
        "One pipe fills a tank in 2 hours and another fills it in 3 hours. Running together, how many minutes do they take to fill it? Answer with the number.",
        "In 4 years Ana will be twice as old as she was 5 years ago. How old is Ana now? Answer with the number.",
        "Walking up from floor 1 to floor 4 takes 30 seconds. At the same pace, how many seconds does it take from floor 1 to floor 10? Answer with the number.",
        "You cut a 15-metre rope into pieces 3 metres long. Each cut takes one minute. How many minutes does the cutting take? Answer with the number.",
        "A clock takes 5 seconds to strike 6 at six o'clock, timed from the first strike to the last. How many seconds does it take to strike 12 at noon? Answer with the number.",
        "You write out every whole number from 1 to 50. How many times do you write the digit 3? Answer with the number.",
        "Two trains start 300 km apart and head toward each other, one at 70 km/h and the other at 80 km/h. How many minutes until they meet? Answer with the number.",
    ]

    @Test("every chateval reasoning prompt reads as a puzzle", arguments: fixturePuzzles)
    func fixturePuzzlesDetected(_ question: String) {
        #expect(PuzzleShape.detects(question))
    }

    @Test("everyday asks never pay the think tax", arguments: [
        "yo M1K3, what's up?",
        "thanks pal!",
        "What time is it?",
        "What's the capital of France?",
        "Write me a haiku about 3 cats.",
        "Convert 5 km to miles.",
        "Remind me to call Mum at 5.",
        "How do I make pancakes?",
        "Summarise this note for me.",
        "What did we agree yesterday?",
        "Play something chill.",
        "Is it going to rain tomorrow in Dublin?",
    ])
    func everydayIsNotAPuzzle(_ question: String) {
        #expect(!PuzzleShape.detects(question))
    }

    @Test("a pasted document or code block is not a puzzle, whatever its numbers")
    func pastesAreNotPuzzles() {
        let code = "```swift\nlet a = 2\nlet b = 3\n```\nHow many lines is this?"
        #expect(!PuzzleShape.detects(code))
        let paste = String(repeating: "Revenue rose 12% to 4.5m in Q3 while costs fell 3%. ", count: 20)
            + "How much did revenue rise?"
        #expect(!PuzzleShape.detects(paste))
    }

    @Test("an explicit riddle reads as a puzzle without numbers")
    func explicitRiddle() {
        #expect(PuzzleShape.detects("Here's a riddle: what has keys but can't open locks?"))
        #expect(PuzzleShape.detects("Can you solve this logic puzzle for me?"))
    }

    @Test("wave-one languages: the same shapes in de, fr, es, pt", arguments: [
        "Ein Laden hat 12 Äpfel. Er verkauft 5 und kauft 8 dazu. Wie viele Äpfel hat er am Ende?",
        "Tom ist größer als Sara. Sara ist größer als Liam. Wer ist am kleinsten?",
        "Un train roule à 60 km/h pendant 2 heures. Combien de kilomètres parcourt-il ?",
        "Un colis part un mardi. Quel jour sera-t-il 100 jours plus tard ?",
        "Tengo 14 caramelos para 4 niños. ¿Cuántos sobran?",
        "Juan es más alto que Ana. Ana es más alta que Luis. ¿Quién es el más bajo?",
        "Uma corda de 15 metros é cortada em pedaços de 3 metros. Quantos cortes são necessários?",
        "Dois trens partem a 300 km de distância, um a 70 km/h e outro a 80 km/h. Em quantos minutos eles se encontram?",
    ])
    func waveOnePuzzles(_ question: String) {
        #expect(PuzzleShape.detects(question))
    }

    @Test("wave-one everyday asks stay fast", arguments: [
        "Wie spät ist es?",
        "Schreib mir ein Gedicht über 3 Katzen.",
        "Quelle est la capitale de l'Espagne ?",
        "¿Qué tiempo hace mañana?",
        "Me lembre de ligar para a minha mãe às 5.",
    ])
    func waveOneEveryday(_ question: String) {
        #expect(!PuzzleShape.detects(question))
    }

    /// The challenger's probes (2026-11-20): everyday turns that fired on the first cut.
    @Test("challenger probes: everyday turns with names, times, weekdays and homographs stay fast", arguments: [
        "How much does an M4 MacBook Pro with 16 GB cost?",
        "How much RAM does Qwen3.5-4B need?",
        "How long will iOS 27.1.2 be supported?",
        "What time does the 7:45 bus leave?",
        "How long until 17:00?",
        "Wie lange noch bis 17:00?",
        "What time does the pharmacy open on Saturday and Sunday?",
        "¿A qué hora abre la farmacia el sábado y el domingo?",
        "Que horas abre a farmácia no sábado e domingo?",
        "À quelle heure ouvre la pharmacie samedi et dimanche ?",
        "Wer ist am Montag im Büro? Und am Dienstag?",
        "How much is a double room for one night?",
        "How long does delivery take once I order, and once it ships?",
        "Combien coûte un iPhone 16 neuf ?",
        "¿Cuánto cuesta un coche de segunda mano con 50.000 km?",
        "Quanto custa o ingresso dos jogos para 2 pessoas?",
        "How long will the Sept 12 meeting run?",
        "Exportiere die Bilder als PNG und die Ordner als ZIP.",
        "Is Lisbon warmer than Porto and cheaper than Madrid in March?",
        "I'd rather walk than drive, other than when it rains.",
        "Who cracked the Enigma code?",
        "Ist das Kreuzworträtsel schon fertig?",
    ])
    func challengerEverydayProbes(_ question: String) {
        #expect(!PuzzleShape.detects(question))
    }

    @Test("challenger probes: real puzzles the first cut missed", arguments: [
        "Which is bigger, 9.11 or 9.9?",
        "If I roll two dice, what's the probability of getting 7?",
        "What is the next number: 2, 4, 8, 16?",
        "It's Wednesday. What day is it in 5 days?",
        "Welcher Wochentag ist 100 Tage später, wenn heute Dienstag ist?",
        "María tiene el doble de edad que su hermano, que tiene 9. ¿Qué edad tiene María?",
        "Ana é maior que Bia, e Bia é maior que Carla. Quem é a mais nova?",
        "Ana es mayor que Luis y Luis es mayor que Pedro. ¿Quién es el más joven?",
        "Marie a deux fois l'âge de son frère, qui a 9 ans. Quel âge a Marie ?",
        "Tu roules 60 km à 30 km/h puis 60 km à 60 km/h. Quelle est ta vitesse moyenne ?",
        "tengo 14 caramelos para 4 niños, cuantos sobran",
    ])
    func challengerMissedPuzzles(_ question: String) {
        #expect(PuzzleShape.detects(question))
    }

    @Test("decomposed accents read like composed ones")
    func decomposedAccents() {
        let nfd = "Tengo 14 caramelos para 4 niños. ¿Cuántos sobran?".decomposedStringWithCanonicalMapping
        #expect(PuzzleShape.detects(nfd))
    }

    @Test("asking to share, a declaration, or explicit types is not an ask to reason", arguments: [
        "¿Cómo comparto una foto?",
        "Como compartilho meu calendário?",
        "Wann ist die Steuererklärung fällig?",
        "Wo ist die Datenschutzerklärung?",
        "Make the types explicit",
    ])
    func reasoningAskBoundaries(_ question: String) {
        #expect(!PuzzleShape.asksForReasoning(question))
    }

    @Test("an explicit ask to explain or go step by step, in every wave-one language")
    func explicitReasoningAsks() {
        for ask in ["Explain how tides work", "Erklär mir, wie Gezeiten funktionieren", "Explique-moi les marées",
                    "Explícame las mareas", "Explique como funcionam as marés", "Schritt für Schritt bitte",
                    "étape par étape", "paso a paso", "passo a passo"]
        {
            #expect(PuzzleShape.asksForReasoning(ask), "\(ask)")
        }
        #expect(!PuzzleShape.asksForReasoning("Tell me a joke"))
    }
}

struct ThinkingShapePolicyTests {
    static let puzzle = PuzzleShapeTests.fixturePuzzles[7]

    @Test("off is today's policy: a fast tier answers a puzzle without thinking")
    func offUnchanged() {
        #expect(!ThinkingPolicy.shouldThink(question: Self.puzzle, hasGroundedKnowledge: false, mode: .auto,
                                            fastByDefault: true, shape: .off))
        #expect(ThinkingPolicy.stepsClause(question: Self.puzzle, mode: .auto, shape: .off, thinking: false, fastByDefault: true) == nil)
    }

    @Test("think: a fast tier thinks on a puzzle, and still not on small talk")
    func thinkArm() {
        #expect(ThinkingPolicy.shouldThink(question: Self.puzzle, hasGroundedKnowledge: false, mode: .auto,
                                           fastByDefault: true, shape: .think))
        #expect(!ThinkingPolicy.shouldThink(question: "yo, what's up?", hasGroundedKnowledge: false, mode: .auto,
                                            fastByDefault: true, shape: .think))
    }

    @Test("think: a wave-one 'explain' ask thinks like the English one")
    func thinkArmIsMultilingual() {
        #expect(ThinkingPolicy.shouldThink(question: "Erklär mir die Gezeiten", hasGroundedKnowledge: false,
                                           mode: .auto, fastByDefault: true, shape: .think))
    }

    @Test("steps: the clause is a speed-tier arm, never on a heavier brain")
    func stepsClauseSpeedTierOnly() {
        #expect(ThinkingPolicy.stepsClause(question: Self.puzzle, mode: .auto, shape: .steps, thinking: false,
                                           fastByDefault: false) == nil)
    }

    @Test("both arms think on a wave-one 'explain' ask: language parity is not the variable")
    func explainParityOnBothArms() {
        for shape in [ThinkingShapeMode.think, .steps] {
            #expect(ThinkingPolicy.shouldThink(question: "Erklär mir die Gezeiten", hasGroundedKnowledge: false,
                                               mode: .auto, fastByDefault: true, shape: shape), "\(shape)")
        }
    }

    @Test("steps: no think phase, a steps clause on a puzzle only")
    func stepsArm() {
        #expect(!ThinkingPolicy.shouldThink(question: Self.puzzle, hasGroundedKnowledge: false, mode: .auto,
                                            fastByDefault: true, shape: .steps))
        #expect(ThinkingPolicy.stepsClause(question: Self.puzzle, mode: .auto, shape: .steps, thinking: false, fastByDefault: true) != nil)
        #expect(ThinkingPolicy.stepsClause(question: "thanks pal!", mode: .auto, shape: .steps, thinking: false, fastByDefault: true) == nil)
    }

    @Test("steps: a turn that thinks anyway gets no clause (the think phase is the steps)")
    func stepsClauseYieldsToThinking() {
        #expect(ThinkingPolicy.stepsClause(question: Self.puzzle, mode: .auto, shape: .steps, thinking: true, fastByDefault: true) == nil)
    }

    @Test("the person's Always / Fast setting wins over every arm")
    func overridesWin() {
        for shape in ThinkingShapeMode.allCases {
            #expect(ThinkingPolicy.shouldThink(question: "hi", hasGroundedKnowledge: false, mode: .always,
                                               fastByDefault: true, shape: shape))
            #expect(!ThinkingPolicy.shouldThink(question: Self.puzzle, hasGroundedKnowledge: false, mode: .fast,
                                                fastByDefault: true, shape: shape))
            #expect(ThinkingPolicy.stepsClause(question: Self.puzzle, mode: .fast, shape: shape, thinking: false, fastByDefault: true) == nil)
        }
    }

    @Test("the launch argument parses, and anything else is off")
    func parsesTheArm() {
        #expect(ThinkingShapeMode(argument: "think") == .think)
        #expect(ThinkingShapeMode(argument: "steps") == .steps)
        #expect(ThinkingShapeMode(argument: "off") == .off)
        #expect(ThinkingShapeMode(argument: nil) == .off)
        #expect(ThinkingShapeMode(argument: "bogus") == .off)
    }
}
