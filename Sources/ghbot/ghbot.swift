import Compute
import CryptoSwift
import Foundation

extension String: Error {}

struct CheckSuitePayload: Codable {
  let action: String
  let checkSuite: CheckSuite
}

struct CheckSuite: Codable {
  let headSha: String
  let status: String
  let conclusion: String
  let pullRequests: [PullRequest]

  struct PullRequest: Codable {
    let url: String
    let id: Int
    let head: Head

    struct Head: Codable {
      let sha: String
    }
  }
}
struct PullRequest: Codable {
  let id: Int
  let labels: [Label]

  struct Label: Codable {
    let id: Int
    let name: String
  }
}

@main
struct Ghbot {
  static func main() async throws {
    try await onIncomingRequest { req, res in
      let env = try Compute.Dictionary(name: "env")
      let secret = env.get("GITHUB_WEBHOOK_SECRET")
      guard let token = env.get("GITHUB_TOKEN") else {
        throw "No GITHUB_TOKEN"
      }

      func validateSignature(payload: [UInt8]) async throws -> Bool {
        guard let secret = secret else {
          // noop for development
          return true
        }
        let hmac = try HMAC(key: secret, variant: .sha2(.sha256))
        let expected =
          try "sha256=" + hmac.authenticate(payload).map { String(format: "%02hhx", $0) }.joined()
        return req.headers.get("x-hub-signature-256") == expected
      }

      guard case (.post, "/webhook") = (req.method, req.url.path) else {
        try await res.status(404).send()
        return
      }

      let payloadBytes = try await req.body.bytes()
      guard try await validateSignature(payload: payloadBytes) else {
          try await res.status(500).send("Signatures didn't match!")
          return
      }

      let event = req.headers.get("x-github-event")
      switch event {
      case "ping":
        let payload = try JSONSerialization.jsonObject(with: Data(payloadBytes), options: [])
        let headers = req.headers.dictionary()
        print("headers:", headers)
        print("payload:", payload)
        try await res.status(200).send("OK")
      case "check_suite":
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(CheckSuitePayload.self, from: Data(payloadBytes))
        guard payload.action == "completed",
          payload.checkSuite.status == "completed",
          payload.checkSuite.conclusion == "success",
          payload.checkSuite.pullRequests.count == 1,
          payload.checkSuite.pullRequests[0].head.sha == payload.checkSuite.headSha
        else {
          try await res.status(200).send("Skip")
          return
        }
        let prURL = payload.checkSuite.pullRequests[0].url

        let prResponse = try await fetch(
          prURL,
          .options(
            headers: [
              "Accept": "application/vnd.github.v3+json",
              "Authorization": "token \(token)",
              "User-Agent": "swiftwasm-ghbot",
            ], backend: "api.github.com"))
        let pr = try await prResponse.decode(PullRequest.self)

        let isMergeable = pr.labels.contains(where: {
          $0.name == ":arrow_heading_down: Upstream Tracking"
        })
        guard isMergeable else {
          try await res.status(200).send("Skip")
          return
        }
        let mergeEndpoint = "\(prURL)/merge"
        _ = try await fetch(
          mergeEndpoint,
          .options(
            method: .put,
            body: .text("{\"merge_method\": \"merge\"}"),
            headers: [
              "Accept": "application/vnd.github.v3+json",
              "Authorization": "token \(token)",
              "User-Agent": "swiftwasm-ghbot",
            ]
          )
        )
        try await res.status(200).send("Done")
      default:
        try await res.status(404).send()
        return
      }
    }
  }
}
