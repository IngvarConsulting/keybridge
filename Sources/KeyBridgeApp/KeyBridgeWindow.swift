// SPDX-License-Identifier: MIT
import AppKit
import Combine
import SwiftUI

@MainActor
final class KeyBridgeWindowController: NSViewController {
    private let model: AppModel
    private let interface: KeyBridgeInterfaceState
    private let initialContentSize: NSSize
    private var observations: AnyCancellable?
    init(model: AppModel, contentSize: NSSize) {
        self.model = model
        self.interface = KeyBridgeInterfaceState(send: { [weak model] in model?.receive($0) })
        self.initialContentSize = contentSize
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func loadView() {
        let hosting = NSHostingController(rootView: KeyBridgeNativeView(interface: interface))
        addChild(hosting)
        view = NSView(frame: NSRect(origin: .zero, size: initialContentSize))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        interface.update(model.payload)
        observations = model.$payload.sink { [weak interface] in interface?.update($0) }
        model.navigate = { [weak interface] in interface?.navigate($0) }
    }
}
