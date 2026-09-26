import SwiftUI

struct NewRecordingView: View {
    @Binding var isPresented: Bool
    @StateObject private var viewModel = NewRecordingViewModel()

    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack {
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Title
            VStack(spacing: 8) {
                Image(systemName: viewModel.isRecording ? "record.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(viewModel.isRecording ? .red : .accentColor)

                Text(viewModel.isRecording ? "正在录音" : "新建录音")
                    .font(.title)
                    .fontWeight(.bold)

                if viewModel.isRecording {
                    Text(viewModel.formattedDuration)
                        .font(.system(size: 32, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }

            // Audio source selection (disabled during recording)
            if !viewModel.isRecording {
                VStack(alignment: .leading, spacing: 8) {
                    Text("录音源")
                        .font(.headline)

                    Picker("", selection: $viewModel.selectedSource) {
                        Text("麦克风").tag(AudioSource.microphone)
                        Text("系统音频").tag(AudioSource.systemAudio)
                        Text("混合").tag(AudioSource.mixed)
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.isRecording)
                }
            }

            // Waveform visualization during recording
            if viewModel.isRecording {
                AudioWaveformView(levels: viewModel.audioLevels, isPlaying: true)
                    .frame(height: 80)
                    .padding(.horizontal)
            }

            // Main action button
            Button(action: {
                Task {
                    if viewModel.isRecording {
                        await viewModel.stopRecording()
                        isPresented = false
                    } else {
                        await viewModel.startRecording()
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                    Text(viewModel.isRecording ? "停止录音" : "开始录音")
                }
                .font(.headline)
                .frame(maxWidth: 200)
                .padding()
                .background(viewModel.isRecording ? Color.red : Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isPreparing)

            if viewModel.isPreparing {
                ProgressView("准备中...")
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
        .frame(width: 480, height: 500)
    }
}
