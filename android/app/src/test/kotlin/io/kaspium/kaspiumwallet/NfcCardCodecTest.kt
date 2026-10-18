package io.kaspium.kaspiumwallet

import org.junit.Assert.*
import org.junit.Test
import java.security.SecureRandom

class NfcCardCodecTest {
    @Test fun everyPairRecoversTheExactSeed() {
        repeat(100) {
            val secret = ByteArray(64).also { SecureRandom().nextBytes(it) }
            val shares = NfcCardCodec.split(secret)
            for (i in 0..2) for (j in i + 1..2) {
                assertArrayEquals(secret, NfcCardCodec.join(shares[i], shares[j]))
                assertArrayEquals(secret, NfcCardCodec.join(shares[j], shares[i]))
            }
        }
    }
    @Test fun duplicateAndTruncatedSharesAreRejected() {
        val shares = NfcCardCodec.split(ByteArray(64))
        assertThrows(IllegalArgumentException::class.java) { NfcCardCodec.join(shares[0], shares[0]) }
        assertThrows(IllegalArgumentException::class.java) { NfcCardCodec.join(shares[0], ByteArray(64)) }
    }
    @Test fun recordRoundTripsAndEverySingleByteMutationIsRejected() {
        val record = NfcCardCodec.Record(2, ByteArray(32) { it.toByte() }, ByteArray(92), ByteArray(109))
        val data = NfcCardCodec.encode(record)
        val decoded = NfcCardCodec.decode(data)
        assertEquals(2, decoded.slot)
        assertArrayEquals(record.wallet, decoded.wallet)
        assertArrayEquals(record.daily, decoded.daily)
        assertArrayEquals(record.recovery, decoded.recovery)
        for (i in data.indices) {
            val bad = data.copyOf(); bad[i] = (bad[i].toInt() xor 1).toByte()
            assertThrows(IllegalArgumentException::class.java) { NfcCardCodec.decode(bad) }
        }
    }
    @Test fun oldCardsAndOutOfRangeSlotsAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { NfcCardCodec.decode(ByteArray(240)) }
        assertThrows(IllegalArgumentException::class.java) {
            NfcCardCodec.encode(NfcCardCodec.Record(4, ByteArray(32), ByteArray(92), ByteArray(109)))
        }
    }
    @Test fun recoveryCanReadSharesWhenDailyRebindingWasInterrupted() {
        val record = NfcCardCodec.Record(1, ByteArray(32), ByteArray(92), ByteArray(109) { it.toByte() })
        val interrupted = NfcCardCodec.encode(record)
        interrupted[50] = 1
        assertThrows(IllegalArgumentException::class.java) { NfcCardCodec.decode(interrupted) }
        val recovered = NfcCardCodec.decode(interrupted, verifyChecksum = false)
        assertArrayEquals(record.recovery, recovered.recovery)
        assertArrayEquals(record.wallet, recovered.wallet)
        assertEquals(record.slot, recovered.slot)
    }

}
