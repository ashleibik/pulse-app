import SwiftUI
import UIKit
import SwiftData
import AuthenticationServices

/// Settings sections for the optional cloud features: your own Supabase project (for the Claude
/// connector and the coach) and Strava. Nothing here is needed for the app to work.
/// Mono design (ios/design/DESIGN.md).
struct CloudSettingsView: View {
    @Environment(CloudManager.self) private var cloud
    @Environment(\.modelContext) private var context
    /// Apple's sign-in sheet for web logins (used for Strava). It returns the address the login
    /// ended on, without the app having to register a URL scheme.
    @Environment(\.webAuthenticationSession) private var webAuthentication

    @State private var projectURL = ""
    @State private var publishableKey = ""
    @State private var email = ""
    @State private var password = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            cloudSection
            if cloud.isSignedIn {
                claudeSection
                stravaSection
            }
        }
    }

    // MARK: - Cloud

    @ViewBuilder
    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Cloud")
                .padding(.bottom, DS.Space.s)

            if !cloud.isConfigured {
                field("Project URL", text: $projectURL, prompt: "https://xxxx.supabase.co")
                    .keyboardType(.URL)
                field("Publishable key", text: $publishableKey, prompt: "sb_publishable_…")
                Button("Save") {
                    Task { await cloud.configure(projectURL: projectURL, publishableKey: publishableKey) }
                }
                .buttonStyle(.secondaryPill)
                .disabled(projectURL.isEmpty || publishableKey.isEmpty)
                .padding(.top, DS.Space.m)
            } else if !cloud.isSignedIn {
                field("Email", text: $email, prompt: "you@example.com")
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                secureField("Password", text: $password)
                HStack(spacing: DS.Space.s) {
                    Button("Sign in") {
                        Task {
                            await cloud.signIn(email: email, password: password)
                            password = ""       // never kept after signing in
                        }
                    }
                    .buttonStyle(.secondaryPill)
                    .disabled(email.isEmpty || password.isEmpty)
                    Button("Remove setup") { Task { await cloud.removeSetup() } }
                        .buttonStyle(.secondaryPill)
                }
                .disabled(cloud.isWorking)
                .padding(.top, DS.Space.m)
            } else {
                ValueRow(label: "Signed in", value: cloud.email ?? "")
                Hairline()
                ValueRow(label: "Last upload",
                         value: cloud.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never",
                         emphasized: cloud.lastSync != nil)
                Hairline()
                HStack(spacing: DS.Space.s) {
                    Button("Upload now") { Task { await cloud.sync(context: context) } }
                        .buttonStyle(.secondaryPill)
                    Button("Sign out") { Task { await cloud.signOut() } }
                        .buttonStyle(.secondaryPill)
                }
                .disabled(cloud.isWorking)
                .padding(.top, DS.Space.m)
            }

            Text(cloud.message ?? "Optional. Uses your own Supabase project. Only daily summaries, sleep sessions and workouts are uploaded. Heartbeats and minute-by-minute data never leave this iPhone.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.m)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Claude connector

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Claude")
                .padding(.bottom, DS.Space.s)
            Text(cloud.connectorURL ?? "")
                .font(.footnote.monospaced())
                .foregroundStyle(DS.Colors.primary)
                .textSelection(.enabled)
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.border, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button(copied ? "Copied" : "Copy address") {
                UIPasteboard.general.string = cloud.connectorURL
                copied = true
            }
            .buttonStyle(.secondaryPill)
            .padding(.top, DS.Space.m)
            .sensoryFeedback(.success, trigger: copied)
            Text("In Claude: Settings > Connectors > Add custom connector, paste this address, then sign in with the same email and password. Claude can then read your summaries. It can't change them.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.m)
        }
    }

    // MARK: - Strava

    private var stravaSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Strava")
                .padding(.bottom, DS.Space.s)
            ValueRow(label: "Status", value: cloud.stravaConnected ? "Connected" : "Not connected",
                     symbol: "figure.run", emphasized: cloud.stravaConnected)
            Hairline()
            Button(cloud.stravaConnected ? "Disconnect" : "Connect Strava") {
                Task {
                    if cloud.stravaConnected {
                        await cloud.disconnectStrava()
                    } else {
                        await connectStrava()
                    }
                }
            }
            .buttonStyle(.secondaryPill)
            .disabled(cloud.isWorking)
            .padding(.top, DS.Space.m)
            Text("Upload only: Pulse sends workouts to Strava and never reads anything from it. Open a workout to send it. Strava's rules forbid giving its data to an AI, so nothing from Strava reaches Claude or the coach.")
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.m)
        }
    }

    private func connectStrava() async {
        guard let url = await cloud.stravaAuthorizeURL() else { return }
        do {
            let callback = try await webAuthentication.authenticate(using: url, callbackURLScheme: "pulse")
            await cloud.finishStrava(callback: callback)
        } catch {
            // The user closed the sheet: nothing to do.
        }
    }

    // MARK: - Fields

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
            TextField(label, text: text, prompt: Text(prompt))
                .textStyle(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: 52)
                .background(DS.Colors.border, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.vertical, DS.Space.s)
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .textStyle(.caption)
                .foregroundStyle(DS.Colors.secondary)
            SecureField(label, text: text)
                .textStyle(.body)
                .textContentType(.password)
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: 52)
                .background(DS.Colors.border, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.vertical, DS.Space.s)
    }
}
