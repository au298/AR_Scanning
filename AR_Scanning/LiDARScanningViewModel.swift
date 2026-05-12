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
        case idle               // 待機中：スキャン未開始
        case scanning           // スキャン中：LiDARでメッシュ取得中
        case saving             // 保存処理中：ジオメトリのシリアライズ・書き込み中
        case saved(URL)         // 保存完了：保存先URLを保持
        case loadingDisplay     // メッシュ構築中：エンティティ生成・配置処理中
        case displaying         // 表示中：メッシュがカメラ前方に配置された状態
        case error(String)      // エラー：メッセージを保持
    }

    // MARK: - 公開プロパティ（SwiftUIが観測する）

    /// 現在の画面状態
    var scanState: ScanState = .idle

    /// スキャン開始からの経過秒数（スキャン中のUI表示用）
    var elapsedSeconds: Int = 0

    /// このデバイスがLiDARスキャナーを搭載しているか
    let isLiDARAvailable: Bool

    // MARK: - 内部プロパティ（SwiftUIの観測対象外）

    /// ARKitセッションへの参照（ARViewContainerから設定される）
    @ObservationIgnored
    var arSession: ARSession?

    /// RealityKitシーンへのアクセスに使うARViewへの参照（ARViewContainerから設定される）
    @ObservationIgnored
    weak var arView: ARView?

    /// スキャン中にセッションデリゲートが収集するARMeshAnchorの辞書（UUIDをキーに使用）
    /// - ARKitはメッシュを更新するたびに同じUUIDのアンカーをdidUpdateで送ってくるため辞書にする
    @ObservationIgnored
    var meshAnchors: [UUID: ARMeshAnchor] = [:]

    /// VRビューアに渡すスナップショット（.displaying 状態のときだけ非nil）
    @ObservationIgnored
    var currentSnapshot: MeshSnapshot?

    /// 経過時間を1秒ごとに更新するタイマー
    @ObservationIgnored
    private var timer: Timer?

    /// 1秒ごとにカメラフレームをサンプリングするタイマー
    @ObservationIgnored
    private var samplingTimer: Timer?

    /// スキャン中に収集したカメラフレーム（最大8枚、古いものから順に上書き）
    @ObservationIgnored
    private var sampledFrames: [SampledFrame] = []

    // MARK: - 初期化

    init() {
        // LiDARメッシュ再構成がこのデバイスでサポートされているか確認
        isLiDARAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    // MARK: - スキャン開始

    /// LiDARメッシュ再構成を有効にしてARセッションを開始する
    func startScanning() {
        // ARセッションが設定されていなければ何もしない
        guard let session = arSession else { return }

        // 前回のスキャンデータをクリア
        meshAnchors.removeAll()
        sampledFrames.removeAll()

        // ARWorldTrackingConfigurationを生成（6DOF空間追跡の設定クラス）
        let configuration = ARWorldTrackingConfiguration()

        // 壁・床・天井・家具などを分類しながらメッシュ再構成（.meshより形状精度が高い）
        configuration.sceneReconstruction = .meshWithClassification

        // 平面検出を有効化（床・壁の検出に使用）
        configuration.planeDetection = [.horizontal, .vertical]

        // フレームレートが高いほどARKitに渡せるデータが増えてメッシュの更新が速くなる
        // 60fps対応フォーマットがあれば優先して使用し、なければデフォルトにフォールバック
        let highFPSFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first {
            $0.framesPerSecond >= 60
        }
        if let format = highFPSFormat {
            configuration.videoFormat = format
        }

        // このデバイスがシーン深度フレームをサポートしているなら有効化
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        // トラッキングリセット＋既存アンカー削除でセッションを開始
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        // 経過時間をリセット
        elapsedSeconds = 0

        // 状態をスキャン中に更新
        scanState = .scanning

        // 1秒ごとに経過時間をインクリメントするタイマーを起動
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.elapsedSeconds += 1
        }

        // 1秒ごとにカメラフレームをサンプリング（最大8枚蓄積してテクスチャ精度を向上）
        samplingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleCurrentFrame()
        }
    }

    // MARK: - スキャン停止 & 保存

    /// スキャンを停止してメッシュジオメトリをDocumentsディレクトリに保存する
    func stopAndSave() {
        timer?.invalidate()
        timer = nil
        samplingTimer?.invalidate()
        samplingTimer = nil

        // この時点でセッションデリゲートが収集したARMeshAnchorをコピーする
        // ※ セッションが動いている間だけMTLBufferは有効なので、ここでスナップショットを取る
        let anchorsToSave = Array(meshAnchors.values)

        // 停止直前のフレームも取得（サンプリングのタイミングによっては最後の1秒が抜ける可能性があるため）
        let lastFrame = arSession?.currentFrame

        guard !anchorsToSave.isEmpty else {
            scanState = .error("メッシュデータがありません\nもう少し部屋をスキャンしてください")
            return
        }

        scanState = .saving

        // 蓄積済みフレームをコピー（Taskに渡すためにスナップショット化）
        var framesSnapshot = sampledFrames

        Task {
            do {
                // 停止直前のフレームを最後に追加（まだサンプリングされていない場合）
                if let frame = lastFrame,
                   let jpeg = pixelBufferToJPEG(frame.capturedImage) {
                    if framesSnapshot.count >= 8 { framesSnapshot.removeFirst() }
                    framesSnapshot.append(SampledFrame(
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

                for i in anchorDataArray.indices {
                    guard let bestIdx = bestFrameIndex(for: anchorsToSave[i], in: framesSnapshot) else {
                        continue
                    }
                    let best = framesSnapshot[bestIdx]
                    anchorDataArray[i].computeUVs(
                        cameraTransform: best.cameraTransform,
                        intrinsics: best.intrinsics,
                        imageResolution: best.imageResolution
                    )
                    anchorDataArray[i].textureImageIndex = bestIdx
                }

                // 全サンプルフレームのJPEGを配列で保存（各アンカーがインデックスで参照）
                let textureImages = framesSnapshot.map { $0.jpegData }

                let snapshot = MeshSnapshot(anchors: anchorDataArray, textureImages: textureImages)

                // バイナリPropertyListとしてエンコード（JSONより大幅に小さい）
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)

                let url = try buildSaveURL()
                try data.write(to: url, options: .atomic)

                await MainActor.run {
                    self.scanState = .saved(url)
                }
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
                    await MainActor.run {
                        self.scanState = .error("保存済みメッシュが空でした")
                    }
                    return
                }

                await MainActor.run {
                    // VR表示にARカメラは不要なのでセッションを停止
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
        timer?.invalidate()
        timer = nil
        samplingTimer?.invalidate()
        samplingTimer = nil

        arSession?.pause()
        arView?.scene.anchors.removeAll()
        meshAnchors.removeAll()
        sampledFrames.removeAll()
        currentSnapshot = nil
        elapsedSeconds = 0
        scanState = .idle
    }

    // MARK: - プライベート：フレームサンプリング

    /// 現在のARFrameを取得してJPEG変換し、sampledFramesに追加する
    /// - 8枚を上限とし、超えた場合は最古のフレームを削除する
    /// - JPEG変換はバックグラウンドTaskで実行してメインスレッドをブロックしない
    private func sampleCurrentFrame() {
        guard let frame = arSession?.currentFrame else { return }

        // キャプチャに必要な値をメインスレッドで即取得（frameの参照は保持されるが早めに処理する）
        let cameraTransform  = frame.camera.transform
        let intrinsics       = frame.camera.intrinsics
        let imageResolution  = frame.camera.imageResolution
        let pixelBuffer      = frame.capturedImage

        Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  let jpegData = self.pixelBufferToJPEG(pixelBuffer) else { return }

            let sampled = SampledFrame(
                cameraTransform: cameraTransform,
                intrinsics: intrinsics,
                imageResolution: imageResolution,
                jpegData: jpegData
            )
            await MainActor.run {
                if self.sampledFrames.count >= 8 { self.sampledFrames.removeFirst() }
                self.sampledFrames.append(sampled)
            }
        }
    }

    // MARK: - プライベート：最適フレーム選択

    /// アンカーに対してサンプル済みフレームの中から最も正面から捉えたフレームのインデックスを返す
    /// - 正面度（dot積）× 距離スコアで採点し、最高スコアのフレームを選ぶ
    /// - カメラ背後・画像フレーム外のアンカーは候補から除外する
    private func bestFrameIndex(for anchor: ARMeshAnchor, in frames: [SampledFrame]) -> Int? {
        guard !frames.isEmpty else { return nil }

        // アンカー中心のワールド座標
        let t = anchor.transform.columns.3
        let anchorCenter = SIMD3<Float>(t.x, t.y, t.z)

        var bestScore: Float = -.infinity
        var bestIndex: Int?

        for (i, frame) in frames.enumerated() {
            let ct = frame.cameraTransform.columns.3
            let camPos = SIMD3<Float>(ct.x, ct.y, ct.z)

            let toAnchor = anchorCenter - camPos
            let distance = simd_length(toAnchor)
            guard distance > 0.05 else { continue }

            // カメラ前方ベクトル（ワールド空間）: カメラ変換行列の -z 列
            let fwd = SIMD3<Float>(
                -frame.cameraTransform.columns.2.x,
                -frame.cameraTransform.columns.2.y,
                -frame.cameraTransform.columns.2.z
            )
            // アンカーがカメラ前方70度以内にあるか
            let dot = simd_dot(simd_normalize(toAnchor), fwd)
            guard dot > 0.1 else { continue }

            // アンカー中心が画像内に収まっているか（手動投影で確認）
            let viewMatrix = frame.cameraTransform.inverse
            let c4 = viewMatrix * SIMD4<Float>(anchorCenter.x, anchorCenter.y, anchorCenter.z, 1)
            guard c4.z < 0 else { continue }

            let fx = frame.intrinsics.columns.0.x
            let fy = frame.intrinsics.columns.1.y
            let cx = frame.intrinsics.columns.2.x
            let cy = frame.intrinsics.columns.2.y
            let xImg = fx * (c4.x / (-c4.z)) + cx
            let yImg = fy * (c4.y / (-c4.z)) + cy
            let margin = Float(min(frame.imageResolution.width, frame.imageResolution.height)) * 0.05
            guard xImg > margin,
                  xImg < Float(frame.imageResolution.width)  - margin,
                  yImg > margin,
                  yImg < Float(frame.imageResolution.height) - margin else { continue }

            // 距離スコア：0.5m〜2mが最適、それ以外は減衰
            let distScore: Float = distance > 0.5 && distance < 2.0
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

    // MARK: - プライベート：ファイル保存ヘルパー

    /// CVPixelBuffer（YCbCr形式）をJPEGのDataに変換する
    private func pixelBufferToJPEG(_ buffer: CVPixelBuffer, quality: CGFloat = 0.82) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    /// タイムスタンプ付きのメッシュ保存先URLを生成する
    private func buildSaveURL() throws -> URL {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw URLError(.fileDoesNotExist)
        }
        let fileName = "mesh_\(Int(Date().timeIntervalSince1970)).echomesh"
        return documents.appendingPathComponent(fileName)
    }
}
