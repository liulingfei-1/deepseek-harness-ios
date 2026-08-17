import SwiftUI
import UIKit

@MainActor
struct CameraPicker: UIViewControllerRepresentable {
    let completion: @MainActor (Data?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: @MainActor (Data?) -> Void

        init(completion: @escaping @MainActor (Data?) -> Void) {
            self.completion = completion
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            completion(image?.jpegData(compressionQuality: 0.9))
        }
    }
}

enum CameraPickerError: LocalizedError {
    case noImageData

    var errorDescription: String? {
        "无法读取所选图片。"
    }
}

