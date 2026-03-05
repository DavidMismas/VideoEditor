import SwiftUI
import UniformTypeIdentifiers
import CoreMedia

struct MediaLibraryView: View {
    @Bindable var viewModel: EditorViewModel
    @State private var isDropTargeted = false
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Media Library")
                .font(.headline)
                .foregroundColor(Theme.textMain)
                .padding(.horizontal)
                .padding(.top, 10)
            
            Divider()
                .background(Theme.separator)
            
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.mediaLibrary) { item in
                        MediaItemRow(item: item, isSelected: viewModel.selectedMediaLibraryItemId == item.id)
                            .onTapGesture(count: 2) {
                                isolateMediaItem(item)
                            }
                            .onTapGesture(count: 1) {
                                viewModel.selectedMediaLibraryItemId = item.id
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            
            Spacer()
            
            Button(action: importMediaAction) {
                Label("Import Media", systemImage: "plus")
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Theme.accentPink)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding()
        }
        .background(Theme.panelBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isDropTargeted ? Theme.accentPink : Color.clear, lineWidth: 2)
                .padding(6)
                .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        }
        .dropDestination(for: URL.self) { urls, _ in
            importDroppedFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .alert("Overwrite Isolated Clip?", isPresented: $showOverwriteAlert) {
            Button("Cancel", role: .cancel) {
                pendingItemToIsolate = nil
            }
            Button("Overwrite", role: .destructive) {
                if let item = pendingItemToIsolate {
                    forceIsolate(item)
                }
                pendingItemToIsolate = nil
            }
        } message: {
            Text("The currently isolated clip has unsaved color adjustments. Are you sure you want to replace it without adding it to the timeline?")
        }
    }
    
    func importMediaAction() {
        // Core functionality stub
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.movie, .audio, .image]
        openPanel.allowsMultipleSelection = true
        
        if openPanel.runModal() == .OK {
            importDroppedFiles(openPanel.urls)
        }
    }
    
    @State private var showOverwriteAlert = false
    @State private var pendingItemToIsolate: MediaItem?
    
    private func isolateMediaItem(_ item: MediaItem) {
        if let isolated = viewModel.isolatedClip {
            // Check if there are real adjustments made (a heuristic to prevent accidental overwrite)
            if isolated.adjustments != ColorAdjustments() {
                pendingItemToIsolate = item
                showOverwriteAlert = true
                return
            }
        }
        forceIsolate(item)
    }
    
    private func forceIsolate(_ item: MediaItem) {
        viewModel.isolatedClip = viewModel.makeTimelineClip(from: item)
        viewModel.selectedClipId = nil
    }
    
    private func importDroppedFiles(_ urls: [URL]) {
        for url in urls {
            guard let mediaType = mediaType(for: url) else { continue }
            let alreadyImported = viewModel.mediaLibrary.contains(where: { $0.url == url })
            if alreadyImported { continue }
            viewModel.importMedia(url: url, type: mediaType)
        }
    }
    
    private func mediaType(for url: URL) -> MediaItem.MediaType? {
        let ext = url.pathExtension.lowercased()
        
        if ["mp3", "wav", "m4a", "aac", "aiff", "flac"].contains(ext) {
            return .audio
        }
        if ["jpg", "jpeg", "png", "heic", "tiff", "gif", "webp"].contains(ext) {
            return .image
        }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm", "hevc"].contains(ext) {
            return .video
        }
        
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .audio) == true { return .audio }
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { return .video }
        
        return nil
    }
}

struct MediaItemRow: View {
    let item: MediaItem
    var isSelected: Bool
    
    var body: some View {
        HStack {
            Image(systemName: iconName(for: item.type))
                .foregroundColor(isSelected ? .white : Theme.accentGreen)
            Text(item.name)
                .foregroundColor(isSelected ? .white : Theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Theme.accentPink : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle()) // ensure the whole row is draggable and clickable
        .draggable(item.id.uuidString)
    }
    
    func iconName(for type: MediaItem.MediaType) -> String {
        switch type {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        }
    }
}
