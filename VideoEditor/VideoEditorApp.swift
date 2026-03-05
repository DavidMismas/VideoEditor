//
//  VideoEditorApp.swift
//  VideoEditor
//
//  Created by David Mišmaš on 5. 3. 2026.
//

import SwiftUI
import AppIntents

@main
struct VideoEditorApp: App {
    @State private var viewModel = EditorViewModel()
    
    var body: some Scene {
        WindowGroup {
            MainEditorView(viewModel: viewModel)
                .frame(minWidth: 1300, idealWidth: 1700, minHeight: 850, idealHeight: 1050)
        }
        .defaultSize(width: 1700, height: 1050)
        .windowStyle(.hiddenTitleBar) // Modern macOS appearance
    }
}
