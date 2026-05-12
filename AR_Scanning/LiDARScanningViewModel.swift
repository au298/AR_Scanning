//
//  LiDARScanningViewModel.swift
//  AR_Scanning
//

import ARKit
import RealityKit
import CoreImage
import UIKit

/// スキャン中にサンプリングした1フレームの軽量なカメラ記録
/// ARFrameをそのまま保持するとメモリが圧迫されるので必要な情報だけ抽出して保持する
private struct SampledFrame {
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize
    let jpegData: Data
}

/// LiDARスキャン・保存・メッシュAR表示を一括管理するViewModel
@Observable
final class LiDARScanningViewModel {

    // MARK: - スキャン状態

    /// 画面状態を表す列挙型
    enum ScanState: Equatable {
        case idle
        case scanning
        case saving
        case saved(URL)
        case loadingDisplay
        case displaying
        case error(String)
    }

    // MARK: - 公開プロパティ（SwiftUIが観測する）

    var scanState: ScanState = .idle
    var elapsedSeconds: Int = 0
    let isLiDARAvailable: Bool

    // MARK: - 内部プロパティ（SwiftUIの観測対象外）

    @ObservationIgnored var arSession: ARSession?
    @ObservationIgnored weak var arView: ARView?
    @ObservationIgnored var meshAnchors: [UUID: ARMeshAnchor] = [:]
    @ObservationIgnored var currentSnapshot: MeshSnapshot?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var samplingTimer: Timer?

    /// スキャン中に1秒ごとサンプリングしたARFrameを同期的に保持する（最大8枚）
    /// - 非同期変換はせずそのまま保持し、保存時にまとめてJPEG変換することで
    ///   stopAndSave() 呼び出し時点で確実にデータが揃っている状態にする
    @ObservationIgnored private var sampledARFrames: [ARFrame] = []

    // MARK: - 初期化

