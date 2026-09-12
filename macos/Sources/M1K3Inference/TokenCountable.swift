//
//  TokenCountable.swift
//  M1K3Inference
//
//  Optional capability: an inference provider that can report exact token
//  counts for text. Only AppleFoundationModelsProvider conforms today (via
//  SystemLanguageModel.tokenCount(for:), macOS 26.4+). MLX has no equivalent
//  SDK method — its budget stays on the chars/token heuristic.
//
//  The budget policy and composition root use this to replace the standing
//  charsPerToken estimate with exact numbers: the [SPIKE] resolved.

import Foundation

public protocol TokenCountable: Sendable {
    func tokenCount(forInstructions text: String) async throws -> Int
    func tokenCount(forPrompt text: String) async throws -> Int
}
