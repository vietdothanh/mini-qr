/* 
 * QR Code generator library (Swift)
 * 
 * Copyright (c) Project Nayuki. (MIT License)
 * https://www.nayuki.io/page/qr-code-generator-library
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 * - The above copyright notice and this permission notice shall be included in
 *   all copies or substantial portions of the Software.
 * - The Software is provided "as is", without warranty of any kind, express or
 *   implied, including but not limited to the warranties of merchantability,
 *   fitness for a particular purpose and noninfringement. In no event shall the
 *   authors or copyright holders be liable for any claim, damages or other
 *   liability, whether in an action of contract, tort or otherwise, arising from,
 *   out of or in connection with the Software or the use or other dealings in the
 *   Software.
 */

import BinaryKit
import Foundation

struct QRCode {
	// Scalar parameters:

	/// The version number of this QR Code, which is between 1 and 40 (inclusive).
	/// This determines the size of this barcode.
	private let version: QRCodeVersion
	/// The width and height of this QR Code, measured in modules, between
	/// 21 and 177 (inclusive). This is equal to version * 4 + 17.
	private let size: Int
	/// The error correction level used in this QR Code.
	private let errorCorrectionLevel: QRCodeECC
	/// The index of the mask pattern used in this QR Code, which is between 0 and 7 (inclusive).
	/// Even if a QR Code is created with automatic masking requested (mask = None),
	/// the resulting object still has a mask value between 0 and 7.
	private var mask: QRCodeMask

	// Grids of modules/pixels, with dimensions of size*size:
	
	/// The modules of this QR Code (false = white, true = black).
	/// Immutable after constructor finishes. Accessed through get_module().
	private var modules: [Bool]
	
	/// Indicates function modules that are not subjected to masking. Discarded when constructor finishes.
	private var isFunction: [Bool]
	
	/*---- Static factory functions (high level) ----*/

	/// Returns a QR Code representing the given Unicode text string at the given error correction level.
	/// 
	/// As a conservative upper bound, this function is guaranteed to succeed for strings that have 738 or fewer Unicode
	/// code points (not UTF-8 code units) if the low error correction level is used. The smallest possible
	/// QR Code version is automatically chosen for the output. The ECC level of the result may be higher than
	/// the ecl argument if it can be done without increasing the version.
	/// 
	/// Returns a wrapped `QrCode` if successful, or `Err` if the
	/// data is too long to fit in any version at the given ECC level.
	public static func encode(text: String, ecl: QRCodeECC) throws -> Self {
		let chrs = Array(text)
		let segs = QRSegment.makeSegments(chrs)
		return try QRCode.encode(segments: segs, ecl: ecl)
	}
	
	/// Returns a QR Code representing the given binary data at the given error correction level.
	/// 
	/// This function always encodes using the binary segment mode, not any text mode. The maximum number of
	/// bytes allowed is 2953. The smallest possible QR Code version is automatically chosen for the output.
	/// The ECC level of the result may be higher than the ecl argument if it can be done without increasing the version.
	/// 
	/// Returns a wrapped `QrCode` if successful, or `Err` if the
	/// data is too long to fit in any version at the given ECC level.
	public static func encode(binary data: [UInt8], ecl: QRCodeECC) throws -> Self {
		let segs = [QRSegment.make(bytes: data)]
		return try QRCode.encode(segments: segs, ecl: ecl)
	}
	
	/*---- Static factory functions (mid level) ----*/
	
	/// Returns a QR Code representing the given segments at the given error correction level.
	/// 
	/// The smallest possible QR Code version is automatically chosen for the output. The ECC level
	/// of the result may be higher than the ecl argument if it can be done without increasing the version.
	/// 
	/// This function allows the user to create a custom sequence of segments that switches
	/// between modes (such as alphanumeric and byte) to encode text in less space.
	/// This is a mid-level API; the high-level API is `encode_text()` and `encode_binary()`.
	/// 
	/// Returns a wrapped `QrCode` if successful, or `Err` if the
	/// data is too long to fit in any version at the given ECC level.
	public static func encode(segments: [QRSegment], ecl: QRCodeECC) throws -> Self {
		try QRCode.encodeAdvanced(segments: segments, ecl: ecl, minVersion: qrCodeMinVersion, maxVersion: qrCodeMaxVersion, boostECL: true)
	}
	
