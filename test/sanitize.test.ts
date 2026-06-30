import { describe, it, expect } from "vitest";
import { num, text, bool, capArray } from "../src/config/sanitize.ts";

describe("num", () => {
  it("clamps finite numbers into range", () => {
    expect(num(5, 0, 10, 1)).toBe(5);
    expect(num(99, 0, 10, 1)).toBe(10);
    expect(num(-99, 0, 10, 1)).toBe(0);
  });

  it("falls back for non-finite or non-number values", () => {
    expect(num("3", 0, 10, 7)).toBe(7);
    expect(num(NaN, 0, 10, 7)).toBe(7);
    expect(num(Infinity, 0, 10, 7)).toBe(7);
    expect(num(undefined, 0, 10, 7)).toBe(7);
  });
});

describe("text", () => {
  it("slices strings to the max length", () => {
    expect(text("hello", 3)).toBe("hel");
    expect(text("hi", 10)).toBe("hi");
  });

  it("falls back for non-strings", () => {
    expect(text(42, 10)).toBe("");
    expect(text(null, 10, "x")).toBe("x");
  });
});

describe("bool", () => {
  it("passes through booleans and falls back otherwise", () => {
    expect(bool(true, false)).toBe(true);
    expect(bool(false, true)).toBe(false);
    expect(bool("yes", true)).toBe(true);
    expect(bool(0, false)).toBe(false);
  });
});

describe("capArray", () => {
  it("slices arrays to the cap and returns [] for non-arrays", () => {
    expect(capArray([1, 2, 3, 4], 2)).toEqual([1, 2]);
    expect(capArray([1], 5)).toEqual([1]);
    expect(capArray("nope", 5)).toEqual([]);
    expect(capArray(null, 5)).toEqual([]);
  });
});
