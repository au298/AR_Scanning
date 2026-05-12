//
//  LiDARScanningViewModel.swift
//  AR_Scanning
//

import ARKit
import RealityKit
import CoreImage
import UIKit

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

        // ARWorldTrackingConfigurationを生成（6DOF空間追跡の設定クラス）
        let configuration = ARWorldTrackingConfiguration()

        // LiDARによるリアルタイムメッシュ再構成を有効化（これによりARMeshAnchorが届く）
        configuration.sceneReconstruction = .mesh

        // 平面検出を有効化（床・壁の検出に使用）
        configuration.planeDetection = [.horizontal, .vertical]

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
    }

    // MARK: - スキャン停止 & 保存

    /// スキャンを停止してメッシュジオメトリをDocumentsディレクトリに保存する
    func stopAndSave() {
        // タイマーを停止
        timer?.invalidate()
        timer = nil

        // この時点でセッションデリゲートが収集したARMeshAnchorをコピーする
        // ※ セッションが動いている間だけMTLBufferは有効なので、ここでスナップショットを取る
        let anchorsToSave = Array(meshAnchors.values)

        // テクスチャ用にスキャン停止時点のカメラフレームを取得（UV計算にも使用）
        let capturedFrame = arSession?.currentFrame

        // スキャンが不十分でメッシュがない場合
        guard !anchorsToSave.isEmpty else {
            scanState = .error("メッシュデータがありません\nもう少し部屋をスキャンしてください")
            return
        }

        // 保存処理中状態に遷移
        scanState = .saving

        // ジオメトリのシリアライズとファイル書き込みは重いので非同期で実行
        Task {
            do {
                // 各ARMeshAnchorからAnchorDataを生成し、カメラ画像が取れていればUVを計算
                var anchorDataArray = anchorsToSave.map { MeshSnapshot.AnchorData(from: $0) }
                if let frame = capturedFrame {
                    for i in anchorDataArray.indices {
                        anchorDataArray[i].computeUVs(from: frame)
                    }
                }

                // カメラ画像をJPEG圧縮してテクスチャデータとして保存
                let textureData = capturedFrame.flatMap { captureTextureJPEG(from: $0) }

                let snapshot = MeshSnapshot(
                    anchors: anchorDataArray,
                    textureImageData: textureData
                )

                // バイナリPropertyListとしてエンコード（JSONより大幅に小さい）
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(snapshot)

                // 保存先URLを生成してファイルに書き込む
                let url = try buildSaveURL()
                try data.write(to: url, options: .atomic)

                await MainActor.run {
                    // 保存完了状態に遷移（URLを持たせる）
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
        // タイマーを停止
        timer?.invalidate()
        timer = nil

        // ARセッションを一時停止
        arSession?.pause()

        // シーン上のアンカーをすべて削除
        arView?.scene.anchors.removeAll()

        // 収集済みメッシュアンカーをクリア
        meshAnchors.removeAll()

        // VRビューア用スナップショットをクリア
        currentSnapshot = nil

        // 経過秒数をリセット
        elapsedSeconds = 0

        // 待機状態に戻す
        scanState = .idle
    }

    // MARK: - プライベート：ファイル保存ヘルパー

    /// ARFrameのcapturedImage（YCbCr CVPixelBuffer）をJPEGのDataに変換する
    /// - CIContextをソフトウェアレンダラーなしで使い、GPU変換を優先する
    private func captureTextureJPEG(from frame: ARFrame) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }

    /// タイムスタンプ付きのメッシュ保存先URLを生成する
    private func buildSaveURL() throws -> URL {
        // Documentsディレクトリのパスを取得
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw URLError(.fileDoesNotExist)
        }

        // Unixタイムスタンプをファイル名に使って一意にする（拡張子は.echomesh）
        let fileName = "mesh_\(Int(Date().timeIntervalSince1970)).echomesh"

        return documents.appendingPathComponent(fileName)
    }
}
