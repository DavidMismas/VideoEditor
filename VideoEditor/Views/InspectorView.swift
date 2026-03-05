import SwiftUI

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

// Sub-components
struct BasicAdjustmentsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = true
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Exposure", value: $adjustments.exposure, range: -5...5)
                SliderRow(title: "Contrast", value: $adjustments.contrast, range: -1...3)
                SliderRow(title: "Highlights", value: $adjustments.highlights, range: -2...2)
                SliderRow(title: "Shadows", value: $adjustments.shadows, range: -2...2)
            }
            .padding(.top, 8)
        } label: {
            Text("Basic Settings").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct DetailAdjustmentsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Clarity", value: $adjustments.clarity, range: -1...1)
                SliderRow(title: "Sharpness", value: $adjustments.sharpness, range: 0...2)
            }
            .padding(.top, 8)
        } label: {
            Text("Details").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct BasicColorSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Saturation", value: $adjustments.saturation, range: 0...2)
                SliderRow(title: "Luminance", value: $adjustments.luminance, range: -1...1)
            }
            .padding(.top, 8)
        } label: {
            Text("Basic Color").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
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
    }
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                Picker("", selection: $selectedColor) {
                    ForEach(HSLColorChannel.allCases) { color in
                        Text(color.rawValue).tag(color)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                HSLControlView(hsl: binding(for: selectedColor))
            }
            .padding(.top, 8)
        } label: {
            Text("True HSL").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
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
    var body: some View {
        VStack(spacing: 12) {
            HueSliderRow(title: "Hue Shift", value: $hsl.hue, range: -1...1)
            SliderRow(title: "Saturation", value: $hsl.saturation, range: 0...2)
            SliderRow(title: "Luminance", value: $hsl.luminance, range: -1...1)
        }
    }
}

struct ColorGradingSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 16) {
                ColorWheelRow(title: "Global", wheel: $adjustments.globalTint)
                ColorWheelRow(title: "Shadows", wheel: $adjustments.shadowTint)
                ColorWheelRow(title: "Highlights", wheel: $adjustments.highlightTint)
            }
            .padding(.top, 8)
        } label: {
            Text("Color Grading").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct ColorWheelRow: View {
    var title: String
    @Binding var wheel: ColorWheelControl
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption).bold().foregroundColor(Theme.textSecondary)
            HueSliderRow(title: "Tint Hue", value: $wheel.hue, range: 0...6.28)
            SliderRow(title: "Intensity", value: $wheel.intensity, range: 0...1)
        }
    }
}

struct EffectsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Vignette", value: $adjustments.vignette, range: 0...2)
                SliderRow(title: "Soft Blur", value: $adjustments.softBlur, range: 0...10)
                SliderRow(title: "Film Grain", value: $adjustments.grain, range: 0...1)
            }
            .padding(.top, 8)
        } label: {
            Text("Effects").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct ExportSection: View {
    var viewModel: EditorViewModel
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Format").foregroundColor(Theme.textSecondary)
                Picker("", selection: .constant("mp4")) {
                    Text("MP4 (H.264)").tag("mp4")
                    Text("HEVC (H.265)").tag("hevc")
                    Text("MOV (ProRes)").tag("mov")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                Button(action: {
                    print("Export clicked")
                }) {
                    Text("Export Video")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.accentGreen)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.top, 8)
        } label: {
            Text("Export").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundColor(Theme.textSecondary)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundColor(Theme.accentPink)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
                .tint(Theme.accentPink)
        }
    }
}

struct HueSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    
    let hueGradient = LinearGradient(
        colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
        startPoint: .leading, endPoint: .trailing
    )
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundColor(Theme.textSecondary)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundColor(Theme.accentPink)
                    .font(.caption.monospacedDigit())
            }
            // A custom background behind the slider
            Slider(value: $value, in: range)
                .background(hueGradient.opacity(0.6).cornerRadius(4))
        }
    }
}
