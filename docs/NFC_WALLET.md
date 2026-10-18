# Kaspa NFC Wallet — Kaspium integration preview

This fork preserves Kaspium's HD address discovery, history, UTXO selection,
transaction mass/fee calculation and broadcasting. NFC wallets use its existing
Schnorr HD signer with a transient seed obtained from an NFC card and an Android
Keystore cipher authorized by BIOMETRIC_STRONG. A separate application ID allows
installation alongside Kaspium and the earlier NFC prototype.

## User flows

- **NFC 지갑 생성**: choose and confirm a recovery password (12+ characters),
  approve biometrics, register three different blank MIFARE Classic cards.
  Each write reads the entire payload back before counting as complete.
- **Send/compound/message signing**: read one matching card, approve a per-use
  biometric CryptoObject, derive and sign all inputs, then clear the session seed
  before network submission. There is no PIN fallback for NFC key use.
- **NFC 카드로 복구**: read two different slots of the same wallet, enter the
  recovery password, reconstruct and verify the HD public key, then authenticate
  and register the two recovered cards with this phone. Their original recovery
  shares are preserved. Recovery parsing tolerates an interrupted daily-ciphertext
  update; the password-protected share is still authenticated by AES-GCM before use. The third original card remains usable for recovery;
  its daily-use ciphertext is still bound to the old phone.

## Storage and format

- Phone wallet database: HD public key and ordinary Kaspium public metadata.
  No seed or mnemonic is written to WalletVault for NFC wallets. Wallet IDs are
  prefixed `nfc-v1-` to select this signing path after restart.
- Phone Keystore: per-wallet AES-256 key, biometric authentication required for
  every cipher operation, invalidated on biometric enrollment changes.
- Card: 480 bytes in data blocks of sectors 1–10. Manufacturer block, sector 0,
  and all sector trailers are untouched. Sector authentication uses the factory
  key; confidentiality relies on authenticated encryption, not that key or UID.
- Magic `KNF\x01`; slot (1–3); SHA-256 of mainnet HD public key; 92-byte daily
  ciphertext (12-byte nonce + encrypted 64-byte seed + GCM tag); 109-byte recovery
  ciphertext (16-byte salt + 12-byte nonce + encrypted 65-byte share + GCM tag);
  zero padding; SHA-256 checksum of the preceding 448 bytes.
- AES-GCM AAD binds daily ciphertext to wallet identity; recovery ciphertext
  additionally binds its slot. PBKDF2-HMAC-SHA256 uses 600,000 iterations and an
  independent salt for each encrypted 2-of-3 GF(256) recovery share.
- Card UID is used only to prevent accidentally registering one physical card
  as multiple slots. UID cloning does not produce another recovery share.

## Compatibility and limitations

This format is deliberately incompatible with the earlier NKW5 single-private-key
prototype. Importing that private key as an HD seed would create different
addresses. Existing data is not overwritten during new-wallet enrollment. Use
blank cards; do not erase funded old cards. Recovery rebind only updates cards
whose authenticated wallet identity matches the recovered seed.

Only Android devices that support MIFARE Classic are supported for NFC. Tangem
and iOS are not implemented. Existing software wallets remain available through
Kaspium's original actions; those wallets do not gain NFC protection automatically.

The preview retains Kaspium's network support, including mainnet. It has not yet
been tested on physical cards or with mainnet transfers. Complete the checks
below on testnet before using funded wallets. Dart strings, VM/crypto internals,
platform-channel buffers and the signing isolate may retain copies until garbage
collection; explicit byte wiping is best effort, not a guarantee of complete
memory erasure. MIFARE Classic is storage, not a secure element or on-card signer.

## Validation

GitHub Actions analyzes the integration, tests signing session cleanup and denied
authorization, builds a debug APK, and runs JVM tests covering every recovery pair,
duplicate/truncated shares, format round-trip and every single-byte mutation.
The APK uses CI debug signing, not a distribution release identity.

Physical-device checklist:

1. Create a testnet NFC wallet with three blank cards and confirm all three
   produce matching receive addresses and can authorize sending.
2. Verify rejection of the wrong wallet, old cards, duplicate slots, incorrect
   recovery password, biometric cancellation and unsupported cards.
3. Interrupt a card write; retry with the same card during the same enrollment.
   If the app/process is killed during partial writing, that card may require
   explicit offline reformatting before a fresh enrollment. Keep existing funded
   wallet cards intact.
4. Reinstall on another phone and recover using A+B, A+C and B+C independently;
   check the same public key and addresses, then rebind and send with each card.
5. Test multi-input sending, fee adjustments, UTXO compounding, RBF, app
   backgrounding/cancellation and network submission failure. Confirm every new
   signing attempt requires a fresh NFC read and biometric approval.
