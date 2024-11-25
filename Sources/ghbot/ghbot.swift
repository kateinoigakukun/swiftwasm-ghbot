import Compute
import CryptoSwift
import Foundation

extension String: Error {}

struct CheckSuitePayload: Codable {
  let action: String
  let checkSuite: CheckSuite
  let repository: Repository
}

struct CheckSuite: Codable {
  let headSha: String
  let status: String
  let conclusion: String
  let pullRequests: [PullRequest]

  struct PullRequest: Codable {
    let url: String
    let id: UInt64
    let head: Head

    struct Head: Codable {
      let sha: String
    }
  }
}
struct PullRequest: Codable {
  let id: UInt64
  let user: User
  let labels: [Label]

  struct User: Codable {
    let id: UInt64
  }

  struct Label: Codable {
    let id: UInt64
    let name: String
  }
}
struct Repository: Codable {
  let fullName: String
}

@main
struct Ghbot {
  static func main() async throws {
    try await onIncomingRequest { req, res in
      let env = try Fastly.ConfigStore(name: "env")
      let secret = try env.get("GITHUB_WEBHOOK_SECRET")
      guard let token = try env.get("GITHUB_TOKEN") else {
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
        try await traceError("processing check_suite event", res) {
          try await respondCheckSuiteEvent(req: req, res: res, payloadBytes: payloadBytes, token: token)
        }
      default:
        try await res.status(404).send()
        return
      }
    }
  }

  @discardableResult
  static func traceError<R>(_ name: @autoclosure () -> String, _ res: OutgoingResponse, _ body: () async throws -> R?) async throws -> R? {
    do {
      return try await body()
    } catch {
      try await res.status(500).send("Error during \(name()): \(error)")
      return nil
    }
  }

  static func respondCheckSuiteEvent(
    req: IncomingRequest, res: OutgoingResponse,
    payloadBytes: [UInt8],
    token: String
  ) async throws {
    func payloadToDisplay() -> String {
      String(data: Data(payloadBytes), encoding: .utf8) ?? "failed to decode payload"
    }
    let payload = try await traceError(
      "decoding check suite payload (payload[\(payloadBytes.count) bytes]: \(payloadToDisplay()))",
      res
    ) {
      try await decodeCheckSuitePayload(res: res, payloadBytes: payloadBytes)
    }
    guard let payload else { return }
    let prURL = payload.checkSuite.pullRequests[0].url

    let pr = try await traceError("fetching PR", res) { () -> PullRequest? in
      let prResponse = try await fetch(
        prURL,
        .options(
          headers: [
            "Accept": "application/vnd.github.v3+json",
            "Authorization": "token \(token)",
            "User-Agent": "swiftwasm-ghbot",
          ], backend: "api.github.com"))
      guard prResponse.status == 200 else {
        try await res.status(500).send("Failed to fetch PR: \(prResponse.status), \(prResponse.body)")
        return nil
      }
      return try await prResponse.decode(PullRequest.self)
    }
    guard let pr else { return }

    let isMergeable = self.isAutoMergeable(pr: pr)
    guard isMergeable else {
      try await res.status(200).send("Skip")
      return
    }
    let mergeEndpoint = "\(prURL)/merge"
    try await traceError("merging PR", res) {
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
    }
    try await res.status(200).send("Done")
  }

  static func decodeCheckSuitePayload(res: OutgoingResponse, payloadBytes: [UInt8]) async throws -> CheckSuitePayload? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let payload = try decoder.decode(CheckSuitePayload.self, from: Data(payloadBytes))
    guard payload.repository.fullName == "swiftwasm/swiftwasm-build",
      payload.action == "completed",
      payload.checkSuite.status == "completed",
      payload.checkSuite.conclusion == "success",
      payload.checkSuite.pullRequests.count == 1,
      payload.checkSuite.pullRequests[0].head.sha == payload.checkSuite.headSha
    else {
      try await res.status(200).send("Skip")
      return nil
    }
    return payload
  }

  static func isAutoMergeable(pr: PullRequest) -> Bool {
    if pr.user.id == 138581863 { // "swiftwasm-bot"
      return pr.labels.contains(where: {
        $0.name == "downstreaming"
      })
    }
    if pr.user.id == 49699333 { // "dependabot[bot]"
      return true
    }

    return false
  }
}
