//
//  LocalModelConfig.swift
//  M1K3MLX
//
//  Reads `model_type` from a downloaded repo's config.json — the one field that
//  names the architecture regardless of what the repo is called. The tool
//  dialect resolver keys on it first (a "Qwen3.8" repo is model_type qwen3_5
//  and speaks the XML function dialect; the name heuristic alone read the
//  "qwen" substring and picked JSON). Quiet on every failure: before the first
//  download there is no config.json, and the name heuristic still applies.
//
//  This is a synchronous read of a ~1–5 KB file, and MLXGemmaProvider.init
//  calls it from main-actor sites (selectBrain, the Mini→Big escalation).
//  Measured class: sub-millisecond on APFS. If it is ever observed on a
//  trace, hoist the read to the provider's async load path (review 1, #212).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.85. Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-10 — `chatTemplate(forRepoID:)` (#264): the template text,
//  from chat_template.jinja or tokenizer_config.json's chat_template, for the post-load think-trait read.
//  Confidence now 0.85.

import Foundation
import Hub

public enum LocalModelConfig {
    /// The top-level `model_type` in `<directory>/config.json`, or nil when the
    /// file is absent, unreadable, malformed, or lacks the key.
    public static func modelType(inDirectory directory: URL) -> String? {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["model_type"] as? String, !type.isEmpty
        else { return nil }
        return type
    }

    /// Same, resolved through the LLM store's own path rule for a hub id (the
    /// LocalModelInventory never-drift rule: detection and download share one
    /// location). A local-path id (an A/B fused dir) is read directly.
    static func modelType(forRepoID repoID: String) -> String? {
        modelType(inDirectory: directory(forRepoID: repoID))
    }

    /// The chat template text: `chat_template.jinja` when the repo ships one,
    /// else `tokenizer_config.json`'s `chat_template` string. nil when absent
    /// (before the first download) or unreadable.
    public static func chatTemplate(inDirectory directory: URL) -> String? {
        if let text = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8),
           !text.isEmpty
        {
            return text
        }
        let url = directory.appendingPathComponent("tokenizer_config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["chat_template"] as? String, !text.isEmpty
        else { return nil }
        return text
    }

    static func chatTemplate(forRepoID repoID: String) -> String? {
        chatTemplate(inDirectory: directory(forRepoID: repoID))
    }

    private static func directory(forRepoID repoID: String) -> URL {
        if repoID.hasPrefix("/") || repoID.hasPrefix("~") {
            return URL(fileURLWithPath: (repoID as NSString).expandingTildeInPath)
        }
        return HubApiDownloader.llmDefault.hub.localRepoLocation(Hub.Repo(id: repoID))
    }
}