    init() {
        isLiDARAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    // MARK: - スキャン開始

    /// LiDARメッシュ再構成を有効にしてARセッションを開始する
    func startScanning() {
        guard let session = arSession else { return }

        meshAnchors.removeAll()
        sampledARFrames.removeAll()

        let configuration = ARWorldTrackingConfiguration()

        // 生のLiDARメッシュを最高精度で再構成（.meshWithClassificationは分類のため平滑化が入り細部が失われる）
        configuration.sceneReconstruction = .mesh
        configuration.planeDetection = [.horizontal, .vertical]

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        elapsedSeconds = 0
        scanState = .scanning

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.elapsedSeconds += 1
        }

        // 1秒ごとにARFrameを同期的に保持（JPEG変換は保存時にまとめて行う）
        samplingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleCurrentFrame()
        }
    }

    // MARK: - スキャン停止 & 保存

    /// スキャンを停止してメッシュジオメトリをDocumentsディレクトリに保存する
    func stopAndSave() {
        timer?.invalidate();        timer = nil
        samplingTimer?.invalidate(); samplingTimer = nil

        let anchorsToSave = Array(meshAnchors.values)
        // 停止直前のフレームも確保（サンプリングタイマーのタイミングによっては最後が抜けるため）
        let lastARFrame = arSession?.currentFrame

        guard !anchorsToSave.isEmpty else {
            scanState = .error("メッシュデータがありません\nもう少し部屋をスキャンしてください")
            return
        }

        scanState = .saving

        // ARFrame参照は保存処理中に解放されないよう値としてコピーして Task に渡す
        let arFramesToConvert = sampledARFrames

        Task {
            do {
                // サンプリング済みフレームを一括でSampledFrameに変換（バックグラウンドで実行）
                var frames: [SampledFrame] = arFramesToConvert.compactMap { frame in
                    guard let jpeg = self.pixelBufferToJPEG(frame.capturedImage) else { return nil }
                    return SampledFrame(
                        cameraTransform: frame.camera.transform,
                        intrinsics: frame.camera.intrinsics,
                        imageResolution: frame.camera.imageResolution,
                        jpegData: jpeg
                    )
                }

                // 停止直前フレームを末尾に追加（既存フレームとの重複は許容）
                if let frame = lastARFrame,
                   let jpeg = self.pixelBufferToJPEG(frame.capturedImage) {
                    if frames.count >= 8 { frames.removeFirst() }
                    frames.append(SampledFrame(
                        cameraTransform: frame.camera.transform,
                        intrinsics: frame.camera.intrinsics,
                        imageResolution: frame.camera.imageResolution,
                        jpegData: jpeg
                    ))
                }

                // 各アンカーに最適フレームを選択してUVを計算
                var anchorDataArray: [MeshSnapshot.AnchorData] = anchorsToSave.map {
                    MeshSnapshot.AnchorData(from: $0)
                }

                // LiDARノイズをラプラシアン平滑化で低減（UV計算前に実行して精度を合わせる）
                for i in anchorDataArray.indices {
                    anchorDataArray[i].smooth()
                }

                for i in anchorDataArray.indices {
                    guard let bestIdx = self.bestFrameIndex(for: anchorsToSave[i], in: frames) else {
                        continue
                    }
                    let best = frames[bestIdx]
                    anchorDataArray[i].computeUVs(
                        cameraTransform: best.cameraTransform,
                        intrinsics: best.intrinsics,
                        imageResolution: best.imageResolution
                    )
                    anchorDataArray[i].textureImageIndex = bestIdx
                }

                let textureImages = frames.map { $0.jpegData }
                let snapshot = MeshSnapshot(anchors: anchorDataArray, textureImages: textureImages)

                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)

                let url = try self.buildSaveURL()
                try data.write(to: url, options: .atomic)

                await MainActor.run { self.scanState = .saved(url) }
            } catch {
                await MainActor.run {
                    self.scanState = .error("保存失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - メッシュVR表示

    /// 保存済みメッシュをVRビューア（SceneKit）で表示するためにスナップショットを読み込む
    func startDisplaying(url: URL) {
        scanState = .loadingDisplay

        Task {
            do {
                let data = try Data(contentsOf: url)
                let snapshot = try PropertyListDecoder().decode(MeshSnapshot.self, from: data)

                guard !snapshot.anchors.isEmpty else {
                    await MainActor.run { self.scanState = .error("保存済みメッシュが空でした") }
                    return
                }

                await MainActor.run {
                    self.arSession?.pause()
                    self.currentSnapshot = snapshot
                    self.scanState = .displaying
                }
            } catch {
                await MainActor.run {
                    self.scanState = .error("読み込み失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - リセット

    /// 全状態をリセットして待機画面に戻る
    func reset() {
        timer?.invalidate();        timer = nil
        samplingTimer?.invalidate(); samplingTimer = nil

        arSession?.pause()
        arView?.scene.anchors.removeAll()
        meshAnchors.removeAll()
        sampledARFrames.removeAll()
        currentSnapshot = nil
        elapsedSeconds = 0
        scanState = .idle
    }

    // MARK: - プライベート：フレームサンプリング

    /// 現在のARFrameを同期的に sampledARFrames に保持する
    /// - JPEG変換は行わず参照だけ保持することで、stopAndSave() 時点で確実にデータが揃う
    private func sampleCurrentFrame() {
        guard let frame = arSession?.currentFrame else { return }
        if sampledARFrames.count >= 8 { sampledARFrames.removeFirst() }
        sampledARFrames.append(frame)
    }

    // MARK: - プライベート：最適フレーム選択

    /// アンカーに対して「最も正面から捉えたフレーム」のインデックスを返す
    /// - dot積（カメラ前方方向とカメラ→アンカー方向の一致度）× 距離スコアで採点
    /// - アンカーがカメラ背後のフレームは除外する（dot <= 0）
    /// - 画像内に収まるかどうかは判定しない（アンカー原点はメッシュ中心ではないため誤判定が多い）
    private func bestFrameIndex(for anchor: ARMeshAnchor, in frames: [SampledFrame]) -> Int? {
        guard !frames.isEmpty else { return nil }

        // アンカーのワールド座標（anchor.transform の平行移動成分）
        let t = anchor.transform.columns.3
        let anchorPos = SIMD3<Float>(t.x, t.y, t.z)

        var bestScore: Float = -.infinity
        var bestIndex: Int?

        for (i, frame) in frames.enumerated() {
            let ct = frame.cameraTransform.columns.3
            let camPos = SIMD3<Float>(ct.x, ct.y, ct.z)

            let toAnchor = anchorPos - camPos
            let distance = simd_length(toAnchor)
            guard distance > 0.05 else { continue }

            // カメラ前方ベクトル（ワールド空間）: カメラ変換行列の -z 列
            let fwd = SIMD3<Float>(
                -frame.cameraTransform.columns.2.x,
                -frame.cameraTransform.columns.2.y,
                -frame.cameraTransform.columns.2.z
            )

            // アンカーがカメラ前方にあるか（dot > 0 = 前方、dot <= 0 = 背後または真横）
            let dot = simd_dot(simd_normalize(toAnchor), fwd)
            guard dot > 0 else { continue }

            // 距離スコア：0.5m〜2mが最適、範囲外は減衰（最低 0.3）
            let distScore: Float = (distance > 0.5 && distance < 2.0)
                ? 1.0
                : max(0.3, 1.0 - abs(distance - 1.25) / 2.5)

            let score = dot * distScore
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }

        return bestIndex
    }

    // MARK: - プライベート：画像変換

    /// CVPixelBuffer（YCbCr形式）をJPEGのDataに変換する
    private func pixelBufferToJPEG(_ buffer: CVPixelBuffer, quality: CGFloat = 0.82) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    // MARK: - プライベート：ファイル保存

    /// タイムスタンプ付きのメッシュ保存先URLを生成する
    private func buildSaveURL() throws -> URL {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            throw URLError(.fileDoesNotExist)
        }
        return documents.appendingPathComponent("mesh_\(Int(Date().timeIntervalSince1970)).echomesh")
    }
}
