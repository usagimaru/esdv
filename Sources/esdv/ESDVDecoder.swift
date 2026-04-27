// ESDVDecoder.swift
// Earthsoft DV コーデックデコーダー
// 仕様: https://earthsoft.jp/PV/tech-codec.html
// 参考: smdn.jp libav earthsoftdv patch
//
// 映像: DV VLC (IEC 61834 / SMPTE 370M 互換) DCT, YUV 4:2:2, 8bit
// 音声: 2ch 16bit PCM 無圧縮 (デコーダーでは扱わない)

import Foundation

// MARK: - デコード結果 (映像のみ)

struct DecodedVideoFrame {
	/// YUV 4:2:2 プレーナー
	/// Y:  width × height バイト
	/// Cb: (width/2) × height バイト
	/// Cr: (width/2) × height バイト
	let yPlane: [UInt8]
	let cbPlane: [UInt8]
	let crPlane: [UInt8]
}

// MARK: - メインデコーダー

final class ESDVDecoder {

	let fileHeader: ESDVFileHeader

	// 量子化テーブル: ジグザグスキャン順に並び替え済み
	// (VLC デコードで得られる coefIdx で直接参照可能)
	private let lumaQTable:   [UInt16]  // 64 要素
	private let chromaQTable: [UInt16]  // 64 要素

	// ホットパス用の事前確保バッファ (フレームごとに再利用)
	private var idctWorkspace = [Double](repeating: 0, count: 64)
	private var dctOut        = [Int16](repeating: 0, count: 64)
	private var blocks        = [[Int16]](repeating: [Int16](repeating: 0, count: 64), count: 8)

	init(fileHeader: ESDVFileHeader) {
		self.fileHeader = fileHeader
		lumaQTable   = Self.reorderToZigzag(fileHeader.lumaQuantTable)
		chromaQTable = Self.reorderToZigzag(fileHeader.chromaQuantTable)
	}

	// MARK: - 単フレームデコード

	func decodeFrame(_ frame: ESDVFrame) throws -> DecodedVideoFrame {
		let w = fileHeader.width
		let h = fileHeader.height
		let isProgressive = fileHeader.isProgressive

		// YUV 4:2:2: 色差は水平半分、垂直同一
		var yPlane  = [UInt8](repeating: 128, count: w * h)
		var cbPlane = [UInt8](repeating: 128, count: (w / 2) * h)
		var crPlane = [UInt8](repeating: 128, count: (w / 2) * h)

		let regionCount = isProgressive ? 2 : 4

		for regionIdx in 0 ..< regionCount {
			guard regionIdx < frame.videoRegions.count,
				  !frame.videoRegions[regionIdx].isEmpty else { continue }

			try decodeRegion(
				data: frame.videoRegions[regionIdx],
				regionIndex: regionIdx,
				regionCount: regionCount,
				frameIndex: frame.index,
				width: w,
				height: h,
				isProgressive: isProgressive,
				yPlane: &yPlane,
				cbPlane: &cbPlane,
				crPlane: &crPlane
			)
		}

		return DecodedVideoFrame(
			yPlane: yPlane,
			cbPlane: cbPlane,
			crPlane: crPlane
		)
	}

	// MARK: - 映像領域デコード

	private(set) var bitstreamErrorCount = 0

