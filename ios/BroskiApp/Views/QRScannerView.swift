import SwiftUI
import AVFoundation

struct QRScannerView: UIViewRepresentable {
    let onScan: (String) -> Void
    func makeUIView(context: Context) -> QRCaptureView {
        let view = QRCaptureView()
        view.onScan = onScan
        return view
    }
    func updateUIView(_ uiView: QRCaptureView, context: Context) {}
}

class QRCaptureView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private var session = AVCaptureSession()

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.first?.frame = bounds
    }

    override init(frame: CGRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = bounds
        preview.videoGravity = .resizeAspectFill
        layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        if let obj = objects.first as? AVMetadataMachineReadableCodeObject, let str = obj.stringValue {
            session.stopRunning()
            onScan?(str)
        }
    }
}
