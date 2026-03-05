import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var viewModel: EditorViewModel
    
    // Binding directly to the active adjustments proxy in the ViewModel
    // This allows real-time updates of the selected clip's properties.
    var baseAdjustments: Binding<ColorAdjustments> {
        Binding(
            get: { viewModel.activeAdjustments },
            set: { viewModel.activeAdjustments = $0 }
        )
    }
    
    private var hasActiveClipSelection: Bool {
        viewModel.selectedClipId != nil || viewModel.isolatedClip != nil
    }
    
    var body: some View {
        VStack {
            Text("Inspector")
                .font(.headline)
                .foregroundColor(Theme.textMain)
                .padding(.vertical, 10)
            
            Divider()
                .background(Theme.separator)
            
            ScrollView {
                VStack(spacing: 16) {
                    LUTLibrarySection(viewModel: viewModel)
                    
                    if !hasActiveClipSelection {
                        Text("No clip selected. Controls remain visible.")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    BasicAdjustmentsSection(adjustments: baseAdjustments)
                    DetailAdjustmentsSection(adjustments: baseAdjustments)
                    BasicColorSection(adjustments: baseAdjustments)
                    TrueHSLSection(adjustments: baseAdjustments)
                    ColorGradingSection(adjustments: baseAdjustments)
                    EffectsSection(adjustments: baseAdjustments)
                    ExportSection(viewModel: viewModel)
                }
                .padding()
            }
        }
        .background(Theme.panelBackground)
    }
}

struct LUTLibrarySection: View {
    @Bindable var viewModel: EditorViewModel
    @State private var isExpanded: Bool = true
    @State private var importMessage: String?
    
    var body: some View {
        InspectorSection(title: "LUT Library", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: importLUTAction) {
                    Label("Import LUT", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(Theme.accentGreen.opacity(0.85))
                        .foregroundColor(.black)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                if viewModel.importedLUTs.isEmpty {
                    Text("No LUT imported. Add .cube files and drag them onto the middle Clip Editor timeline.")
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(viewModel.importedLUTs) { lut in
                            HStack(spacing: 8) {
                                Image(systemName: "cube.transparent")
                                    .foregroundColor(Theme.accentGreen)
                                Text(lut.name)
                                    .font(.caption)
                                    .foregroundColor(Theme.textMain)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Theme.panelBackground.opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
                            )
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                            .draggable("lut:\(lut.id.uuidString)")
                        }
                    }
                }
                
                if let importMessage {
                    Text(importMessage)
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }
    
    private func importLUTAction() {
        let panel = NSOpenPanel()
        panel.title = "Import LUT"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        let cubeType = UTType(filenameExtension: "cube") ?? .data
        panel.allowedContentTypes = [cubeType]
        
        guard panel.runModal() == .OK else { return }
        
        var importedCount = 0
        var rejectedCount = 0
        for url in panel.urls {
            if viewModel.importLUT(url: url) {
                importedCount += 1
            } else {
                rejectedCount += 1
            }
        }
        
        if rejectedCount > 0 {
            importMessage = "Imported \(importedCount) LUT(s), rejected \(rejectedCount) invalid file(s)."
        } else if importedCount > 0 {
            importMessage = "Imported \(importedCount) LUT(s). Drag LUT onto the middle Clip Editor timeline."
        } else {
            importMessage = "No new LUT imported."
        }
    }
}

struct InspectorSection<Content: View>: View {
    var title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text(title)
                        .bold()
                        .foregroundColor(Theme.textMain)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.accentPink)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                content()
                    .padding(.top, 8)
            }
        }
    }
}

// Sub-components
struct BasicAdjustmentsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = true
    
    var body: some View {
        InspectorSection(title: "Basic Settings", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Exposure", value: $adjustments.exposure, range: -5...5)
                SliderRow(title: "Contrast", value: $adjustments.contrast, range: 0.7...1.3)
                SliderRow(title: "Highlights", value: $adjustments.highlights, range: -2...2)
                SliderRow(title: "Shadows", value: $adjustments.shadows, range: -2...2)
            }
        }
    }
}

struct DetailAdjustmentsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        InspectorSection(title: "Details", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Clarity", value: $adjustments.clarity, range: -1...1)
                SliderRow(title: "Sharpness", value: $adjustments.sharpness, range: 0...2)
            }
        }
    }
}

struct BasicColorSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        InspectorSection(title: "Basic Color", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Saturation", value: $adjustments.saturation, range: 0...2)
                SliderRow(title: "Vibrance", value: $adjustments.vibrance, range: -1...1)
            }
        }
    }
}