	private func decodeRegion(
		data: Data,
		regionIndex: Int,
		regionCount: Int,
		frameIndex: Int,
		width: Int,
		height: Int,
		isProgressive: Bool,
		yPlane: inout [UInt8],
		cbPlane: inout [UInt8],
		crPlane: inout [UInt8]
	) throws {
		// ===================================================================
		// 領域 → マクロブロック割り当て (smdn.jp libav パッチ準拠)
		//
		// 各領域はインターリーブされた MB 行を担当する:
		//   インターレース (4領域): 領域 i → MB行 i, i+4, i+8, …
		//   プログレッシブ (2領域): 領域 i → MB行 i, i+2, i+4, …
		//
		// フレーム高さが 16*regionCount で割り切れない場合、余りの MB 行は
		// 各領域の末尾に順次振り分けられる ("pad" 領域)。
		// ===================================================================

		let mbPerLine = width / 16
		let nbMBTotal = (width * height) / (16 * 16)

		// 各領域の MB 数を計算 (参照: smdn.jp switch (nb_mb_total % nb_blocks))
		var nbMBForRegion = [Int](repeating: nbMBTotal / regionCount, count: regionCount)
		switch nbMBTotal % regionCount {
		case 1:
			nbMBForRegion[1] += 1
		case 2:
			nbMBForRegion[1] += 1
			if regionCount > 3 { nbMBForRegion[3] += 1 }
		case 3:
			nbMBForRegion[1] += 1
			nbMBForRegion[2] += 1
			if regionCount > 3 { nbMBForRegion[3] += 1 }
		default:
			break
		}

		let myNBMB = nbMBForRegion[regionIndex]

		// pad 領域の計算 (参照: smdn.jp esdv_decode_init_context)
		let mbPadStartY = (height / (16 * regionCount)) * regionCount  // MB行
		var nbMBPadAccum = 0
		var myPadX = 0
		var myPadY = mbPadStartY

		for i in 0 ..< regionCount {
			if i == regionIndex {
				if i == 0 {
					myPadX = 0
					myPadY = mbPadStartY
				} else {
					myPadX = nbMBPadAccum % mbPerLine
					myPadY = nbMBPadAccum / mbPerLine + mbPadStartY
				}
				break
			}
			let overshoot = nbMBForRegion[i] - (mbPadStartY / regionCount) * mbPerLine
			nbMBPadAccum += overshoot
		}

		// 最下段 (高さが 16 の倍数でない場合) の検出
		// 最後の領域のみが bottom 行を持つ (参照: smdn.jp mb_bottom_y)
		let hasBottomPartial = (height % 16 != 0)
		let mbBottomY = hasBottomPartial && (regionIndex == regionCount - 1)
			? height / 16 : -1

		var reader = BitReader(data: data)

		var mbX = 0
		var mbY = regionIndex
		let mbYStep = regionCount
		var inPadZone = false
		var currentMBYStep = mbYStep

		for _ in 0 ..< myNBMB {
			guard reader.remainingBits > 20 else { break }

			// 最下段 (32×8) 判定
			let isBottom = (mbY == mbBottomY)

			try decodeMB(
				reader: &reader,
				mbX: mbX, mbY: mbY,
				isBottom: isBottom,
				isProgressive: isProgressive,
				width: width, height: height,
				yPlane: &yPlane, cbPlane: &cbPlane, crPlane: &crPlane
			)

			mbX += 1
			if mbX == mbPerLine {
				mbX = 0
				mbY += currentMBYStep

				// pad 領域への遷移 (参照: smdn.jp esdv_decode_block_thread)
				if regionIndex > 0 && !inPadZone && mbY >= myPadY {
					inPadZone = true
					currentMBYStep = 1
					mbY = myPadY
					mbX = myPadX
				}
			}
		}

	}

	// MARK: - 単一マクロブロックのデコード

