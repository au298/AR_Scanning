//
//  MeshViewerView.swift
//  AR_Scanning
//

import SwiftUI
import SceneKit
import UIKit

/// スキャン済みメッシュをVR空間（黒背景・カメラ映像なし）でインタラクティブに表示するビューア
struct MeshViewerView: View {

    /// 閉じるボタンが押されたときのコールバック
    let onDismiss: () -> Void

    /// SceneKitシーン（init時に一度だけ構築して再利用する）
    @State private var scene: SCNScene

    /// - Parameters:
    ///   - snapshot: 表示するメッシュスナップショット
    ///   - onDismiss: 閉じるボタンが押されたときのコールバック
    init(snapshot: MeshSnapshot, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _scene = State(initialValue: MeshViewerView.buildScene(from: snapshot))
    }

    var body: some View {
        ZStack {
            // SceneKitビュー（ドラッグ回転・ピンチズーム・2本指パンを自動サポート）
            SceneView(
                scene: scene,
                options: [.allowsCameraControl, .autoenablesDefaultLighting]
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: onDismiss) {
                        Label("スキャンに戻る", systemImage: "chevron.left")
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)

                Spacer()

                Text("ドラッグで回転 · ピンチで拡大 · 2本指でパン")
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }
        }
    }

    // MARK: - SceneKit構築

    /// MeshSnapshotからSCNSceneを生成する（メインスレッドでinitから呼ばれる）
    private static func buildScene(from snapshot: MeshSnapshot) -> SCNScene {
        let scene = SCNScene()
        // 暗い宇宙感のある背景でVR空間を演出
        scene.background.contents = UIColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1)

        let groupNode = SCNNode()

        // 全頂点のワールド座標バウンディングボックスを計算しながらノードを追加
        var worldMin = SIMD3<Float>(repeating: .infinity)
        var worldMax = SIMD3<Float>(repeating: -.infinity)

        for anchorData in snapshot.anchors {
            let vertices = anchorData.vertices
            let normals  = anchorData.normals
            let indices  = anchorData.indices
            guard !vertices.isEmpty, !indices.isEmpty else { continue }

            // アンカー行列でローカル頂点をワールド座標に変換してバウンディングボックスを更新
            let m = anchorData.matrix
            for v in vertices {
                let w = m * SIMD4<Float>(v.x, v.y, v.z, 1)
                let w3 = SIMD3<Float>(w.x, w.y, w.z)
                worldMin = min(worldMin, w3)
                worldMax = max(worldMax, w3)
            }

            if let node = makeNode(vertices: vertices, normals: normals, indices: indices, transform: m) {
                groupNode.addChildNode(node)
            }
        }

        // バウンディングボックスの中心をシーン原点に揃えてカメラの回転軸を中央にする
        if worldMin.x < worldMax.x {
            let center = (worldMin + worldMax) * 0.5
            groupNode.position = SCNVector3(-center.x, -center.y, -center.z)

            // メッシュ全体が収まる距離にカメラを配置（やや斜め上から俯瞰）
            let extent = worldMax - worldMin
            let maxDim = max(extent.x, max(extent.y, extent.z))
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, maxDim * 0.6, maxDim * 2.2)
            cameraNode.look(at: .init(0, 0, 0))
            scene.rootNode.addChildNode(cameraNode)
        }

        scene.rootNode.addChildNode(groupNode)
        return scene
    }

    /// 頂点・法線・インデックスとアンカー行列からSCNNodeを生成する
    private static func makeNode(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [UInt32],
        transform: simd_float4x4
    ) -> SCNNode? {
        // 頂点座標ソース
        let vertexSource = SCNGeometrySource(
            vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        )
        var sources: [SCNGeometrySource] = [vertexSource]

        // 法線ソース（ライティングに影響）
        if !normals.isEmpty {
            let normalSource = SCNGeometrySource(
                normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }
            )
            sources.append(normalSource)
        }

        // 三角形インデックスエレメント（UInt32 = bytesPerIndex 4）
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: 4
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])

        // シアン半透明マテリアル（両面描画でスキャン漏れによる穴を目立たなくする）
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.cyan.withAlphaComponent(0.85)
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        // アンカーの変換行列を適用（ワールド座標での位置・向きを復元）
        node.simdTransform = transform
        return node
    }
}
