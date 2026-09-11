import Foundation
import Testing
@testable import health_sync

struct DashboardModelsTests {
    @Test
    func briefingDecodesServerOwnedDailyDecisionAdditively() throws {
        let payload = """
        {
          "date": "2026-09-11",
          "daily_decision": {
            "id": "2026-09-11:moderate",
            "mode": "moderate",
            "label": "Moderate day",
            "reason": "Recovery signals are steady.",
            "signal_keys": ["readiness", "sleep"]
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BriefingResponse.self, from: payload)

        #expect(decoded.dailyDecision?.id == "2026-09-11:moderate")
        #expect(decoded.dailyDecision?.mode == "moderate")
        #expect(decoded.dailyDecision?.signalKeys == ["readiness", "sleep"])
    }

    @Test
    func legacyAIBriefingStillDecodesWithoutDecisionPlan() throws {
        let payload = """
        {
          "date": "2026-09-11",
          "lang": "en",
          "insight": "Legacy insight",
          "blocks": {},
          "generating": false,
          "disabled": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AIBriefingResponse.self, from: payload)

        #expect(decoded.decisionId == nil)
        #expect(decoded.plan == nil)
        #expect((decoded.freshForDecision ?? false) == false)
        #expect(decoded.insight == "Legacy insight")
    }

    @Test
    func aiBriefingDecodesFreshPlanAndEvidenceKeys() throws {
        let payload = """
        {
          "date": "2026-09-11",
          "lang": "en",
          "insight": "",
          "blocks": {},
          "generating": false,
          "disabled": false,
          "decision_id": "2026-09-11:moderate",
          "fresh_for_decision": true,
          "plan": {
            "title": "Moderate day",
            "body": "Keep training easy today.",
            "evidence_keys": ["readiness", "sleep"]
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AIBriefingResponse.self, from: payload)

        #expect(decoded.decisionId == "2026-09-11:moderate")
        #expect(decoded.freshForDecision == true)
        #expect(decoded.plan?.title == "Moderate day")
        #expect(decoded.plan?.evidenceKeys == ["readiness", "sleep"])
    }

    @Test
    func todayInsightsDecodeServerOwnedDomainsWithUnknownEnums() throws {
        let payload = """
        {
          "date": "2026-09-11",
          "decision_id": "2026-09-11:balanced",
          "snapshot_version": "snapshot-v1",
          "generation": { "state": "ready", "fresh_for_snapshot": true },
          "primary": {
            "state": "factual_context",
            "title": "Steady day",
            "observation": "Your signals are consistent.",
            "meaning": "Keep the plan comfortable.",
            "evidence_ids": ["readiness"],
            "fallback": false
          },
          "domains": [{
            "key": "sleep",
            "band": "future-band",
            "data_state": "fresh",
            "summary": "Sleep is available.",
            "insight": {
              "state": "confirmed_personal_evidence",
              "title": "Sleep held steady",
              "observation": "The night is recorded.",
              "meaning": "Recovery is supported.",
              "next_step": { "id": "wind_down", "text": "Keep tonight calm." },
              "evidence_ids": ["sleep"],
              "fallback": false
            },
            "destination": { "kind": "section", "id": "sleep" }
          }],
          "evidence": [],
          "changes": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TodayInsightsResponse.self, from: payload)

        #expect(decoded.decisionID == "2026-09-11:balanced")
        #expect(decoded.generation.freshForSnapshot)
        #expect(decoded.domains.first?.band == "future-band")
        #expect(decoded.domains.first?.insight.nextStep?.id == "wind_down")
    }
}
