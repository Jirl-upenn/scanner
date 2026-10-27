//
//  WearerHeight.swift
//  StrayScanner
//

import SwiftUI

let WearerHeightUserDefaultsKey: String = "WearerHeightCm"
let WearerHeightRangeCm: ClosedRange<Double> = 100...230

// The wearer's standing height, entered once and written to each recording's
// metadata.json. The body pipeline takes the wearer's eye height from it to place
// the head-mounted phone relative to the eyes.
func storedWearerHeightCm() -> Double? {
    let cm = UserDefaults.standard.double(forKey: WearerHeightUserDefaultsKey)
    return WearerHeightRangeCm.contains(cm) ? cm : nil
}

func formatWearerHeight(_ cm: Double) -> String {
    let totalInches = Int((cm / 2.54).rounded())
    return "\(totalInches / 12)′ \(totalInches % 12)″ (\(Int(cm.rounded())) cm)"
}

struct WearerHeightView: View {
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage(WearerHeightUserDefaultsKey) private var heightCm: Double = 0
    @State private var useFeet: Bool = !Locale.current.usesMetricSystem
    @State private var cm: String = ""
    @State private var feet: String = ""
    @State private var inches: String = ""

    private var enteredCm: Double? {
        let value: Double?
        if useFeet {
            guard let ft = Double(feet) else { return nil }
            value = (ft * 12 + (Double(inches) ?? 0)) * 2.54
        } else {
            value = Double(cm.replacingOccurrences(of: ",", with: "."))
        }
        guard let v = value, WearerHeightRangeCm.contains(v) else { return nil }
        return v
    }

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("Your standing height, without shoes. It places the phone relative to your eyes, so every recording needs it. It stays on this phone and is saved in each recording's metadata.")) {
                    Picker("Units", selection: $useFeet) {
                        Text("ft / in").tag(true)
                        Text("cm").tag(false)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    if useFeet {
                        HStack {
                            TextField("ft", text: $feet).keyboardType(.numberPad)
                            Text("ft")
                            TextField("in", text: $inches).keyboardType(.decimalPad)
                            Text("in")
                        }
                    } else {
                        HStack {
                            TextField("cm", text: $cm).keyboardType(.decimalPad)
                            Text("cm")
                        }
                    }
                }
            }
            .navigationBarTitle("Wearer height", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Cancel") { presentationMode.wrappedValue.dismiss() },
                trailing: Button("Save") {
                    if let v = enteredCm {
                        heightCm = v
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                .disabled(enteredCm == nil)
            )
            .onAppear(perform: fillFromStored)
        }
    }

    private func fillFromStored() {
        guard let stored = storedWearerHeightCm() else { return }
        cm = String(format: "%.0f", stored)
        let totalInches = (stored / 2.54).rounded()
        feet = String(Int(totalInches) / 12)
        inches = String(Int(totalInches) % 12)
    }
}

struct WearerHeightView_Previews: PreviewProvider {
    static var previews: some View {
        WearerHeightView()
    }
}