	private func decodeMB(
		reader: inout BitReader,
		mbX: Int, mbY: Int,
		isBottom: Bool,
		isProgressive: Bool,
		width: Int, height: Int,
		yPlane: inout [UInt8],
		cbPlane: inout [UInt8],
		crPlane: inout [UInt8]
	) throws {
		// DCT モードビット: インターレース時は最下段含め常にビットストリームに存在
		// (smdn.jp: get_bits1(gb) を interlaced ブロック冒頭で無条件に読む)
		// 最下段 MB は常にフレームモード (仕様: "必ずフレームモードを適用")
		let fieldMode: Bool
		if !isProgressive {
			let rawFieldMode = try reader.readBit() != 0
			fieldMode = isBottom ? false : rawFieldMode
		} else {
			fieldMode = false
		}

		// 8 個の DCT ブロック: Y0, Y1, Y2, Y3, Cr0, Cr1, Cb0, Cb1
		for b in 0 ..< 8 {
			for i in 0 ..< 64 { blocks[b][i] = 0 }
		}
		for b in 0 ..< 8 {
			let isChroma = b >= 4
			let qTable = isChroma ? chromaQTable : lumaQTable
			do {
				try decodeDCTBlock(reader: &reader, qTable: qTable, out: &blocks[b])
			} catch {
				if reader.remainingBits < 20 { break }
				throw error
			}
		}

		let pixelY = mbY * 16

		// マクロブロックをプレーンに書き込む
		if isBottom {
			// 最下段: 32×8 マクロブロック (mbX は自動的に 2 倍)
			let pixelX = mbX * 32
			writeMB32x8(
				blocks: blocks, mbX: pixelX, mbY: pixelY,
				width: width, height: height,
				yPlane: &yPlane, cbPlane: &cbPlane, crPlane: &crPlane
			)
		} else {
			let pixelX = mbX * 16
			writeMB16x16(
				blocks: blocks, mbX: pixelX, mbY: pixelY,
				width: width, height: height,
				fieldMode: fieldMode,
				yPlane: &yPlane, cbPlane: &cbPlane, crPlane: &crPlane
			)
		}
	}

	// MARK: - DCT ブロックデコード

	private func decodeDCTBlock(
		reader: inout BitReader,
		qTable: [UInt16],
		out: inout [Int16]
	) throws {
		// DC 成分: 9bit 符号付き (2の補数)
		// 仕様上の量子化ステップ 32 に対し、IDCT の 1/8 正規化を考慮して ×4
		// (dc * 32 / 8 = dc * 4, smdn.jp: block[0] = dc << 2)
		let dcRaw = try reader.readBitsSigned(9)
		out[0] = Int16(clamping: dcRaw * 4)

		// Q フラグ: AC 係数のスケーリング制御
		//   q=0: (level * qTable) >> 3  (通常)
		//   q=1: (level * qTable) >> 2  (AC を 2倍 = 量子化テーブル一時的 2倍に相当)
		let qFlag = try reader.readBit()
		let acScale = 3 - qFlag

		// AC 成分: DV VLC デコード (smdn.jp リファレンス準拠)
		var coefIdx = 1
		while true {
			let vlcResult = try readDVVLC(reader: &reader)

			if vlcResult.isEOB { break }

			coefIdx += vlcResult.run

			if coefIdx >= 64 {
				bitstreamErrorCount += 1
				break
			}

			if vlcResult.level != 0 {
				let q = Int(qTable[coefIdx])
				let coef = (vlcResult.level * q) >> acScale
				out[coefIdx] = Int16(clamping: coef)
			}
			coefIdx += 1
		}

		// 逆ジグザグスキャン → ラスタースキャン順に配置 (事前確保バッファ使用)
		for i in 0 ..< 64 { dctOut[i] = 0 }
		for i in 0 ..< 64 {
			dctOut[zigzagTable[i]] = out[i]
		}

		// 逆 DCT (ワークスペースは事前確保済み)
		idct8x8(&dctOut, workspace: &idctWorkspace)
		for i in 0 ..< 64 { out[i] = dctOut[i] }
	}

	// MARK: - マクロブロック書き込み (16×16, 通常)

