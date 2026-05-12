//
//  MeshSnapshot.swift
//  AR_Scanning
//

import ARKit
import simd

/// スキャンしたLiDARメッシュを保存・復元するためのCodableなデータ構造
struct MeshSnapshot: Codable {

    /// スキャン中に収集したARMeshAnchorの配列
    var anchors: [AnchorData]

    /// スキャン中にサンプリングした複数のカメラ画像（JPEG圧縮済み）
    /// 各AnchorDataがtextureImageIndexで最適フレームを指定する
    var textureImages: [Data]

    /// 1つのARMeshAnchorに対応するシリアライズ可能なジオメトリデータ
    struct AnchorData: Codable {

        /// 頂点座標をバイト列として保存（SIMD3<Float>を平坦化）
        var vertexData: Data

        /// 法線ベクトルをバイト列として保存（SIMD3<Float>を平坦化）
        var normalData: Data

        /// 三角形インデックスをバイト列として保存（UInt32を平坦化）
        var indexData: Data

        /// 総インデックス数（面の数 × 3）
        var indexCount: Int

        /// アンカーのワールド変換行列を列優先で16個のFloatに展開して保存
        var transform: [Float]

        /// 各頂点のUV座標をFloatペア（u, v）としてバイト列に保存（頂点数 × 2個）
        var uvData: Data?

        /// このアンカーが使用するtextureImages配列内のインデックス
        var textureImageIndex: Int?

        // MARK: - ARMeshAnchorからの初期化

        /// ARMeshAnchorのジオメトリをメモリ上のバイト列にコピーして初期化する
        /// - セッションが動いている間だけMTLBufferは有効なので、停止前に呼ぶこと
        init(from anchor: ARMeshAnchor) {
            let geometry = anchor.geometry

            // --- 頂点座標の読み取り ---
            let vertexCount = geometry.vertices.count
            // MTLBufferのCPUポインタを取得（GPU使用中でなければ安全）
            let vPtr = geometry.vertices.buffer.contents()
            var vertices = [SIMD3<Float>]()
            vertices.reserveCapacity(vertexCount)
            for i in 0..<vertexCount {
                // offset（バッファ先頭からのずれ）+ stride（1頂点のバイト幅）でアドレスを計算
                let byteOffset = geometry.vertices.offset + i * geometry.vertices.stride
                // SIMD3<Float>は16バイトアライメントが必要だがMTLBufferは12バイトパックで格納するため、
                // Floatを1つずつ読み取ってSIMD3を構築しアライメント違反を回避する
                let x = vPtr.load(fromByteOffset: byteOffset,     as: Float.self)
                let y = vPtr.load(fromByteOffset: byteOffset + 4, as: Float.self)
                let z = vPtr.load(fromByteOffset: byteOffset + 8, as: Float.self)
                vertices.append(SIMD3<Float>(x, y, z))
            }
            // [SIMD3<Float>]をDataに変換（unsafeBytesで生バイトを取り出す）
            self.vertexData = vertices.withUnsafeBytes { Data($0) }

            // --- 法線ベクトルの読み取り ---
            let normalCount = geometry.normals.count
            let nPtr = geometry.normals.buffer.contents()
            var normals = [SIMD3<Float>]()
            normals.reserveCapacity(normalCount)
            for i in 0..<normalCount {
                let byteOffset = geometry.normals.offset + i * geometry.normals.stride
                // 頂点と同様にFloatを個別に読み取る
                let x = nPtr.load(fromByteOffset: byteOffset,     as: Float.self)
                let y = nPtr.load(fromByteOffset: byteOffset + 4, as: Float.self)
                let z = nPtr.load(fromByteOffset: byteOffset + 8, as: Float.self)
                normals.append(SIMD3<Float>(x, y, z))
            }
            self.normalData = normals.withUnsafeBytes { Data($0) }

            // --- 面インデックスの読み取り ---
            // indexCountPerPrimitive = 3（三角形）
            let totalIndices = geometry.faces.count * geometry.faces.indexCountPerPrimitive
            let iPtr = geometry.faces.buffer.contents()
            var indices = [UInt32]()
            indices.reserveCapacity(totalIndices)
            for i in 0..<totalIndices {
                switch geometry.faces.bytesPerIndex {
                case 2:
                    // UInt16インデックスをUInt32に拡張
                    let v = iPtr.load(fromByteOffset: i * 2, as: UInt16.self)
                    indices.append(UInt32(v))
                default:
                    // UInt32インデックスをそのまま読み取る
                    let v = iPtr.load(fromByteOffset: i * 4, as: UInt32.self)
                    indices.append(v)
                }
            }
            self.indexData = indices.withUnsafeBytes { Data($0) }
            self.indexCount = totalIndices

            // --- 変換行列の保存 ---
            // simd_float4x4は列優先（column-major）で4列 × 4行 = 16個のFloatに展開
            let m = anchor.transform
            self.transform = [
                m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
            ]
        }

        // MARK: - 復元用の計算プロパティ

        /// 保存済みFloatの配列からsimd_float4x4を復元する
        var matrix: simd_float4x4 {
            simd_float4x4(columns: (
                SIMD4(transform[0],  transform[1],  transform[2],  transform[3]),
                SIMD4(transform[4],  transform[5],  transform[6],  transform[7]),
                SIMD4(transform[8],  transform[9],  transform[10], transform[11]),
                SIMD4(transform[12], transform[13], transform[14], transform[15])
            ))
        }