	/// Returns a QR Code representing the given segments with the given encoding parameters.
	/// 
	/// The smallest possible QR Code version within the given range is automatically
	/// chosen for the output. Iff boostecl is `true`, then the ECC level of the result
	/// may be higher than the ecl argument if it can be done without increasing the
	/// version. The mask number is either between 0 to 7 (inclusive) to force that
	/// mask, or `None` to automatically choose an appropriate mask (which may be slow).
	/// 
	/// This function allows the user to create a custom sequence of segments that switches
	/// between modes (such as alphanumeric and byte) to encode text in less space.
	/// This is a mid-level API; the high-level API is `encode_text()` and `encode_binary()`.
	/// 
	/// Returns a wrapped `QrCode` if successful, or `Err` if the data is too
	/// long to fit in any version in the given range at the given ECC level.
	public static func encodeAdvanced(segments: [QRSegment], ecl: QRCodeECC, minVersion: QRCodeVersion, maxVersion: QRCodeVersion, mask: QRCodeMask? = nil, boostECL: Bool) throws -> Self {
		assert(minVersion <= maxVersion, "Invalid value")
		
		// Find the minimal version number to use
		var version = minVersion
		var dataUsedBits: UInt!
		while true {
			// Number of data bits available
			let dataCapacityBits: UInt = QRCode.getNumDataCodewords(version: version, ecl: ecl) * 8
			let dataUsed: UInt? = QRSegment.getTotalBits(segments: segments, version: version)
			if let used = dataUsed, used <= dataCapacityBits {
				// The version number is found to be suitable
				dataUsedBits = used
				break
			} else if version >= maxVersion {
				let msg: String
				if let used = dataUsed {
					msg = "Data length = \(used) bits, Max capacity = \(dataCapacityBits) bits"
				} else {
					msg = "Segment too long"
				}
			} else {
				version = QRCodeVersion(version.value + 1)
			}
		}
		
		// Increase error correction level while the data still fits in the current version number
		for newECL in [QRCodeECC.medium, QRCodeECC.quartile, QRCodeECC.high] {
			if boostECL && dataUsedBits <= QRCode.getNumDataCodewords(version: version, ecl: newECL) * 8 {
				ecl = newECL
			}
		}
		
		// Concatenate all segments to create the data bit string
		var bb = BitBuffer()
		for seg in segments {
			bb.appendBits(seg.mode.modeBits(), 4)
			bb.appendBits(UInt32(seg.numChars), seg.mode.numCharCountBits(version: version))
			bb.values += seg.data
		}
		
		assert(bb.count == dataUsedBits)
		
		// Add terminator and pad up to a byte if applicable
		let dataCapacityBits: UInt = QRCode.getNumDataCodeWords(version: version, ecl: ecl)
		assert(bb.count <= dataCapacityBits)
		var numZeroBits = min(4, dataCapacityBits - bb.count)
		bb.appendBits(0, UInt8(numZeroBits))
		numZeroBits = (0 &- bb.count) & 7
		bb.appendBits(0, UInt8(numZeroBits))
		assert(bb.count % 8 == 0)
		
		// Pad with alternating bytes until data capacity is reached
		let padBytes = [0xEC, 0x11]
		var i = 0
		while bb.count < dataCapacityBits {
			bb.appendBits(padBytes[i], 8)
			i += 1
			if i >= padBytes.count {
				i = 0
			}
		}
		
		// Pack bits into bytes in big endian
		var dataCodeWords = [UInt8](repeating: 0, bb.count / 8)
		for (i, bit) in bb.values.enumerated() {
			dataCodeWords[i >> 3] |= UInt8(bit) << (7 - (i & 7))
		}
		
		// Create the QRCode object
		return QRCode.encodeCodewords(version: version, ecl: ecl, dataCodeWords: dataCodeWords, mask: mask)
	}
	
	/*---- Constructor (low level) ----*/
	
	/// Creates a new QR Code with the given version number,
	/// error correction level, data codeword bytes, and mask number.
	/// 
	/// This is a low-level API that most users should not use directly.
	/// A mid-level API is the `encode_segments()` function.
	public static func encodeCodewords(version: QRCodeVersion, ecl: QRCodeECC, dataCodeWords: [UInt8], mask: QRCodeMask? = nil) -> Self {
		var mutMask = mask

		// Initialize fields
		let size = UInt(version.value)
		var result = Self(
			version: version,
			size: Int(size),
			mask: QRCodeMask(0), // Dummy value
			errorCorrectionLevel: ecl,
			modules: Array(repeating: false, count: size * size), // Initially all white
			isFunction: Array(repeating: false, count: size * size)
		)
		
		// Compute ECC, draw modules
		result.drawFunctionPatterns()
		let allCodeWords = result.addECCAndInterleave(dataCodeWords: dataCodeWords)
		result.draw(codewords: allCodeWords)
		
		// Do masking
		if mask == nil { // Automatically choose best mask
			var minPenalty = Int32.max
			for i in UInt8(0)..<8 {
				let newMask = QRCodeMask(i)
				result.apply(mask: newMask)
				result.drawFormatBits(mask: newMask)
				let penalty = result.getPenaltyScore()
				if penalty < minPenalty {
					mutMask = newMask
					minPenalty = penalty
				}
				result.apply(mask: newMask) // Undoes mask due to XOR
			}
		}
		let mask: QRCodeMask = mask!
		result.mask = mask
		result.apply(mask: mask) // Apply the final choice of mask
		result.drawFormatBits(mask: mask)
		
		result.isFunction = []
		return result
	}
}
