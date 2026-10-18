package io.kaspium.kaspiumwallet

import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.MifareClassic
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.SecureRandom
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/** No plaintext seed is persisted. All NFC IO and password KDF work stays off the UI thread. */
internal class NfcWalletBridge(private val activity: FlutterFragmentActivity, private val channel: MethodChannel) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val adapter get() = NfcAdapter.getDefaultAdapter(activity)
    @Volatile private var pending: MethodChannel.Result? = null
    private val workResult = ThreadLocal<MethodChannel.Result?>()
    private var enrollmentSeed: ByteArray? = null
    private val attempted = linkedMapOf<Int, String>()
    private val rebindRecords = linkedMapOf<String, NfcCardCodec.Record>()
    private var prompt: BiometricPrompt? = null
    private var records = emptyList<NfcCardCodec.Record>()
    private val recovery = linkedMapOf<Int, NfcCardCodec.Record>()
    private val written = linkedMapOf<Int, String>()
    private var rebinding = false
    private var enrollmentExpires = 0L
    private var enrollmentWallet: ByteArray? = null
    private var rebindDaily: ByteArray? = null
    private val timeout = Runnable { fail("TIMEOUT", "카드 대기 시간이 초과되었습니다. 다시 태그하세요.") }

    init { channel.setMethodCallHandler(::handle) }
    private fun status(text: String) = main.post { channel.invokeMethod("progress", text) }
    private fun finish(value: Any?) {
        val expected = workResult.get() ?: pending
        main.post {
            if (expected == null || pending !== expected) {
                if (value is ByteArray) value.fill(0)
                if (value is Map<*, *>) value.values.filterIsInstance<ByteArray>().forEach { it.fill(0) }
                return@post
            }
            adapter?.disableReaderMode(activity); main.removeCallbacks(timeout)
            val result = pending; pending = null; prompt = null; result?.success(value)
            if (value is ByteArray) value.fill(0)
            if (value is Map<*, *>) value.values.filterIsInstance<ByteArray>().forEach { it.fill(0) }
        }
    }
    private fun fail(code: String, message: String) {
        val expected = workResult.get() ?: pending
        main.post {
            if (expected == null || pending !== expected) return@post
            enrollmentSeed?.fill(0); enrollmentSeed = null
            adapter?.disableReaderMode(activity); main.removeCallbacks(timeout)
            val result = pending; pending = null; prompt = null; result?.error(code, message, null)
        }
    }
    private fun runWork(expected: MethodChannel.Result? = pending, block: () -> Unit) {
        worker.execute {
            if (expected == null || pending !== expected) return@execute
            workResult.set(expected)
            try { block() } catch (e: Exception) { fail("NFC_ERROR", e.message ?: "NFC 작업 실패") }
            finally { workResult.remove() }
        }
    }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancel") { cancel(); result.success(null); return }
        if (pending != null) { result.error("BUSY", "진행 중인 작업을 완료하세요", null); return }
        pending = result
        try {
            when (call.method) {
                "begin" -> begin(call)
                "write" -> write(call.argument<Int>("slot") ?: 0)
                "unlock" -> unlock(call.argument<ByteArray>("wallet") ?: error("wallet required"))
                "readRecovery" -> readRecovery()
                "recover" -> recover(call.argument<String>("password") ?: "")
                "clear" -> { clearEnrollment(); recovery.clear(); finish(null) }
                else -> { pending = null; result.notImplemented() }
            }
        } catch (e: Exception) { fail("NFC_ERROR", e.message ?: "NFC 작업 실패") }
    }
    fun cancel() {
        val result = pending; pending = null
        enrollmentSeed?.fill(0); enrollmentSeed = null
        prompt?.cancelAuthentication(); prompt = null
        adapter?.disableReaderMode(activity); main.removeCallbacks(timeout)
        result?.error("CANCELLED", "작업이 취소되었습니다", null)
    }
    fun pause() { if (prompt == null && pending != null) cancel() }
    fun close() { cancel(); clearEnrollment(); recovery.clear(); worker.shutdown() }
    private fun clearEnrollment() {
        records = emptyList(); written.clear(); attempted.clear(); rebindRecords.clear(); rebindDaily = null; enrollmentWallet = null
        enrollmentExpires = 0L
    }
    private fun key(wallet: ByteArray): SecretKey {
        val alias = "kaspium_nfc_v1_" + wallet.joinToString("") { "%02x".format(it) }
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance("AES", "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setUserAuthenticationRequired(true)
                .setUserAuthenticationValidityDurationSeconds(-1)
                .setInvalidatedByBiometricEnrollment(true).build())
            generateKey()
        }
    }
    private fun biometric(cipher: Cipher, onSuccess: (Cipher) -> Unit) {
        val expected = workResult.get() ?: pending
        check(BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS) {
            "강한 생체인증을 먼저 등록하세요. PIN으로 대체할 수 없습니다."
        }
        main.post {
            if (pending !== expected) return@post
            prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object: BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (pending !== expected) return
                    val authorized = result.cryptoObject?.cipher
                    if (authorized == null) { fail("AUTH", "생체인증 암호화 승인 실패"); return }
                    prompt = null
                    runWork(expected) { onSuccess(authorized) }
                }
                override fun onAuthenticationError(code: Int, message: CharSequence) { if (pending === expected) fail("AUTH", message.toString()) }
            })
            prompt!!.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle("Kaspa NFC Wallet")
                .setSubtitle("NFC 지갑 키 사용 승인")
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .setNegativeButtonText("취소").build(), BiometricPrompt.CryptoObject(cipher))
        }
    }
    private fun passwordKey(password: String, salt: ByteArray): SecretKey {
        val spec = PBEKeySpec(password.toCharArray(), salt, 600000, 256)
        return try { SecretKeySpec(SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded, "AES") }
        finally { spec.clearPassword() }
    }
    private fun passwordEncrypt(data: ByteArray, password: String, aad: ByteArray): ByteArray {
        val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, passwordKey(password, salt)); cipher.updateAAD(aad)
        return salt + cipher.iv + cipher.doFinal(data)
    }
    private fun passwordDecrypt(data: ByteArray, password: String, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, passwordKey(password, data.copyOfRange(0, 16)), GCMParameterSpec(128, data.copyOfRange(16, 28)))
        cipher.updateAAD(aad)
        return cipher.doFinal(data.copyOfRange(28, data.size))
    }
    private fun begin(call: MethodCall) {
        clearEnrollment()
        val seed = call.argument<ByteArray>("seed") ?: error("seed required")
        enrollmentSeed = seed
        val wallet = call.argument<ByteArray>("wallet") ?: error("wallet required")
        val password = call.argument<String>("password") ?: ""
        rebinding = call.argument<Boolean>("rebind") == true
        require(seed.size == 64 && wallet.size == 32)
        require(rebinding || password.length >= 12) { "복구 비밀번호는 12자 이상으로 설정하세요" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(wallet)); cipher.updateAAD(wallet)
        // Wiped on both authentication cancellation and completion by a separate timeout guard.
        val wipe = Runnable { seed.fill(0) }
        main.postDelayed(wipe, 120000)
        biometric(cipher) { authorized ->
            try {
                val daily = authorized.iv + authorized.doFinal(seed)
                check(pending === workResult.get()) { "작업이 취소되었습니다" }
                enrollmentWallet = wallet.copyOf()
                if (rebinding) {
                    rebindDaily = daily
                } else {
                    val shares = NfcCardCodec.split(seed)
                    try {
                        records = shares.mapIndexed { i, share -> NfcCardCodec.Record(i + 1, wallet, daily,
                            passwordEncrypt(share, password, wallet + byteArrayOf((i + 1).toByte()))) }
                    } finally { shares.forEach { it.fill(0) } }
                }
                enrollmentExpires = System.currentTimeMillis() + 600000
                finish(null)
            } finally { seed.fill(0); enrollmentSeed = null; main.removeCallbacks(wipe) }
        }
    }
    private fun scan(operation: (Tag) -> Unit) {
        val expected = workResult.get() ?: pending
        val nfc = adapter ?: error("이 기기는 NFC를 지원하지 않습니다")
        check(nfc.isEnabled) { "NFC를 켜주세요" }
        main.post {
            if (pending !== expected) return@post
            main.postDelayed(timeout, 45000)
            nfc.enableReaderMode(activity, { tag ->
                main.post { nfc.disableReaderMode(activity); main.removeCallbacks(timeout) }
                runWork(expected) { operation(tag) }
            }, NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK, Bundle())
        }
    }
    private fun <T> card(tag: Tag, label: String, operation: (MifareClassic) -> T): T {
        var last: Exception? = null
        repeat(5) { attempt ->
            status("$label (${attempt + 1}/5)")
            val card = MifareClassic.get(tag) ?: error("MIFARE Classic 카드가 필요합니다")
            try {
                card.connect()
                require(card.sectorCount >= 11)
                return operation(card)
            } catch (e: Exception) { last = e; Thread.sleep(80) }
            finally { runCatching { card.close() } }
        }
        throw last ?: IllegalStateException("카드를 다시 태그하세요")
    }
    private fun read(card: MifareClassic): ByteArray {
        val data = ByteArray(NfcCardCodec.SIZE)
        for (sector in 1..10) {
            check(card.authenticateSectorWithKeyA(sector, MifareClassic.KEY_DEFAULT)) { "카드 인증 실패" }
            for (block in 0..2) card.readBlock(card.sectorToBlock(sector) + block).copyInto(data, (sector - 1) * 48 + block * 16)
        }
        return data
    }
    private fun write(slot: Int) {
        require(System.currentTimeMillis() < enrollmentExpires) { "등록 시간이 만료되었습니다. 처음부터 다시 진행하세요" }
        require(slot in 1..3)
        scan { tag ->
            val uid = tag.id.joinToString("") { "%02x".format(it) }
            require(written.none { it.key != slot && it.value == uid }) { "다른 실물 카드를 태그하세요" }
            val writtenSlot = card(tag, "카드 쓰는 중") { card ->
                val before = read(card)
                val record = if (rebinding) {
                    val old = rebindRecords[uid] ?: NfcCardCodec.decode(before)
                    require(old.wallet.contentEquals(enrollmentWallet)) { "복구한 지갑의 카드만 다시 등록할 수 있습니다" }
                    require(!written.containsKey(old.slot)) { "이미 등록한 카드입니다" }
                    rebindRecords[uid] = old
                    old.copy(daily = rebindDaily ?: error("등록 정보 없음"))
                } else {
                    val record = records.first { it.slot == slot }
                    val expected = NfcCardCodec.encode(record)
                    // Existing cards, including NKW5, are never silently overwritten.
                    require(attempted[slot] == uid || before.all { it == 0.toByte() } || before.contentEquals(expected)) {
                        "데이터가 있는 카드입니다. 기존 지갑 보호를 위해 덮어쓰지 않습니다. 빈 카드를 사용하세요."
                    }
                    attempted[slot] = uid
                    record
                }
                val payload = NfcCardCodec.encode(record)
                for (sector in 1..10) {
                    check(pending === workResult.get()) { "작업이 취소되었습니다" }
                    check(card.authenticateSectorWithKeyA(sector, MifareClassic.KEY_DEFAULT))
                    for (block in 0..2) {
                        val offset = (sector - 1) * 48 + block * 16
                        card.writeBlock(card.sectorToBlock(sector) + block, payload.copyOfRange(offset, offset + 16))
                    }
                }
                check(read(card).contentEquals(payload)) { "저장 후 읽기 검증 실패. 같은 카드를 다시 태그하세요." }
                record.slot
            }
            written[writtenSlot] = uid
            status("카드 $writtenSlot 저장 및 검증 완료")
            finish(written.size)
        }
    }
    private fun unlock(wallet: ByteArray) {
        require(wallet.size == 32)
        status("등록된 NFC 카드 1장을 태그하세요")
        scan { tag ->
            val record = card(tag, "카드 읽는 중") { NfcCardCodec.decode(read(it)) }
            require(record.wallet.contentEquals(wallet)) { "현재 지갑의 카드가 아닙니다" }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(wallet), GCMParameterSpec(128, record.daily.copyOfRange(0, 12)))
            cipher.updateAAD(wallet)
            biometric(cipher) { authorized ->
                val seed = authorized.doFinal(record.daily.copyOfRange(12, record.daily.size))
                try { require(seed.size == 64); finish(seed.copyOf()) } finally { seed.fill(0) }
            }
        }
    }
    private fun readRecovery() {
        scan { tag ->
            val record = card(tag, "복구 카드 읽는 중") { NfcCardCodec.decode(read(it)) }
            require(recovery.isEmpty() || recovery.values.first().wallet.contentEquals(record.wallet)) { "서로 다른 지갑의 카드입니다" }
            require(!recovery.containsKey(record.slot)) { "서로 다른 카드 2장이 필요합니다" }
            recovery[record.slot] = record
            finish(recovery.size)
        }
    }
    private fun recover(password: String) {
        require(password.length >= 12 && recovery.size >= 2)
        runWork {
            val pair = recovery.values.take(2)
            var a: ByteArray? = null; var b: ByteArray? = null; var seed: ByteArray? = null
            try {
                a = passwordDecrypt(pair[0].recovery, password, pair[0].wallet + byteArrayOf(pair[0].slot.toByte()))
                b = passwordDecrypt(pair[1].recovery, password, pair[1].wallet + byteArrayOf(pair[1].slot.toByte()))
                require(a[0].toInt() == pair[0].slot && b[0].toInt() == pair[1].slot)
                seed = NfcCardCodec.join(a, b)
                finish(mapOf("seed" to seed.copyOf(), "wallet" to pair[0].wallet.copyOf()))
            } finally { a?.fill(0); b?.fill(0); seed?.fill(0) }
        }
    }
}
