//
//  ARViewContainer.swift
//  AR_Scanning
//

import SwiftUI
import ARKit
import RealityKit

/// RealityKitのARViewをSwiftUIで使えるようにするUIViewRepresentableラッパー
struct ARViewContainer: UIViewRepresentable {

    /// スキャン状態・シーン操作を管理するViewModel
    var viewModel: LiDARScanningViewModel

    // MARK: - Coordinator

    /// ARSessionDelegateを担当する内部クラス
    /// スキャン中のARMeshAnchorをリアルタイムで収集する役割を持つ
    class Coordinator: NSObject, ARSessionDelegate {

        /// ViewModelへの参照（メッシュアンカーの収集・状態更新に使用）
        var viewModel: LiDARScanningViewModel

        init(viewModel: LiDARScanningViewModel) {
            self.viewModel = viewModel
        }

        /// ARKitが新しいアンカー（平面・メッシュなど）を追加したときに呼ばれる
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            // 追加されたアンカーの中からARMeshAnchorだけを取り出す
            for case let mesh as ARMeshAnchor in anchors {
                // UUIDをキーにしてViewModelのdictに追加
                viewModel.meshAnchors[mesh.identifier] = mesh
            }
        }

        /// ARKitが既存アンカーを更新（メッシュが広がったなど）したときに呼ばれる
        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            // 既存のメッシュアンカーを最新の状態で上書き
            for case let mesh as ARMeshAnchor in anchors {
                viewModel.meshAnchors[mesh.identifier] = mesh
            }
        }

        /// ARKitがアンカーを削除したときに呼ばれる
        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            // 削除されたアンカーをdictから取り除く
            for case let mesh as ARMeshAnchor in anchors {
                viewModel.meshAnchors.removeValue(forKey: mesh.identifier)
            }
        }
    }

    /// Coordinatorインスタンスを生成する（SwiftUIが1回だけ呼ぶ）
    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    // MARK: - UIViewRepresentable

    /// ARViewを生成して初期設定を行う（SwiftUIが最初に1回だけ呼ぶ）
    func makeUIView(context: Context) -> ARView {
        // ARViewを生成（セッションの自動設定をオフにして手動制御する）
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

        // LiDARメッシュをワイヤーフレームで可視化（どこがスキャンされたか確認用）
        arView.debugOptions = [.showSceneUnderstanding]

        // スキャンしたメッシュをオクルージョン（実物体がARの手前に来る）として使用
        arView.environment.sceneUnderstanding.options.insert(.occlusion)

        // スキャンしたメッシュを物理衝突判定の境界として使用
        arView.environment.sceneUnderstanding.options.insert(.physics)

        // CoordinatorをARSessionDelegateに設定（メッシュアンカーを受け取るため）
        arView.session.delegate = context.coordinator

        // ViewModelにARKitセッションを渡す（セッション操作に使用）
        viewModel.arSession = arView.session

        // ViewModelにARViewを渡す（メッシュエンティティのシーン追加に使用）
        viewModel.arView = arView

        return arView
    }

    /// SwiftUIの状態変化に応じてARViewを更新する（状態管理はViewModelに任せているため空）
    func updateUIView(_ uiView: ARView, context: Context) {}
}