        /// 保存済みバイト列からSIMD3<Float>の頂点配列を復元する
        var vertices: [SIMD3<Float>] {
            vertexData.withUnsafeBytes { ptr in
                // UnsafeRawBufferPointerをSIMD3<Float>として解釈して配列化
                Array(ptr.bindMemory(to: SIMD3<Float>.self))
            }
        }

        /// 保存済みバイト列からSIMD3<Float>の法線配列を復元する
        var normals: [SIMD3<Float>] {
            normalData.withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: SIMD3<Float>.self))
            }
        }

        /// 保存済みバイト列からUInt32のインデックス配列を復元する
        var indices: [UInt32] {
            indexData.withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: UInt32.self))
            }
        }

        /// 保存済みuvDataをCGPoint（x=u, y=v）の配列として復元する
        var uvCoordinates: [CGPoint] {
            guard let data = uvData else { return [] }
            return data.withUnsafeBytes { ptr -> [CGPoint] in
                let floats = Array(ptr.bindMemory(to: Float.self))
                var result = [CGPoint]()
                result.reserveCapacity(floats.count / 2)
                stride(from: 0, to: floats.count - 1, by: 2).forEach {
                    result.append(CGPoint(x: CGFloat(floats[$0]), y: CGFloat(floats[$0 + 1])))
                }
                return result
            }
        }

        // MARK: - 平滑化

        /// ラプラシアン平滑化でLiDARノイズを低減する
        /// 各頂点を隣接頂点の平均方向に factor だけ移動する操作を iterations 回繰り返す
        /// - Parameters:
        ///   - iterations: 繰り返し回数（多いほど滑らか。多すぎると形状が崩れる）
        ///   - factor: 1回あたりの移動割合 0〜1
        mutating func smooth(iterations: Int = 2, factor: Float = 0.3) {
            var verts = vertices
            let idxs  = indices
            guard verts.count > 2, !idxs.isEmpty else { return }

            // 三角形インデックスから隣接頂点Setを構築（Set で辺の重複を排除）
            var neighbors = Array(repeating: Set<Int>(), count: verts.count)
            for t in stride(from: 0, to: idxs.count - 2, by: 3) {
                let i0 = Int(idxs[t]), i1 = Int(idxs[t + 1]), i2 = Int(idxs[t + 2])
                neighbors[i0].formUnion([i1, i2])
                neighbors[i1].formUnion([i0, i2])
                neighbors[i2].formUnion([i0, i1])
            }

            for _ in 0..<iterations {
                var smoothed = verts
                for i in 0..<verts.count {
                    let nbrs = neighbors[i]
                    guard !nbrs.isEmpty else { continue }
                    var sum = SIMD3<Float>.zero
                    for j in nbrs { sum += verts[j] }
                    let avg = sum / Float(nbrs.count)
                    // 元の位置から avg 方向に factor だけ移動
                    smoothed[i] = verts[i] + factor * (avg - verts[i])
                }
                verts = smoothed
            }

            vertexData = verts.withUnsafeBytes { Data($0) }
        }

        // MARK: - UV計算

        /// カメラパラメータを直接受け取って各頂点をカメラ画像に投影し、UV座標をuvDataに格納する
        /// - Parameters:
        ///   - cameraTransform: カメラのワールド変換行列
        ///   - intrinsics: カメラ内部パラメータ行列（landscapeRight基準）
        ///   - imageResolution: カメラ画像の解像度
        /// - Note: ARKit座標系ではカメラは-z方向を向く。camPos.z < 0 が前方。
        ///         SceneKitのUVはV=0が下なのでV軸を反転して保存する。
        mutating func computeUVs(
            cameraTransform: simd_float4x4,
            intrinsics: simd_float3x3,
            imageResolution: CGSize
        ) {
            let verts = vertices
            let anchorMatrix = matrix
            let viewMatrix = cameraTransform.inverse

            let fx   = intrinsics.columns.0.x
            let fy   = intrinsics.columns.1.y
            let cx   = intrinsics.columns.2.x
            let cy   = intrinsics.columns.2.y
            let imgW = Float(imageResolution.width)
            let imgH = Float(imageResolution.height)

            var uvFloats = [Float]()
            uvFloats.reserveCapacity(verts.count * 2)

            for v in verts {
                // ローカル → ワールド座標
                let w4 = anchorMatrix * SIMD4<Float>(v.x, v.y, v.z, 1)
                let wp = SIMD3<Float>(w4.x / w4.w, w4.y / w4.w, w4.z / w4.w)

                // ワールド → カメラ座標
                let c4 = viewMatrix * SIMD4<Float>(wp.x, wp.y, wp.z, 1)

                let u: Float
                let vCoord: Float
                if c4.z < 0 {
                    // カメラ前方: 内部パラメータで画素座標へ投影
                    let xImg = fx * (c4.x / (-c4.z)) + cx
                    let yImg = fy * (c4.y / (-c4.z)) + cy
                    u      = xImg / imgW
                    vCoord = 1.0 - yImg / imgH   // SceneKit UV は V=0 が下
                } else {
                    // カメラ背後: 中心にフォールバック（clamp で端色になる）
                    u      = 0.5
                    vCoord = 0.5
                }
                uvFloats.append(u)
                uvFloats.append(vCoord)
            }

            self.uvData = uvFloats.withUnsafeBytes { Data($0) }
        }
    }
}