	private func writeMB16x16(
		blocks: [[Int16]],
		mbX: Int, mbY: Int,
		width: Int, height: Int,
		fieldMode: Bool,
		yPlane: inout [UInt8],
		cbPlane: inout [UInt8],
		crPlane: inout [UInt8]
	) {
		let cw = width / 2
		let chromaX = mbX / 2

		if !fieldMode {
			// フレームモード: Y0=左上, Y1=左下, Y2=右上, Y3=右下
			let yOffsets: [(dx: Int, dy: Int)] = [(0, 0), (0, 8), (8, 0), (8, 8)]
			for b in 0 ..< 4 {
				let (dx, dy) = yOffsets[b]
				let clipH = min(8, height - (mbY + dy))
				if clipH <= 0 { continue }
				write8x8Block(blocks[b], toPlane: &yPlane,
							  x: mbX + dx, y: mbY + dy,
							  stride: width, clipH: clipH, rowStep: 1)
			}

			// 色差 4:2:2: Cr0=上半, Cr1=下半, Cb0=上半, Cb1=下半
			let topClipH = min(8, height - mbY)
			let botClipH = min(8, height - (mbY + 8))
			if topClipH > 0 {
				write8x8Block(blocks[4], toPlane: &crPlane,
							  x: chromaX, y: mbY, stride: cw, clipH: topClipH, rowStep: 1)
				write8x8Block(blocks[6], toPlane: &cbPlane,
							  x: chromaX, y: mbY, stride: cw, clipH: topClipH, rowStep: 1)
			}
			if botClipH > 0 {
				write8x8Block(blocks[5], toPlane: &crPlane,
							  x: chromaX, y: mbY + 8, stride: cw, clipH: botClipH, rowStep: 1)
				write8x8Block(blocks[7], toPlane: &cbPlane,
							  x: chromaX, y: mbY + 8, stride: cw, clipH: botClipH, rowStep: 1)
			}
		} else {
			// フィールドモード: 偶数行/奇数行を交互に書き込み (rowStep=2)
			// Y0=左偶数行, Y1=左奇数行, Y2=右偶数行, Y3=右奇数行
			write8x8Block(blocks[0], toPlane: &yPlane,
						  x: mbX, y: mbY, stride: width, clipH: 16, rowStep: 2)
			write8x8Block(blocks[1], toPlane: &yPlane,
						  x: mbX, y: mbY + 1, stride: width, clipH: 16, rowStep: 2)
			write8x8Block(blocks[2], toPlane: &yPlane,
						  x: mbX + 8, y: mbY, stride: width, clipH: 16, rowStep: 2)
			write8x8Block(blocks[3], toPlane: &yPlane,
						  x: mbX + 8, y: mbY + 1, stride: width, clipH: 16, rowStep: 2)

			// 色差: Cr0/Cb0=偶数行, Cr1/Cb1=奇数行
			write8x8Block(blocks[4], toPlane: &crPlane,
						  x: chromaX, y: mbY, stride: cw, clipH: 16, rowStep: 2)
			write8x8Block(blocks[5], toPlane: &crPlane,
						  x: chromaX, y: mbY + 1, stride: cw, clipH: 16, rowStep: 2)
			write8x8Block(blocks[6], toPlane: &cbPlane,
						  x: chromaX, y: mbY, stride: cw, clipH: 16, rowStep: 2)
			write8x8Block(blocks[7], toPlane: &cbPlane,
						  x: chromaX, y: mbY + 1, stride: cw, clipH: 16, rowStep: 2)
		}
	}

	// MARK: - マクロブロック書き込み (32×8, 最下段)

	private func writeMB32x8(
		blocks: [[Int16]],
		mbX: Int, mbY: Int,
		width: Int, height: Int,
		yPlane: inout [UInt8],
		cbPlane: inout [UInt8],
		crPlane: inout [UInt8]
	) {
		let clipH = min(8, height - mbY)
		if clipH <= 0 { return }

		// 輝度: 横並び Y0(+0), Y2(+8), Y1(+16), Y3(+24)
		let yOrder: [(blockIdx: Int, dx: Int)] = [(0, 0), (2, 8), (1, 16), (3, 24)]
		for (b, dx) in yOrder {
			write8x8Block(blocks[b], toPlane: &yPlane,
						  x: mbX + dx, y: mbY,
						  stride: width, clipH: clipH, rowStep: 1)
		}

		// 色差 4:2:2: Cr0, Cr1 横並び / Cb0, Cb1 横並び
		let cw = width / 2
		let chromaX = mbX / 2
		write8x8Block(blocks[4], toPlane: &crPlane,
					  x: chromaX, y: mbY, stride: cw, clipH: clipH, rowStep: 1)
		write8x8Block(blocks[5], toPlane: &crPlane,
					  x: chromaX + 8, y: mbY, stride: cw, clipH: clipH, rowStep: 1)
		write8x8Block(blocks[6], toPlane: &cbPlane,
					  x: chromaX, y: mbY, stride: cw, clipH: clipH, rowStep: 1)
		write8x8Block(blocks[7], toPlane: &cbPlane,
					  x: chromaX + 8, y: mbY, stride: cw, clipH: clipH, rowStep: 1)
	}

