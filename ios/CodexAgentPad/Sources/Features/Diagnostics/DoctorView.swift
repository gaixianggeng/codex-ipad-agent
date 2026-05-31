import SwiftUI

struct DoctorView: View {
    @EnvironmentObject private var appStore: AppStore
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await runDoctor() }
            } label: {
                Label("运行 Doctor", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)

            ScrollView {
                Text(output.isEmpty ? "尚未运行诊断" : output)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .navigationTitle("诊断")
    }

    private func runDoctor() async {
        do {
            let client = try appStore.client()
            let url = URL(string: AgentAPIClient.normalizedEndpoint(appStore.endpoint))!.appending(path: "/api/doctor")
            var request = URLRequest(url: url)
            request.setValue("Bearer \(appStore.token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            output = String(data: data, encoding: .utf8) ?? "诊断结果不是 UTF-8"
            _ = client
        } catch {
            output = error.localizedDescription
        }
    }
}
