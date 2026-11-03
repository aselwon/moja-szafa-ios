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
    var repository: (any WardrobeRepository)? = nil
    @State private var selection: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var editing: PhotoImportModel.Draft?
    private struct FormDraft: Identifiable {
        let id: UUID
        let value: GarmentFormValue?
        let suggestions: GarmentSuggestions?
    }
    @State private var formDraft: FormDraft?
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
                    if let file = draft.displayFile, let image = UIImage(contentsOfFile: file.path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                            .accessibilityLabel(Text("import.preview"))
                    }
                    Text(LocalizedStringKey(draft.status))
                    if draft.file != nil {
                        Button("garment.title") {
                            do { formDraft = FormDraft(id: draft.id, value: try model.garmentValue(for: draft.id),
                                                       suggestions: try? model.recognitionSuggestions(for: draft.id)) }
                            catch { model.message = "import.storageFailed" }
                        }.disabled(model.running)
                        Button("edit.title") { editing = draft }
                            .disabled(model.running)
                    }
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
        .sheet(item: $formDraft) { draft in
            GarmentFormView(value: draft.value, suggestions: draft.suggestions, duplicateReview: {
                await model.duplicateReview(for: draft.id, repository: repository)
            }) { value in
                try model.saveGarmentValue(value, for: draft.id)
            }
        }
        .sheet(item: $editing) { draft in
            if let file = draft.file, let data = try? Data(contentsOf: file) {
                PhotoEditorView(original: data) { output in
                    model.acceptEdit(output, for: draft.id)
                }
            } else {
                Text("edit.failed").padding()
            }
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


private struct PhotoEditorView: View {
    @StateObject private var model: PhotoEditorModel
    @State private var work: Task<Void, Never>?
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss
    private let original: Data
    private let accept: (Data) -> Bool

    init(original: Data, accept: @escaping (Data) -> Bool) {
        self.original = original
        self.accept = accept
        _model = StateObject(wrappedValue: PhotoEditorModel(original: original))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("edit.originalPreserved")
                    Text("edit.before").font(.headline)
                    if let image = UIImage(data: original) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .overlay {
                                GeometryReader { geometry in
                                    Rectangle().stroke(.white, lineWidth: 3)
                                        .background(.black.opacity(0.12))
                                        .frame(width: geometry.size.width * model.crop.width,
                                               height: geometry.size.height * model.crop.height)
                                        .offset(x: geometry.size.width * (1 - model.crop.width) * model.crop.horizontal,
                                                y: geometry.size.height * (1 - model.crop.height) * model.crop.vertical)
                                }
                            }
                            .accessibilityLabel(Text("edit.before"))
                    }
                    Group {
                        cropSlider("edit.width", value: $model.crop.width, range: 0.1...1)
                        cropSlider("edit.height", value: $model.crop.height, range: 0.1...1)
                        cropSlider("edit.horizontal", value: $model.crop.horizontal, range: 0...1)
                        cropSlider("edit.vertical", value: $model.crop.vertical, range: 0...1)
                        Button("edit.reset") { model.crop = PhotoCrop() }
                        Button("edit.keepBackground") { render(removeBackground: false) }
                        Button("edit.removeBackground") { render(removeBackground: true) }
                    }.disabled(model.running)
                    if model.running { ProgressView("edit.processing") }
                    if let message = model.message { Text(LocalizedStringKey(message)) }
                    if let preview = model.preview, let image = UIImage(data: preview) {
                        Text("edit.after").font(.headline)
                        Image(uiImage: image).resizable().scaledToFit()
                            .background(Color.gray.opacity(0.25))
                            .accessibilityLabel(Text("edit.after"))
                        Button("edit.accept") {
                            if accept(preview) { dismiss() } else { saveFailed = true }
                        }.buttonStyle(.borderedProminent).disabled(model.running)
                    }
                    if saveFailed { Text("import.storageFailed") }
                }.padding()
            }
            .navigationTitle("edit.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { work?.cancel(); dismiss() }
                }
            }
        }
        .onDisappear { work?.cancel() }
    }

    private func cropSlider(_ key: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text(key)
            Slider(value: value, in: range, step: 0.01) { Text(key) }
        }
    }

    private func render(removeBackground: Bool) {
        saveFailed = false
        work = Task { await model.render(removeBackground: removeBackground) }
    }
}