	// MARK: - 8×8 ブロック書き込み

	@inline(__always)
	private func write8x8Block(
		_ block: [Int16],
		toPlane plane: inout [UInt8],
		x: Int, y: Int, stride: Int, clipH: Int,
		rowStep: Int
	) {
		let planeSize = plane.count
		for row in 0 ..< 8 {
			let outputRow = y + row * rowStep
			// フィールドモード (rowStep=2) の場合 clipH=16 なので
			// outputRow < y + 16 の範囲内。フレームモードは clipH で制限。
			if outputRow >= y + clipH { break }
			let planeBase = outputRow * stride + x
			let blockBase = row * 8
			// ブロックがプレーン内に完全に収まるか判定
			if planeBase >= 0 && planeBase + 8 <= planeSize {
				// 高速パス: 境界チェック不要
				for col in 0 ..< 8 {
					let val = Int(block[blockBase + col]) + 128
					plane[planeBase + col] = UInt8(clamping: val)
				}
			} else {
				// 低速パス: ピクセル単位境界チェック
				for col in 0 ..< 8 {
					let idx = planeBase + col
					guard idx >= 0, idx < planeSize else { continue }
					let val = Int(block[blockBase + col]) + 128
					plane[idx] = UInt8(clamping: val)
				}
			}
		}
	}

	// MARK: - 量子化テーブル変換

	/// ラスタースキャン順 → ジグザグスキャン順に並び替え
	/// result[zigzagIdx] = table[rasterPos(zigzagIdx)]
	private static func reorderToZigzag(_ table: [UInt16]) -> [UInt16] {
		var result = [UInt16](repeating: 0, count: 64)
		for i in 0 ..< 64 {
			result[i] = table[zigzagTable[i]]
		}
		return result
	}
}

// MARK: - 逆 DCT (8×8, 行-列分離法)
//
// 2D IDCT を行-列分離で計算。事前確保ワークスペースを使用しアロケーションゼロ。
// 8×8 行列では vDSP_mmulD より手動ループの方が高速
// (関数呼び出しオーバーヘッドが支配的なため)。

private let idctCosTable: [Double] = {
	// フラット配列 [x * 8 + u] で cos((2x+1)*u*π/16) を格納
	var table = [Double](repeating: 0, count: 64)
	for x in 0 ..< 8 {
		for u in 0 ..< 8 {
			table[x * 8 + u] = cos(Double(2 * x + 1) * Double(u) * Double.pi / 16.0)
		}
	}
	return table
}()

private let idctC: [Double] = {
	var c = [Double](repeating: 1.0, count: 8)
	c[0] = 1.0 / sqrt(2.0)
	return c
}()

func idct8x8(_ block: inout [Int16], workspace: inout [Double]) {
	let cos = idctCosTable
	let C   = idctC

	// パス1: 各行 (固定 v) に対して u → x 変換
	for v in 0 ..< 8 {
		let rowBase = v * 8
		for x in 0 ..< 8 {
			let cosBase = x * 8
			var sum = C[0] * Double(block[rowBase]) * cos[cosBase]
			sum += C[1] * Double(block[rowBase + 1]) * cos[cosBase + 1]
			sum += C[2] * Double(block[rowBase + 2]) * cos[cosBase + 2]
			sum += C[3] * Double(block[rowBase + 3]) * cos[cosBase + 3]
			sum += C[4] * Double(block[rowBase + 4]) * cos[cosBase + 4]
			sum += C[5] * Double(block[rowBase + 5]) * cos[cosBase + 5]
			sum += C[6] * Double(block[rowBase + 6]) * cos[cosBase + 6]
			sum += C[7] * Double(block[rowBase + 7]) * cos[cosBase + 7]
			workspace[rowBase + x] = sum
		}
	}

	// パス2: 各列 (固定 x) に対して v → y 変換、1/4 正規化
	for x in 0 ..< 8 {
		for y in 0 ..< 8 {
			let cosBase = y * 8
			var sum = C[0] * workspace[x] * cos[cosBase]
			sum += C[1] * workspace[8 + x] * cos[cosBase + 1]
			sum += C[2] * workspace[16 + x] * cos[cosBase + 2]
			sum += C[3] * workspace[24 + x] * cos[cosBase + 3]
			sum += C[4] * workspace[32 + x] * cos[cosBase + 4]
			sum += C[5] * workspace[40 + x] * cos[cosBase + 5]
			sum += C[6] * workspace[48 + x] * cos[cosBase + 6]
			sum += C[7] * workspace[56 + x] * cos[cosBase + 7]
			block[y * 8 + x] = Int16(clamping: Int((sum * 0.25).rounded()))
		}
	}
}

