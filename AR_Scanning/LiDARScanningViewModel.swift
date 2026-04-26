//
//  LiDARScanningViewModel.swift
//  AR_Scanning
//

import ARKit
import RealityKit

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
                // 各ARMeshAnchorからAnchorDataを生成してMeshSnapshotにまとめる
                let snapshot = MeshSnapshot(
                    anchors: anchorsToSave.map { MeshSnapshot.AnchorData(from: $0) }
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

    // MARK: - メッシュAR表示

    /// 保存済みメッシュをカメラ前方に3Dオブジェクトとして表示する
    func startDisplaying(url: URL) {
        // ARSeessionとARViewの両方が必要
        guard let session = arSession, let arView = arView else {
            scanState = .error("ARViewが初期化されていません")
            return
        }

        // メッシュ構築中状態に遷移
        scanState = .loadingDisplay

        // メッシュ読み込みと配置を非同期で実行（MeshResource生成が重いため）
        Task {
            do {
                // バイナリPropertyListファイルを読み込む
                let data = try Data(contentsOf: url)

                // MeshSnapshotにデコード
                let snapshot = try PropertyListDecoder().decode(MeshSnapshot.self, from: data)

                // スナップショットが空の場合
                guard !snapshot.anchors.isEmpty else {
                    await MainActor.run {
                        self.scanState = .error("保存済みメッシュが空でした")
                    }
                    return
                }

                // カメラパススルー用のシンプルなARセッションを開始（WorldMapなし）
                let configuration = ARWorldTrackingConfiguration()
                await MainActor.run {
                    session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                }

                // セッションのトラッキングが安定するまで待機
                try await Task.sleep(for: .seconds(0.8))

                // 各AnchorDataからModelEntityを生成（失敗したものはスキップ）
                var entities: [ModelEntity] = []
                for anchorData in snapshot.anchors {
                    if let entity = try? makeMeshEntity(from: anchorData) {
                        entities.append(entity)
                    }
                }

                // 1つも生成できなかった場合はエラー
                guard !entities.isEmpty else {
                    await MainActor.run {
                        self.scanState = .error("メッシュエンティティの生成に失敗しました")
                    }
                    return
                }

                // --- 中心揃えとスケール計算 ---

                // 各エンティティの位置からバウンディングボックスを計算
                var minPos = entities[0].position
                var maxPos = entities[0].position
                for entity in entities {
                    minPos = min(minPos, entity.position)
                    maxPos = max(maxPos, entity.position)
                }

                // バウンディングボックスの中心点
                let center = (minPos + maxPos) * 0.5

                // 最大辺の長さ（ルームスケールは数m）
                let size = maxPos - minPos
                let maxDimension = max(size.x, max(size.y, size.z))

                // カメラ前方で見やすいように0.5mに収まるスケールを計算
                let targetSize: Float = 0.5
                let scale = maxDimension > 0.01 ? targetSize / maxDimension : 1.0

                // 全エンティティを束ねる親エンティティを作成
                let group = Entity()
                for entity in entities {
                    // バウンディングボックスの中心が原点に来るようにオフセット
                    entity.position -= center
                    group.addChild(entity)
                }

                // グループをスキャン時のスケールから縮小する
                group.scale = SIMD3(repeating: scale)

                // ワールド座標 [0, 0, -0.6] = セッション開始位置から前方0.6mに配置
                let anchor = AnchorEntity(world: [0, 0, -0.6])
                anchor.addChild(group)

                await MainActor.run {
                    // シーンの既存アンカーをクリアしてから新しいアンカーを追加
                    arView.scene.anchors.removeAll()
                    arView.scene.addAnchor(anchor)
                    // 表示完了状態に遷移
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

        // 経過秒数をリセット
        elapsedSeconds = 0

        // 待機状態に戻す
        scanState = .idle
    }

    // MARK: - プライベート：メッシュエンティティ生成

    /// AnchorDataからRealityKitのModelEntityを生成する
    private func makeMeshEntity(from anchorData: MeshSnapshot.AnchorData) throws -> ModelEntity {
        // 保存済みバイト列から頂点・法線・インデックスを復元
        let vertices = anchorData.vertices
        let normals = anchorData.normals
        let indices = anchorData.indices

        // MeshDescriptorにジオメトリデータを詰める
        var descriptor = MeshDescriptor()

        // 頂点座標を設定
        descriptor.positions = MeshBuffer(vertices)

        // 法線ベクトルが存在する場合は設定（ライティングに影響）
        if !normals.isEmpty {
            descriptor.normals = MeshBuffer(normals)
        }

        // 三角形の面インデックスを設定
        descriptor.primitives = .triangles(indices)

        // MeshDescriptorからMeshResourceを生成（失敗した場合はthrow）
        let mesh = try MeshResource.generate(from: [descriptor])

        // シアン色のマテリアル（LiDARスキャンメッシュらしい見た目に）
        let material = SimpleMaterial(color: .cyan, roughness: 0.6, isMetallic: false)

        // ModelEntityを生成
        let entity = ModelEntity(mesh: mesh, materials: [material])

        // 保存済み変換行列をエンティティに適用（ワールド空間での位置・向きが決まる）
        entity.transform = Transform(matrix: anchorData.matrix)

        return entity
    }

    // MARK: - プライベート：ファイル保存ヘルパー

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
