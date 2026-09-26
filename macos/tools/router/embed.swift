// embed.swift — Apple NLEmbedding sentence vectors for the tool-router trainer.
// Usage: swift embed.swift <prompts.json: [String]> <out.json: [[Double]]>
// The SAME embedding the app's NLSentenceEmbedder reads (English sentence model),
// so the weights trained here match what the router computes at runtime.
// Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.9. Prior: Unknown.
import Foundation
import NaturalLanguage

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: embed.swift <in.json> <out.json>") }
let prompts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { fatalError("no English sentence embedding") }
let vectors = prompts.map { embedding.vector(for: $0) ?? [] }
if let missing = vectors.firstIndex(where: \.isEmpty) { fatalError("no vector for prompt \(missing)") }
try JSONEncoder().encode(vectors).write(to: URL(fileURLWithPath: args[2]))
