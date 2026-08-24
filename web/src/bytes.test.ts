import { describe, expect, test } from "vitest";
import { fromBase64, hexToBytes, toBase64 } from "./bytes";

function seededBytes(length: number, seed: number): Uint8Array {
  const bytes = new Uint8Array(length);
  let state = seed >>> 0;
  for (let index = 0; index < length; index++) {
    state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0;
    bytes[index] = state >>> 24;
  }
  return bytes;
}

describe("byte encodings", () => {
  test("round-trips binary payloads across chunk boundaries", () => {
    const lengths = [0, 1, 2, 3, 31, 255, 32_767, 32_768, 32_769, 65_537];
    for (const [seed, length] of lengths.entries()) {
      const input = seededBytes(length, seed + 1);
      expect(fromBase64(toBase64(input))).toEqual(input);
    }
  });

  test("round-trips a seeded corpus", () => {
    for (let seed = 1; seed <= 512; seed++) {
      const length = (seed * 2_653) % 4_097;
      const input = seededBytes(length, seed);
      expect(fromBase64(toBase64(input))).toEqual(input);
    }
  });

  test("decodes every byte value from hex", () => {
    const input = Uint8Array.from({ length: 256 }, (_, value) => value);
    const hex = Array.from(input, (value) => value.toString(16).padStart(2, "0")).join("");
    expect(hexToBytes(hex)).toEqual(input);
    expect(hexToBytes(hex.toUpperCase())).toEqual(input);
    expect(hexToBytes("")).toEqual(new Uint8Array(0));
  });

  test("rejects malformed hex instead of decoding a different value", () => {
    expect(() => hexToBytes("abc")).toThrow();
    for (const bad of ["zz", "0z", "1z", " 1", "1 ", "+1", "0x", "ab\n", "aé"]) {
      expect(() => hexToBytes(bad), bad).toThrow();
    }
  });
});
