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
                vertices.append(vPtr.load(fromByteOffset: byteOffset, as: SIMD3<Float>.self))
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
                normals.append(nPtr.load(fromByteOffset: byteOffset, as: SIMD3<Float>.self))
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
    }
}
