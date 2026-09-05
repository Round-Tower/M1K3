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
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.85. Prior: Unknown

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
        if repoID.hasPrefix("/") || repoID.hasPrefix("~") {
            return modelType(inDirectory: URL(fileURLWithPath: (repoID as NSString).expandingTildeInPath))
        }
        return modelType(inDirectory: HubApiDownloader.llmDefault.hub.localRepoLocation(Hub.Repo(id: repoID)))
    }
}
