// klog_decoder.ts
//
// Deno / TypeScript decoder for the SPOTEQ "KLOG" binary log format.
// Mirrors BinaryLogEnvelope.swift on the watch — same magic, tags, and
// little-endian framing. Use it in the Supabase edge functions that the watch
// uploads to (`watch-ingest`, `calib-log`).
//
// The watch now sends `Content-Type: application/octet-stream` with a KLOG body
// instead of JSON. `decodeKlog()` turns those bytes back into the exact same
// object shape the functions used to receive from `await req.json()`.

export type KlogValue =
  | null
  | boolean
  | number
  | string
  | Uint8Array
  | KlogValue[]
  | { [key: string]: KlogValue };

const MAGIC = [0x4b, 0x4c, 0x4f, 0x47]; // "KLOG"
const VERSION = 1;

// Value type tags — must stay in sync with BinaryLogValue.Tag in Swift.
const TAG_NULL = 0x00;
const TAG_BOOL = 0x01;
const TAG_INT = 0x02;
const TAG_DOUBLE = 0x03;
const TAG_STRING = 0x04;
const TAG_BLOB = 0x05;
const TAG_ARRAY = 0x06;
const TAG_OBJECT = 0x07;

/** Returns true if the bytes start with the KLOG magic. */
export function isKlog(bytes: Uint8Array): boolean {
  return bytes.length >= 6 &&
    bytes[0] === MAGIC[0] && bytes[1] === MAGIC[1] &&
    bytes[2] === MAGIC[2] && bytes[3] === MAGIC[3];
}

/**
 * Decode a KLOG container into a plain object.
 * String values come back as `string`, blobs as `Uint8Array`, numbers as
 * `number`, and nested arrays/objects are reconstructed recursively.
 *
 * @throws if the magic, version, or structure is invalid.
 */
export function decodeKlog(bytes: Uint8Array): Record<string, KlogValue> {
  if (!isKlog(bytes)) {
    throw new Error("Not a KLOG payload (bad magic)");
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const text = new TextDecoder();
  let off = 4;

  const version = bytes[off++];
  if (version !== VERSION) {
    throw new Error(`Unsupported KLOG version ${version}`);
  }
  off++; // flags / reserved

  const readU16 = (): number => {
    const v = dv.getUint16(off, true);
    off += 2;
    return v;
  };
  const readU32 = (): number => {
    const v = dv.getUint32(off, true);
    off += 4;
    return v;
  };

  const readValue = (): KlogValue => {
    if (off >= bytes.length) throw new Error("KLOG truncated");
    const tag = bytes[off++];
    switch (tag) {
      case TAG_NULL:
        return null;
      case TAG_BOOL:
        return bytes[off++] !== 0;
      case TAG_INT: {
        const v = dv.getBigInt64(off, true);
        off += 8;
        // All real fields (sessId, coords·1e4, timestamps) are well within the
        // safe-integer range; widen to BigInt only if you ever exceed 2^53.
        return Number(v);
      }
      case TAG_DOUBLE: {
        const v = dv.getFloat64(off, true);
        off += 8;
        return v;
      }
      case TAG_STRING: {
        const len = readU32();
        const s = text.decode(bytes.subarray(off, off + len));
        off += len;
        return s;
      }
      case TAG_BLOB: {
        const len = readU32();
        const b = bytes.subarray(off, off + len); // raw bytes, e.g. the .kslog file
        off += len;
        return b;
      }
      case TAG_ARRAY: {
        const count = readU32();
        const arr: KlogValue[] = new Array(count);
        for (let i = 0; i < count; i++) arr[i] = readValue();
        return arr;
      }
      case TAG_OBJECT: {
        const count = readU32();
        const obj: Record<string, KlogValue> = {};
        for (let i = 0; i < count; i++) {
          const keyLen = readU16();
          const key = text.decode(bytes.subarray(off, off + keyLen));
          off += keyLen;
          obj[key] = readValue();
        }
        return obj;
      }
      default:
        throw new Error(`Unknown KLOG type tag 0x${tag.toString(16)} at offset ${off - 1}`);
    }
  };

  const root = readValue();
  if (root === null || typeof root !== "object" || Array.isArray(root) || root instanceof Uint8Array) {
    throw new Error("KLOG root is not an object");
  }
  return root as Record<string, KlogValue>;
}

/**
 * Read a request body as the decoded payload object, accepting BOTH the new
 * binary KLOG format and legacy JSON during the migration window.
 *
 * Drop-in replacement for `await req.json()` in an edge function.
 */
export async function readPayload(req: Request): Promise<Record<string, KlogValue>> {
  const buf = new Uint8Array(await req.arrayBuffer());
  if (isKlog(buf)) {
    return decodeKlog(buf);
  }
  // Legacy JSON fallback — remove once all watches ship the binary build.
  return JSON.parse(new TextDecoder().decode(buf));
}
