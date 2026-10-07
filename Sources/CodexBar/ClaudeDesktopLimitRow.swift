import SwiftUI

struct ClaudeDesktopLimitRow: View {
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    let showUsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(self.title).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((self.showUsed ? self.usedPercent : 100 - self.usedPercent).rounded()))% "
                    + (self.showUsed ? "usado" : "restante"))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: self.showUsed ? self.usedPercent : 100 - self.usedPercent, total: 100)
                .tint(self.usedPercent >= 90 ? .orange : .accentColor)
            if let reset = self.resetsAt {
                Text("Reinicio \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
