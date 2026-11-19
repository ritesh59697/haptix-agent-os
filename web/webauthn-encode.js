// abi.encode(WebAuthn.Signature) for a single assertion, matching
// struct Signature { bytes authenticatorData; string clientDataJSON;
//   uint256 challengeIndex; uint256 typeIndex; uint256 r; uint256 s; }
// No dependencies, so it can be checked against `cast abi-encode` in Node.

const pad = (n) => BigInt(n).toString(16).padStart(64, '0');
const strip = (h) => (h.startsWith('0x') ? h.slice(2) : h);
const toHex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, '0')).join('');
const tail = (hex) => pad(hex.length / 2) + hex.padEnd(Math.ceil(hex.length / 64) * 64, '0');

export function encodeWebAuthnSignature(sig) {
  const auth = strip(sig.authenticatorData).toLowerCase();
  const cd = toHex(new TextEncoder().encode(sig.clientDataJSON));
  const offAuth = 6 * 32;
  const offCd = offAuth + 32 + Math.ceil(auth.length / 2 / 32) * 32;
  const body =
    pad(offAuth) + pad(offCd) + pad(sig.challengeIndex) + pad(sig.typeIndex) +
    pad(BigInt(sig.r)) + pad(BigInt(sig.s)) + tail(auth) + tail(cd);
  return '0x' + pad(32) + body; // a lone dynamic tuple is preceded by its offset
}
