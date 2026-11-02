import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct ImportedPhoto: Transferable, Sendable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            ImportedPhoto(data: try PhotoProcessor.read(received.file))
        }
    }
}

struct PhotoImportView: View {
    @ObservedObject var model: PhotoImportModel
    @State private var selection: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var requestingCamera = false
    @State private var cameraDenied = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $selection, maxSelectionCount: 20, selectionBehavior: .ordered,
                             matching: .images, preferredItemEncoding: .current) {
                    Label("import.library", systemImage: "photo.on.rectangle")
                }
                .disabled(model.running)
                Button {
                    Task { await requestCamera() }
                } label: { Label("import.camera", systemImage: "camera") }
                    .disabled(model.running || requestingCamera)
                Text("import.explanation")
                if cameraDenied {
                    Text("import.cameraDenied")
                    Button("import.settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                if let message = model.message { Text(LocalizedStringKey(message)) }
                if model.running { Button("common.cancel") { model.cancel() } }
            }
            ForEach(Array(model.drafts.enumerated()), id: \.element.id) { index, draft in
                VStack(alignment: .leading) {
                    Text("\(index + 1)").font(.headline)
                    if let file = draft.file, let image = UIImage(contentsOfFile: file.path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                            .accessibilityLabel(Text("import.preview"))
                    }
                    Text(LocalizedStringKey(draft.status))
                    Button("import.remove", role: .destructive) { model.remove(draft.id) }
                        .disabled(model.running)
                }
            }
        }
        .navigationTitle("import.title")
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            let loaders: [@MainActor () async throws -> Data] = items.map { item in
                { @MainActor in
                    guard let photo = try await item.loadTransferable(type: ImportedPhoto.self) else {
                        throw PhotoImportError.invalidImage
                    }
                    return photo.data
                }
            }
            model.start(loaders)
            selection = []
        }
        .sheet(isPresented: $showCamera) {
            CameraCapture { data in
                showCamera = false
                if let data { model.start([{ data }]) }
            }
        }
    }

    @MainActor private func requestCamera() async {
        requestingCamera = true
        defer { requestingCamera = false }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            model.message = "import.cameraUnavailable"
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        else { allowed = status == .authorized }
        cameraDenied = !allowed
        showCamera = allowed
    }
}

private struct CameraCapture: UIViewControllerRepresentable {
    let completion: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Data?) -> Void
        init(completion: @escaping (Data?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // UIImage's JPEG representation preserves the capture orientation for ImageIO.
            let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.95)
            // Empty data enters the normal per-item failure path; cancellation creates no draft.
            completion(data ?? Data())
        }
    }
}
