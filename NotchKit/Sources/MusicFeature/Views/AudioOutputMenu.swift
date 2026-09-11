import CoreAudio
import SwiftUI

/// Speaker button that lists output devices; picking one changes the system default.
struct AudioOutputMenu: View {
    @State private var devices: [AudioOutputDevices.Device] = []
    @State private var current: AudioDeviceID?

    var body: some View {
        Menu {
            ForEach(devices) { device in
                Button {
                    AudioOutputDevices.setDefaultOutput(device.id)
                    current = device.id
                } label: {
                    if device.id == current { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                }
            }
        } label: {
            Image(systemName: "hifispeaker")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear {
            devices = AudioOutputDevices.outputs()
            current = AudioOutputDevices.defaultOutputID()
        }
    }
}
