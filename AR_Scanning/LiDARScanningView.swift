//
//  LiDARScanningView.swift
//  AR_Scanning
//

import SwiftUI

/// LiDARスキャン・保存・メッシュAR表示を行うメイン画面
struct LiDARScanningView: View {

    /// スキャン全体を管理するViewModel（このViewが所有する）
    @State private var viewModel = LiDARScanningViewModel()

    var body: some View {
        ZStack {
            if viewModel.isLiDARAvailable {
                // LiDAR搭載デバイス：ARカメラ＋LiDARメッシュを全画面表示
                ARViewContainer(viewModel: viewModel)
                    .ignoresSafeArea()

                // カメラ映像の上に重ねるUIオーバーレイ
                VStack {
                    Spacer()
                    // 状態に応じた操作パネルを下部に表示
                    controlPanel
                        .padding(.bottom, 48)
                        .padding(.horizontal, 24)
                }

            } else {
                // LiDAR非搭載デバイス：使用不可メッセージを表示
                lidarUnavailableView
            }
        }
    }

    // MARK: - 操作パネル（状態ごとに切り替え）

    /// 現在のscanStateに応じたボタン・メッセージを表示する
    @ViewBuilder
    private var controlPanel: some View {
        switch viewModel.scanState {

        case .idle:
            // 待機中：スキャン開始ボタンのみ表示
            primaryButton(
                label: "スキャン開始",
                icon: "camera.viewfinder",
                color: .blue
            ) {
                viewModel.startScanning()
            }

        case .scanning:
            // スキャン中：経過時間バッジ + 停止して保存ボタン
            VStack(spacing: 14) {
                elapsedTimeBadge
                primaryButton(
                    label: "停止して保存",
                    icon: "stop.circle.fill",
                    color: .red
                ) {
                    viewModel.stopAndSave()
                }
            }

        case .saving:
            // 保存処理中：インジケーター（ボタン操作不可）
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("WorldMapを保存中...")
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(.black.opacity(0.6), in: Capsule())

        case .saved(let url):
            // 保存完了：ファイル名 + ARで確認ボタン + リセットボタン
            VStack(spacing: 14) {
                savedFileBadge(url: url)
                primaryButton(
                    label: "ARで確認する",
                    icon: "arkit",
                    color: .indigo
                ) {
                    // 保存済みWorldMapのメッシュをカメラ前方に表示
                    viewModel.startDisplaying(url: url)
                }
                secondaryButton(label: "リセット", icon: "arrow.counterclockwise") {
                    viewModel.reset()
                }
            }

        case .loadingDisplay:
            // メッシュ構築中：エンティティ生成・配置のインジケーター
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("メッシュを配置中...")
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(.black.opacity(0.6), in: Capsule())

        case .displaying:
            // 表示中：説明テキスト + スキャンに戻るボタン
            VStack(spacing: 14) {
                // 操作説明バッジ（端末を動かして確認できることを伝える）
                Text("端末を動かしてメッシュを確認できます")
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                secondaryButton(label: "スキャンに戻る", icon: "arrow.counterclockwise") {
                    viewModel.reset()
                }
            }

        case .error(let message):
            // エラー：メッセージ + リセットボタン
            VStack(spacing: 14) {
                errorBadge(message: message)
                secondaryButton(label: "リセット", icon: "arrow.counterclockwise") {
                    viewModel.reset()
                }
            }
        }
    }

    // MARK: - ボタンコンポーネント

    /// メインアクションボタン（色付き・塗りつぶし）
    private func primaryButton(
        label: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.headline)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(color, in: Capsule())
                .foregroundStyle(.white)
        }
    }

    /// サブアクションボタン（半透明背景）
    private func secondaryButton(
        label: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.primary)
        }
    }

    // MARK: - バッジ・ラベルコンポーネント

    /// スキャン経過時間を表示するバッジ
    private var elapsedTimeBadge: some View {
        HStack(spacing: 6) {
            // 録画中を示す赤い点インジケーター
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            // 経過秒数（monospacedDigitで数字が変わっても幅が変わらない）
            Text("スキャン中 \(viewModel.elapsedSeconds)秒")
                .font(.subheadline)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// 保存完了時のファイル名バッジ
    private func savedFileBadge(url: URL) -> some View {
        VStack(spacing: 4) {
            Label("保存完了", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            // 末尾のファイル名部分のみ表示（長い場合は中央を省略）
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// エラー内容を表示するバッジ
    private func errorBadge(message: String) -> some View {
        VStack(spacing: 4) {
            Label("エラー", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - LiDAR非搭載デバイス向け表示

    /// LiDARスキャナーが搭載されていないデバイスで表示するエラー画面
    private var lidarUnavailableView: some View {
        VStack(spacing: 20) {
            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("LiDARスキャナーが\n必要です")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("このアプリはLiDAR搭載の\niPhone/iPad（Proモデル）でのみ動作します")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
