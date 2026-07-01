import SwiftUI

struct AgentPlaceholderPaneView: View {
    let workspace: Workspace

    private var projectName: String {
        if let path = workspace.agentProjectPath, !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty { return name }
        }
        return workspace.displayName
    }

    private var projectPath: String? {
        guard let path = workspace.agentProjectPath, !path.isEmpty else { return nil }
        return path
    }

    var body: some View {
        ZStack {
            Theme.bgPane
            VStack(spacing: 14) {
                Image("DevinMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .shadow(color: Color(red: 0.16, green: 0.43, blue: 0.81).opacity(0.55),
                            radius: 14)

                VStack(spacing: 4) {
                    Text(projectName)
                        .font(AppFonts.ui(20, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let projectPath {
                        Text(projectPath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Text("Devin workspace is ready. The chat UI lands in the next phase.")
                    .font(AppFonts.ui(13))
                    .foregroundStyle(Theme.text3)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 340)
            }
            .padding(28)
        }
    }
}
