import Foundation
import Observation
import SwiftData
import PulseCore

/// Cloud features as the screens see them: setup, sign-in, uploading summaries (for the Claude
/// connector and the coach), Strava, and the coach chat.
///
/// Everything here is optional. Without setup, Pulse works fully offline and uploads nothing.
/// What gets uploaded is decided by PulseCore (`CloudRows`, `StravaExport`, both tested):
/// summaries only, never raw heartbeats; simulated workouts never go to Strava.
@MainActor
@Observable
final class CloudManager {

    private(set) var config: CloudConfig?
    private(set) var email: String?
    private(set) var isWorking = false
    /// The last thing that happened, in words, for the Settings screen.
    private(set) var message: String?
    private(set) var stravaConnected = false

    private let client = CloudClient.shared
    private static let lastSyncKey = "cloudLastSync"

    var isConfigured: Bool { config?.baseURL != nil }
    var isSignedIn: Bool { email != nil }
    var lastSync: Date? { UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date }

    /// The address to paste into Claude when adding the connector.
    var connectorURL: String? {
        config?.baseURL.map { $0.appendingPathComponent("functions/v1/mcp").absoluteString }
    }

    /// Reads the saved setup from the Keychain. Call once at launch.
    func load() async {
        config = await client.currentConfig
        email = await client.signedInEmail
        if isSignedIn { await refreshStrava() }
    }

    // MARK: - Setup and sign-in

    func configure(projectURL: String, publishableKey: String) async {
        let new = CloudConfig(projectURL: projectURL.trimmingCharacters(in: .whitespacesAndNewlines),
                              publishableKey: publishableKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard new.baseURL != nil, !new.publishableKey.isEmpty else {
            message = "That doesn't look right. The URL must start with https://"
            return
        }
        await client.setConfig(new)
        config = new
        message = "Saved. Now sign in."
    }

    /// Removes the setup and the session from this iPhone. Data already uploaded stays in your
    /// project until you delete it there.
    func removeSetup() async {
        await client.setConfig(nil)
        config = nil
        email = nil
        stravaConnected = false
        message = nil
    }

    func signIn(email: String, password: String) async {
        await run("Signed in.") {
            try await self.client.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            self.email = await self.client.signedInEmail
        }
        if isSignedIn { await refreshStrava() }
    }

    func signOut() async {
        await client.signOut()
        email = nil
        stravaConnected = false
        message = "Signed out."
    }

    // MARK: - Uploading summaries

    /// Uploads every stored day, sleep session and workout summary (replacing older versions).
    func sync(context: ModelContext) async {
        guard isSignedIn else { return }
        await run(nil) {
            let days = try context.fetch(FetchDescriptor<DaySummaryRecord>()).map { CloudRows.day($0.value, calendar: .current) }
            let sleeps = try context.fetch(FetchDescriptor<SleepRecord>()).map { CloudRows.sleep($0.value) }
            let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>()).map { CloudRows.workout($0.value) }
            try await self.client.upsert(days, table: "daily_summary", onConflict: "user_id,day")
            try await self.client.upsert(sleeps, table: "sleep_session", onConflict: "user_id,id")
            try await self.client.upsert(workouts, table: "workout", onConflict: "user_id,id")
            UserDefaults.standard.set(Date.now, forKey: Self.lastSyncKey)
            self.message = "Uploaded \(days.count) days, \(sleeps.count) sleeps and \(workouts.count) workouts."
        }
    }

    // MARK: - Strava (upload only)

    private struct StravaRequest: Encodable {
        var action: String
        var tcx: String?
        var name: String?
        var external_id: String?
    }
    private struct StravaReply: Decodable {
        var url: String?
        var connected: Bool?
        var ok: Bool?
    }

    func refreshStrava() async {
        do {
            let reply: StravaReply = try await client.invoke("strava", body: StravaRequest(action: "status"))
            stravaConnected = reply.connected ?? false
        } catch {
            stravaConnected = false     // not set up on the server, or offline
        }
    }

    /// The Strava page to open in the sign-in sheet. The server keeps the client secret.
    func stravaAuthorizeURL() async -> URL? {
        var result: URL?
        await run(nil) {
            let reply: StravaReply = try await self.client.invoke("strava", body: StravaRequest(action: "start"))
            result = reply.url.flatMap(URL.init(string:))
        }
        return result
    }

    /// Called with the `pulse://strava?status=...` address the sign-in sheet ended on.
    func finishStrava(callback: URL) async {
        let status = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "status" }?.value
        switch status {
        case "connected": message = "Strava connected."
        case "no_permission": message = "Strava needs the permission to upload activities. Try again and leave it ticked."
        case "cancelled": message = "Strava was not connected."
        default: message = "Strava could not be connected. Try again."
        }
        await refreshStrava()
    }

    func disconnectStrava() async {
        await run("Strava disconnected.") {
            let _: StravaReply = try await self.client.invoke("strava", body: StravaRequest(action: "disconnect"))
            self.stravaConnected = false
        }
    }

    /// Sends one workout to Strava. Returns true when it is there (new or already uploaded).
    func uploadToStrava(_ record: WorkoutRecord, context: ModelContext) async -> Bool {
        let workout = record.value
        guard StravaExport.canUpload(workout) else {
            message = "Simulated workouts are never sent to Strava."
            return false
        }
        let minutes = PulseStore.minutes(from: workout.start, to: workout.end, in: context)
        let request = StravaRequest(action: "upload", tcx: StravaExport.tcx(for: workout, minutes: minutes),
                                    name: StravaExport.name(for: workout), external_id: StravaExport.externalID(for: workout))
        var uploaded = false
        await run("Sent to Strava.") {
            let reply: StravaReply = try await self.client.invoke("strava", body: request)
            uploaded = reply.ok ?? false
        }
        if uploaded {
            // Only our own "sent" mark is kept. Nothing Strava answers is stored (its 7-day cache rule).
            record.stravaUploadedAt = .now
            try? context.save()
        }
        return uploaded
    }

    // MARK: - Coach

    struct ChatMessage: Codable, Identifiable, Equatable {
        var id = UUID()
        var role: String        // "user" or "assistant"
        var content: String

        private enum CodingKeys: String, CodingKey { case role, content }
    }
    private struct CoachRequest: Encodable { var messages: [ChatMessage] }
    private struct CoachReply: Decodable {
        var text: String?
        var message: String?
    }

    /// Asks the coach. The conversation is kept only in memory on the phone; the server adds the
    /// user's last 14 days of summaries and forwards it to Claude.
    func askCoach(_ conversation: [ChatMessage]) async -> String {
        do {
            let reply: CoachReply = try await client.invoke("coach", body: CoachRequest(messages: conversation))
            return reply.text ?? reply.message ?? "The coach had no answer."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Helper

    /// Runs one cloud action with a busy flag, and turns errors into a readable message.
    private func run(_ success: String?, _ action: @escaping () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
            if let success { message = success }
        } catch {
            message = error.localizedDescription
        }
    }
}