struct TrueHSLSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    @State private var selectedColor: HSLColorChannel = .red
    
    enum HSLColorChannel: String, CaseIterable, Identifiable {
        case red = "Red", orange = "Orange", yellow = "Yellow", green = "Green"
        case aqua = "Aqua", blue = "Blue", purple = "Purple", magenta = "Magenta"
        var id: String { self.rawValue }
        
        var baseHue: Double {
            switch self {
            case .red: return 0.0
            case .orange: return 1.0 / 12.0
            case .yellow: return 1.0 / 6.0
            case .green: return 1.0 / 3.0
            case .aqua: return 0.5
            case .blue: return 2.0 / 3.0
            case .purple: return 0.75
            case .magenta: return 5.0 / 6.0
            }
        }
        
        var accentColor: Color {
            Color(hue: baseHue, saturation: 0.95, brightness: 0.95)
        }
    }
    
    var body: some View {
        InspectorSection(title: "True HSL", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                Picker("", selection: $selectedColor) {
                    ForEach(HSLColorChannel.allCases) { color in
                        Text(color.rawValue).tag(color)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                HSLControlView(hsl: binding(for: selectedColor), channel: selectedColor)
                SliderRow(
                    title: "HSL Tightness",
                    value: $adjustments.hslTightness,
                    range: 0.20...1.00,
                    tint: selectedColor.accentColor
                )
            }
        }
    }
    
    private func binding(for channel: HSLColorChannel) -> Binding<HSLControl> {
        Binding {
            switch channel {
            case .red: return adjustments.redHSL
            case .orange: return adjustments.orangeHSL
            case .yellow: return adjustments.yellowHSL
            case .green: return adjustments.greenHSL
            case .aqua: return adjustments.aquaHSL
            case .blue: return adjustments.blueHSL
            case .purple: return adjustments.purpleHSL
            case .magenta: return adjustments.magentaHSL
            }
        } set: { newValue in
            switch channel {
            case .red: adjustments.redHSL = newValue
            case .orange: adjustments.orangeHSL = newValue
            case .yellow: adjustments.yellowHSL = newValue
            case .green: adjustments.greenHSL = newValue
            case .aqua: adjustments.aquaHSL = newValue
            case .blue: adjustments.blueHSL = newValue
            case .purple: adjustments.purpleHSL = newValue
            case .magenta: adjustments.magentaHSL = newValue
            }
        }
    }
}

struct HSLControlView: View {
    @Binding var hsl: HSLControl
    var channel: TrueHSLSection.HSLColorChannel
    
    private var activeHueUnit: Double {
        wrappedHue(channel.baseHue + (hsl.hue * 0.1666))
    }
    
    private var hueShiftTint: Color {
        Color(hue: activeHueUnit, saturation: 0.95, brightness: 0.95)
    }
    
    private var saturationTint: Color {
        let normalizedSat = min(max(hsl.saturation / 2.0, 0.05), 1.0)
        return Color(hue: activeHueUnit, saturation: normalizedSat, brightness: 0.95)
    }
    
    private var luminanceTint: Color {
        let brightness = min(max(0.5 + (hsl.luminance * 0.35), 0.15), 1.0)
        let sat = min(max(hsl.saturation / 2.0, 0.15), 1.0)
        return Color(hue: activeHueUnit, saturation: sat, brightness: brightness)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            SliderRow(
                title: "Hue Shift",
                value: $hsl.hue,
                range: -1...1,
                tint: hueShiftTint
            )
            SliderRow(
                title: "Saturation",
                value: $hsl.saturation,
                range: 0...2,
                tint: saturationTint
            )
            SliderRow(
                title: "Luminance",
                value: $hsl.luminance,
                range: -1...1,
                tint: luminanceTint
            )
        }
    }
    
    private func wrappedHue(_ hue: Double) -> Double {
        var wrapped = hue.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        return wrapped
    }
}

struct ColorGradingSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    private var shadowRangeTint: Color {
        let hueUnit = wrappedHue(adjustments.shadowTint.hue / (Double.pi * 2.0))
        let saturation = min(max(0.94 + (adjustments.shadowTint.intensity * 0.06), 0.94), 1.0)
        let brightness = min(max(0.62 + (adjustments.shadowTint.intensity * 0.20), 0.62), 0.82)
        return Color(hue: hueUnit, saturation: saturation, brightness: brightness)
    }
    
    private var highlightRangeTint: Color {
        let hueUnit = wrappedHue(adjustments.highlightTint.hue / (Double.pi * 2.0))
        let saturation = min(max(0.90 + (adjustments.highlightTint.intensity * 0.10), 0.90), 1.0)
        let brightness = min(max(0.80 + (adjustments.highlightTint.intensity * 0.16), 0.80), 0.96)
        return Color(hue: hueUnit, saturation: saturation, brightness: brightness)
    }
    
    var body: some View {
        InspectorSection(title: "Color Grading", isExpanded: $isExpanded) {
            VStack(spacing: 16) {
                ColorWheelRow(title: "Global", wheel: $adjustments.globalTint)
                ColorWheelRow(title: "Shadows", wheel: $adjustments.shadowTint)
                SliderRow(title: "Shadow Range", value: $adjustments.shadowRange, range: 0.20...0.70, tint: shadowRangeTint)
                ColorWheelRow(title: "Highlights", wheel: $adjustments.highlightTint)
                SliderRow(title: "Highlights Range", value: $adjustments.highlightRange, range: 0.55...0.98, tint: highlightRangeTint)
            }
        }
    }
    
    private func wrappedHue(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        return wrapped
    }
}