// MARK: - DV VLC デコーダー (IEC 61834 / SMPTE 370M 互換)
//
// 12-bit ルックアップテーブル (4096 エントリ) + 13/15-bit 拡張コード
// テーブル出典: FFmpeg dv_vlc_data (ff_dv_vlc_run / ff_dv_vlc_level, 409 エントリと照合済み)

struct DVVLCResult {
	let run: Int
	let level: Int
	let isEOB: Bool
}

private struct VLCEntry {
	var run: UInt8   = 0
	var level: UInt8  = 0
	var bits: UInt8   = 0    // 消費ビット数 (0 = 拡張コードへフォールスルー)
}

/// 12-bit ルックアップテーブル
private let dvVLCTable: [VLCEntry] = {
	var table = [VLCEntry](repeating: VLCEntry(), count: 4096)

	// (code, codeBits, run, level)
	// level > 0: sign bit が後続
	// level == 0 && bits == 4: EOB (code = 0110)
	// level == 0 && bits > 4: ゼロスキップ (run 分)
	let entries: [(code: Int, bits: Int, run: Int, level: Int)] = [
		// 2-bit
		(0x00, 2, 0, 1),
		// 3-bit
		(0x02, 3, 0, 2),
		// 4-bit
		(0x06, 4, 0, 0),   // EOB
		(0x07, 4, 1, 1),
		(0x08, 4, 0, 3),
		(0x09, 4, 0, 4),
		// 5-bit
		(0x14, 5, 2, 1),
		(0x15, 5, 1, 2),
		(0x16, 5, 0, 5),
		(0x17, 5, 0, 6),
		// 6-bit
		(0x30, 6, 3, 1),
		(0x31, 6, 4, 1),
		(0x32, 6, 0, 7),
		(0x33, 6, 0, 8),
		// 7-bit
		(0x68, 7, 5, 1),
		(0x69, 7, 6, 1),
		(0x6A, 7, 2, 2),
		(0x6B, 7, 1, 3),
		(0x6C, 7, 1, 4),
		(0x6D, 7, 0, 9),
		(0x6E, 7, 0, 10),
		(0x6F, 7, 0, 11),
		// 8-bit
		(0xE0, 8, 7, 1),
		(0xE1, 8, 8, 1),
		(0xE2, 8, 9, 1),
		(0xE3, 8, 10, 1),
		(0xE4, 8, 3, 2),
		(0xE5, 8, 4, 2),
		(0xE6, 8, 2, 3),
		(0xE7, 8, 1, 5),
		(0xE8, 8, 1, 6),
		(0xE9, 8, 1, 7),
		(0xEA, 8, 0, 12),
		(0xEB, 8, 0, 13),
		(0xEC, 8, 0, 14),
		(0xED, 8, 0, 15),
		(0xEE, 8, 0, 16),
		(0xEF, 8, 0, 17),
		// 9-bit
		(0x1E0, 9, 11, 1),
		(0x1E1, 9, 12, 1),
		(0x1E2, 9, 13, 1),
		(0x1E3, 9, 14, 1),
		(0x1E4, 9, 5, 2),
		(0x1E5, 9, 6, 2),
		(0x1E6, 9, 3, 3),
		(0x1E7, 9, 4, 3),
		(0x1E8, 9, 2, 4),
		(0x1E9, 9, 2, 5),
		(0x1EA, 9, 1, 8),
		(0x1EB, 9, 0, 18),
		(0x1EC, 9, 0, 19),
		(0x1ED, 9, 0, 20),
		(0x1EE, 9, 0, 21),
		(0x1EF, 9, 0, 22),
		// 10-bit
		(0x3E0, 10, 5, 3),
		(0x3E1, 10, 3, 4),
		(0x3E2, 10, 3, 5),
		(0x3E3, 10, 2, 6),
		(0x3E4, 10, 1, 9),
		(0x3E5, 10, 1, 10),
		(0x3E6, 10, 1, 11),
		// 11-bit
		(0x7D0, 11, 6, 3),
		(0x7D1, 11, 4, 4),
		(0x7D2, 11, 3, 6),
		(0x7D3, 11, 1, 12),
		(0x7D4, 11, 1, 13),
		(0x7D5, 11, 1, 14),
		(0x7CE, 11, 0, 0),   // skip
		(0x7CF, 11, 1, 0),   // skip
		// 12-bit (level > 0)
		(0xFB0, 12, 7, 2),
		(0xFB1, 12, 8, 2),
		(0xFB2, 12, 9, 2),
		(0xFB3, 12, 10, 2),
		(0xFB4, 12, 7, 3),
		(0xFB5, 12, 8, 3),
		(0xFB6, 12, 4, 5),
		(0xFB7, 12, 3, 7),
		(0xFB8, 12, 2, 7),
		(0xFB9, 12, 2, 8),
		(0xFBA, 12, 2, 9),
		(0xFBB, 12, 2, 10),
		(0xFBC, 12, 2, 11),
		(0xFBD, 12, 1, 15),
		(0xFBE, 12, 1, 16),
		(0xFBF, 12, 1, 17),
		// 12-bit (skip)
		(0xFAC, 12, 2, 0),
		(0xFAD, 12, 3, 0),
		(0xFAE, 12, 4, 0),
		(0xFAF, 12, 5, 0),
	]

	for entry in entries {
		let shift = 12 - entry.bits
		let base = entry.code << shift
		let count = 1 << shift
		let vlcEntry = VLCEntry(
			run: UInt8(entry.run),
			level: UInt8(entry.level),
			bits: UInt8(entry.bits)
		)
		for j in 0 ..< count {
			table[base + j] = vlcEntry
		}
	}

	// 13-bit run 拡張 (prefix 1111110 = 0x7E) と
	// 15-bit level 拡張 (prefix 1111111 = 0x7F) は
	// 12-bit テーブルでは bits=0 のまま → readDVVLC で別途処理

	return table
}()

