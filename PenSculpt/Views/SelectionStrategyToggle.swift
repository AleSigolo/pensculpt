import SwiftUI

/// Floating Lasso / Smart sub-toggle shown while in Select mode.
struct SelectionStrategyToggle: View {
    @Binding var strategy: SelectionStrategyKind

    var body: some View {
        HStack(spacing: 12) {
            button(.lasso, systemImage: "lasso", label: "Lasso")
            Divider().frame(height: 24)
            button(.smart, systemImage: "circle.dashed.inset.filled", label: "Smart")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func button(_ kind: SelectionStrategyKind, systemImage: String, label: String) -> some View {
        Button {
            strategy = kind
        } label: {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(strategy == kind ? .primary : .secondary)
        }
    }
}