struct ColorWheelRow: View {
    var title: String
    @Binding var wheel: ColorWheelControl
    
    private var tintColor: Color {
        let hueUnit = wrappedHue(wheel.hue / (Double.pi * 2.0))
        let saturation = min(max(0.93 + (wheel.intensity * 0.07), 0.93), 1.0)
        let brightness = min(max(0.70 + (wheel.intensity * 0.20), 0.70), 0.90)
        return Color(hue: hueUnit, saturation: saturation, brightness: brightness)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption).bold().foregroundColor(Theme.textSecondary)
            HueSliderRow(title: "Tint Hue", value: $wheel.hue, range: 0...(Double.pi * 2.0), tint: tintColor)
            SliderRow(title: "Intensity", value: $wheel.intensity, range: 0...1, tint: tintColor)
        }
    }
    
    private func wrappedHue(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        return wrapped
    }
}

struct EffectsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        InspectorSection(title: "Effects", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Vignette", value: $adjustments.vignette, range: 0...2)
                SliderRow(title: "Soft Blur", value: $adjustments.softBlur, range: 0...10)
                SliderRow(title: "Film Grain", value: $adjustments.grain, range: 0...1)
            }
        }
    }
}

@MainActor
struct ExportSection: View {
    var viewModel: EditorViewModel
    @State private var isExpanded: Bool = false
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0
    @State private var exportMessageTitle: String = "Export"
    @State private var exportMessageBody: String = ""
    @State private var showExportAlert: Bool = false
    
    var body: some View {
        InspectorSection(title: "Export", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Format").foregroundColor(Theme.textSecondary)
                Picker(
                    "",
                    selection: Binding(
                        get: { viewModel.exportFormat },
                        set: { viewModel.exportFormat = $0 }
                    )
                ) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                if isExporting {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: exportProgress, total: 1.0)
                            .tint(Theme.accentGreen)
                        Text("Export progress: \(Int((exportProgress * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                
                Button(action: startExportFlow) {
                    HStack(spacing: 8) {
                        if isExporting {
                            ProgressView(value: exportProgress, total: 1.0)
                                .controlSize(.small)
                                .tint(.black)
                                .frame(width: 42)
                        }
                        Text(isExporting ? "Exporting..." : "Export Video")
                    }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.accentGreen)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                }
                .disabled(isExporting)
                .opacity(isExporting ? 0.75 : 1.0)
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .alert(exportMessageTitle, isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessageBody)
        }
    }
    
    private func startExportFlow() {
        guard !isExporting else { return }
        
        let selectedFormat = viewModel.exportFormat
        guard let destinationURL = presentSavePanel(for: selectedFormat) else {
            return
        }
        
        isExporting = true
        exportProgress = 0
        Task {
            do {
                try await viewModel.exportBottomTimeline(
                    to: destinationURL,
                    format: selectedFormat,
                    onProgress: { progress in
                        exportProgress = progress
                    }
                )
                exportProgress = 1
                exportMessageTitle = "Export Complete"
                exportMessageBody = "Video saved to:\n\(destinationURL.path)"
                showExportAlert = true
            } catch {
                exportMessageTitle = "Export Failed"
                exportMessageBody = error.localizedDescription
                showExportAlert = true
            }
            isExporting = false
        }
    }
    
    private func presentSavePanel(for format: ExportFormat) -> URL? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                presentSavePanel(for: format)
            }
        }
        
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "TimelineExport.\(format.preferredExtension)"
        panel.title = "Export Video"
        panel.prompt = "Export"
        
        guard panel.runModal() == .OK, var url = panel.url else {
            return nil
        }
        
        if url.pathExtension.isEmpty {
            url.appendPathExtension(format.preferredExtension)
        }
        return url
    }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color = Theme.accentPink
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundColor(Theme.textSecondary)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundColor(tint)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
                .tint(tint)
        }
    }
}

struct HueSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color = Theme.accentPink
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundColor(Theme.textSecondary)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundColor(tint)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
                .tint(tint)
        }
    }
}
