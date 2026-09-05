//
//  ChatEvalModelOverride.swift
//  M1K3Eval
//
//  Resolves the CHATEVAL A/B hook (`M1K3_SELFTEST_CHATEVAL_MLX_MODEL`) for ONE
//  tier of a run. Two forms:
//
//    • a bare hub id / local path — applies only when exactly ONE MLX brain is
//      in the run. With two, the old behaviour applied it to both, which ran
//      the same model twice under two column names and produced a matrix that
//      compared a model with itself. That is now a refusal with the fix in it.
//    • `lil=<id>,big=<id>` — per-tier, so a two-brain A/B can pit two
//      challengers against each other by name. An unselected tier's entry is
//      ignored; a key that names no selected tier is refused (a typo must not
//      silently read as "stock").
//
//  Pure — the SelfTest stage owns the env read and the emit.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.9. Prior: Unknown

import Foundation

public enum ChatEvalModelOverride {
    public enum Resolution: Equatable, Sendable {
        /// Run the tier's stock model.
        case stock
        /// Run this hub id / local path in the tier's place.
        case override(String)
        /// The override is ambiguous or malformed; skip the tier and say why.
        case refused(String)
    }

    /// - Parameters:
    ///   - raw: the env value, or nil when unset.
    ///   - tier: the tier being resolved (`BrainTier.rawValue`).
    ///   - mlxTiersSelected: the MLX-backed tiers in this run, in run order.
    public static func resolve(raw: String?, tier: String, mlxTiersSelected: [String]) -> Resolution {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .stock
        }
        guard mlxTiersSelected.contains(tier) else { return .stock }

        let entries = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let keyed = entries.filter { $0.contains("=") }.count
        // A mix of bare ids and tier=id entries (a dangling comma yields an empty
        // entry, which is unkeyed) is neither form — name that, rather than the
        // bare-id refusal that would mislead.
        if keyed > 0, keyed != entries.count {
            return .refused(
                "mixed override '\(raw)' — use EITHER one bare id (single MLX brain) OR only <tier>=<id> entries"
            )
        }
        let isPerTier = keyed == entries.count
        guard isPerTier else {
            if entries.count == 1, mlxTiersSelected.count == 1 { return .override(entries[0]) }
            let selected = mlxTiersSelected.joined(separator: ",")
            let example = mlxTiersSelected.map { "\($0)=<id>" }.joined(separator: ",")
            return .refused(
                "a bare M1K3_SELFTEST_CHATEVAL_MLX_MODEL would apply to every MLX brain (\(selected)) — "
                    + "use the per-tier form \(example), or select one brain"
            )
        }

        var byTier: [String: String] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[1].isEmpty else {
                return .refused("malformed override entry '\(entry)' — expected <tier>=<id>")
            }
            guard mlxTiersSelected.contains(parts[0]) else {
                return .refused(
                    "override names '\(parts[0])', which is not a selected MLX brain (\(mlxTiersSelected.joined(separator: ",")))"
                )
            }
            guard byTier[parts[0]] == nil else {
                return .refused("override names '\(parts[0])' twice — one entry per tier")
            }
            byTier[parts[0]] = parts[1]
        }
        return byTier[tier].map(Resolution.override) ?? .stock
    }
}
