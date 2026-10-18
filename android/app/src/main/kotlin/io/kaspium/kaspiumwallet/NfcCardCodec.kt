package io.kaspium.kaspiumwallet

import java.security.MessageDigest
import java.security.SecureRandom

/** Versioned format, deliberately distinct from the old NKW5 single-key cards. */
internal object NfcCardCodec {
    const val SIZE = 480
    private val magic = byteArrayOf(75, 78, 70, 1)
    data class Record(val slot: Int, val wallet: ByteArray, val daily: ByteArray, val recovery: ByteArray)
    fun digest(data: ByteArray) = MessageDigest.getInstance("SHA-256").digest(data)
    fun encode(record: Record): ByteArray {
        require(record.slot in 1..3 && record.wallet.size == 32)
        require(record.daily.size == 92 && record.recovery.size == 109)
        val out = ByteArray(SIZE)
        magic.copyInto(out); out[4] = record.slot.toByte()
        record.wallet.copyInto(out, 5)
        record.daily.copyInto(out, 37)
        record.recovery.copyInto(out, 129)
        digest(out.copyOfRange(0, SIZE - 32)).copyInto(out, SIZE - 32)
        return out
    }
    fun decode(data: ByteArray): Record {
        require(data.size == SIZE && data.copyOfRange(0, 4).contentEquals(magic)) {
            "새 Kaspa NFC Wallet 카드가 아닙니다. 이전 앱 카드는 호환되지 않습니다."
        }
        require(MessageDigest.isEqual(digest(data.copyOfRange(0, SIZE - 32)), data.copyOfRange(SIZE - 32, SIZE))) {
            "카드 데이터 검증 실패"
        }
        val slot = data[4].toInt()
        require(slot in 1..3)
        require(data.copyOfRange(238, SIZE - 32).all { it == 0.toByte() })
        return Record(slot, data.copyOfRange(5, 37), data.copyOfRange(37, 129), data.copyOfRange(129, 238))
    }
    private fun mul(a: Int, b: Int): Int {
        var x = a; var y = b; var r = 0
        repeat(8) {
            if (y and 1 != 0) r = r xor x
            x = if (x and 128 != 0) ((x shl 1) xor 0x11b) and 255 else (x shl 1) and 255
            y = y ushr 1
        }
        return r
    }
    fun split(seed: ByteArray): List<ByteArray> {
        require(seed.size == 64)
        val slope = ByteArray(64).also { SecureRandom().nextBytes(it) }
        return try {
            (1..3).map { x -> byteArrayOf(x.toByte()) + ByteArray(64) { i ->
                ((seed[i].toInt() and 255) xor mul(slope[i].toInt() and 255, x)).toByte()
            } }
        } finally { slope.fill(0) }
    }
    fun join(a: ByteArray, b: ByteArray): ByteArray {
        require(a.size == 65 && b.size == 65)
        val x = a[0].toInt(); val y = b[0].toInt()
        require(x in 1..3 && y in 1..3 && x != y) { "서로 다른 카드 2장이 필요합니다" }
        var inverse = 1
        repeat(254) { inverse = mul(inverse, x xor y) }
        return ByteArray(64) { i ->
            val slope = mul((a[i + 1].toInt() xor b[i + 1].toInt()) and 255, inverse)
            ((a[i + 1].toInt() and 255) xor mul(slope, x)).toByte()
        }
    }
}
