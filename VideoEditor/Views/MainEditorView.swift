import SwiftUI

struct MainEditorView: View {
    @Bindable var viewModel: EditorViewModel
    private let sidePanelWidth: CGFloat = 280
    
    var body: some View {
        HSplitView {
            // Left: Library
            MediaLibraryView(viewModel: viewModel)
                .frame(minWidth: 240, idealWidth: sidePanelWidth, maxWidth: 340)
            
            // Center: Workspaces
            CenterWorkspaceView(viewModel: viewModel)
                .frame(minWidth: 600, idealWidth: .infinity, maxWidth: .infinity)
            
            // Right: Inspector
            InspectorView(viewModel: viewModel)
                .frame(minWidth: 240, idealWidth: sidePanelWidth, maxWidth: 340)
        }
        // Applying global dark theme traits
        .colorScheme(.dark)
        .background(Theme.backgroundDark)
    }
}