/// DV VLC コードを 1 つ読み取る
func readDVVLC(reader: inout BitReader) throws -> DVVLCResult {
	let peek12 = try reader.peekBits(12)
	let entry = dvVLCTable[peek12]

	if entry.bits > 0 {
		reader.skipBits(Int(entry.bits))

		let run = Int(entry.run)
		let level = Int(entry.level)

		// EOB: 4-bit code 0110
		if level == 0 && entry.bits == 4 {
			return DVVLCResult(run: 0, level: 0, isEOB: true)
		}

		// level == 0: ゼロスキップ (sign bit なし)
		if level == 0 {
			return DVVLCResult(run: run, level: 0, isEOB: false)
		}

		// level > 0: 後続 sign bit (0=正, 1=負)
		let sign = try reader.readBit()
		let signedLevel = sign != 0 ? -level : level
		return DVVLCResult(run: run, level: signedLevel, isEOB: false)
	}

	// 12-bit 未解決 → 13-bit / 15-bit 拡張コード
	let top7 = peek12 >> 5

	if top7 == 0x7E {
		// 13-bit run 拡張: 1111110 (7bit) + 6-bit run
		reader.skipBits(7)
		let run = try reader.readBits(6)
		return DVVLCResult(run: run, level: 0, isEOB: false)
	}

	if top7 == 0x7F {
		// level 拡張: 1111111 (7bit) + 9-bit signed level = 合計 16 bits
		// smdn.jp パッチ: level = (raw9 & 1) ? -(raw9 >> 1) : +(raw9 >> 1)
		// 9-bit フィールド: [8-bit magnitude][1-bit sign], sign: 1=負, 0=正
		reader.skipBits(7)
		let rawLevel = try reader.readBits(9)
		let magnitude = rawLevel >> 1
		let sign = rawLevel & 1
		let level = sign != 0 ? -magnitude : magnitude
		return DVVLCResult(run: 0, level: level, isEOB: false)
	}

	throw ESDVError.bitstreamError(
		frame: -1, region: -1,
		detail: "VLC: 不正なコード (peek12=0b\(String(peek12, radix: 2)))")
}

// MARK: - ビットリーダー

struct BitReader {
	private let bytes: [UInt8]
	private(set) var bitPosition: Int = 0

	init(data: Data) {
		self.bytes = Array(data)
	}

	var remainingBits: Int { bytes.count * 8 - bitPosition }

	@inline(__always)
	mutating func readBit() throws -> Int {
		let byteIdx = bitPosition >> 3
		guard byteIdx < bytes.count else {
			throw ESDVError.bitstreamError(
				frame: -1, region: -1,
				detail: "BitReader: データ枯渇 (pos=\(bitPosition) total=\(bytes.count * 8))")
		}
		let bitIdx = 7 - (bitPosition & 7)
		let bit = Int((bytes[byteIdx] >> bitIdx) & 1)
		bitPosition += 1
		return bit
	}

	mutating func readBits(_ n: Int) throws -> Int {
		// バイト境界をまたぐ場合でも最大3バイトから一括読み取り
		let byteIdx = bitPosition >> 3
		let bitOff  = bitPosition & 7
		guard byteIdx < bytes.count else {
			throw ESDVError.bitstreamError(
				frame: -1, region: -1,
				detail: "BitReader: データ枯渇 (pos=\(bitPosition))")
		}
		// 最大24ビット (3バイト) をアキュムレータに読み込み
		var acc: UInt32 = UInt32(bytes[byteIdx]) << 16
		if byteIdx + 1 < bytes.count { acc |= UInt32(bytes[byteIdx + 1]) << 8 }
		if byteIdx + 2 < bytes.count { acc |= UInt32(bytes[byteIdx + 2]) }
		// 上位ビットから n ビット抽出
		let shift = 24 - bitOff - n
		let result = Int((acc >> shift) & ((1 << n) - 1))
		bitPosition += n
		return result
	}

	mutating func readBitsSigned(_ n: Int) throws -> Int {
		let raw = try readBits(n)
		let signBit = 1 << (n - 1)
		return (raw & (signBit - 1)) - (raw & signBit)
	}

	mutating func peekBits(_ n: Int) throws -> Int {
		let byteIdx = bitPosition >> 3
		let bitOff  = bitPosition & 7
		if byteIdx >= bytes.count { return 0 }
		var acc: UInt32 = UInt32(bytes[byteIdx]) << 16
		if byteIdx + 1 < bytes.count { acc |= UInt32(bytes[byteIdx + 1]) << 8 }
		if byteIdx + 2 < bytes.count { acc |= UInt32(bytes[byteIdx + 2]) }
		let shift = 24 - bitOff - n
		if shift >= 0 {
			return Int((acc >> shift) & ((1 << n) - 1))
		}
		// データ末端で n ビット取れない場合: 取れる分を上位に詰める
		return Int((acc << (-shift)) >> (32 - n)) & ((1 << n) - 1)
	}

	@inline(__always)
	mutating func skipBits(_ n: Int) {
		bitPosition += n
	}
}

// MARK: - ジグザグスキャンテーブル

/// ジグザグインデックス → ラスタースキャン位置
let zigzagTable: [Int] = [
	 0,  1,  8, 16,  9,  2,  3, 10,
	17, 24, 32, 25, 18, 11,  4,  5,
	12, 19, 26, 33, 40, 48, 41, 34,
	27, 20, 13,  6,  7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36,
	29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63
]
