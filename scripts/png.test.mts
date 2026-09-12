#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import { inflateSync } from "node:zlib";
import { crc32, encodePng, renderAlgizIcon } from "./png.mts";

test("crc32 matches the PNG specification's own IEND checksum", () => {
  // The IEND chunk is constant, and its published CRC is 0xAE426082.
  assert.equal(crc32(Buffer.from("IEND", "ascii")), 0xae426082);
});

test("the file starts with the PNG signature", () => {
  const png = encodePng(1, 1, Buffer.from([1, 2, 3, 4]));
  assert.deepEqual(
    [...png.subarray(0, 8)],
    [137, 80, 78, 71, 13, 10, 26, 10],
  );
});

test("IHDR carries the dimensions and an 8-bit RGBA description", () => {
  const png = encodePng(3, 2, Buffer.alloc(3 * 2 * 4));
  const ihdrStart = 8 + 8;
  assert.equal(png.readUInt32BE(ihdrStart), 3);
  assert.equal(png.readUInt32BE(ihdrStart + 4), 2);
  assert.equal(png[ihdrStart + 8], 8, "bit depth");
  assert.equal(png[ihdrStart + 9], 6, "colour type RGBA");
});

test("every chunk's stored CRC matches its recomputed one", () => {
  const png = encodePng(4, 4, Buffer.alloc(4 * 4 * 4, 7));
  let offset = 8;
  let chunksChecked = 0;
  while (offset < png.length) {
    const length = png.readUInt32BE(offset);
    const typeAndData = png.subarray(offset + 4, offset + 8 + length);
    assert.equal(
      png.readUInt32BE(offset + 8 + length),
      crc32(typeAndData),
      `CRC mismatch in ${typeAndData.subarray(0, 4).toString("ascii")}`,
    );
    chunksChecked++;
    offset += 12 + length;
  }
  assert.equal(chunksChecked, 3, "IHDR, IDAT, IEND");
});

test("the pixels survive the round trip, filter bytes and all", () => {
  const width = 2;
  const height = 2;
  const rgba = Buffer.from([
    255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 9, 9, 255,
  ]);
  const png = encodePng(width, height, rgba);

  const idatLength = png.readUInt32BE(8 + 8 + 13 + 4);
  const idatStart = 8 + 8 + 13 + 4 + 8;
  const raw = inflateSync(png.subarray(idatStart, idatStart + idatLength));

  const rowLength = width * 4;
  for (let row = 0; row < height; row++) {
    assert.equal(raw[row * (rowLength + 1)], 0, "filter byte");
    assert.deepEqual(
      [...raw.subarray(row * (rowLength + 1) + 1, (row + 1) * (rowLength + 1))],
      [...rgba.subarray(row * rowLength, (row + 1) * rowLength)],
    );
  }
});

test("a pixel buffer of the wrong size is refused rather than padded", () => {
  assert.throws(
    () => encodePng(2, 2, Buffer.alloc(15)),
    /15 bytes, expected 16 for 2x2/,
  );
});

test("a non-positive or fractional dimension is refused", () => {
  // A zero-by-zero image satisfies the buffer-length check with an empty buffer and would
  // otherwise emit a PNG the specification forbids.
  for (const [width, height] of [
    [0, 0],
    [0, 4],
    [4, 0],
    [-1, 4],
    [2.5, 4],
  ]) {
    assert.throws(
      () => encodePng(width, height, Buffer.alloc(Math.max(0, width * height * 4))),
      /dimensions must be positive integers/,
      `expected ${width}x${height} to be refused`,
    );
  }
});

/**
 * Property: for any positive width and height, inflating IDAT and stripping the per-scanline
 * filter byte returns the pixels exactly, and IHDR carries the dimensions it was given.
 * Oracle: node:zlib inflate plus the identity on the input buffer.
 */
test("property: the round trip holds across generated sizes and pixel data", () => {
  let seed = 20260912;
  const nextByte = (): number => {
    // Deterministic so a failure is reproducible from the seed alone.
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return (seed >>> 16) & 0xff;
  };

  for (let iteration = 0; iteration < 200; iteration++) {
    const width = 1 + (nextByte() % 23);
    const height = 1 + (nextByte() % 23);
    const rgba = Buffer.alloc(width * height * 4);
    for (let index = 0; index < rgba.length; index++) rgba[index] = nextByte();

    const png = encodePng(width, height, rgba);

    const ihdrStart = 8 + 8;
    assert.equal(png.readUInt32BE(ihdrStart), width);
    assert.equal(png.readUInt32BE(ihdrStart + 4), height);

    const idatLength = png.readUInt32BE(8 + 8 + 13 + 4);
    const idatStart = 8 + 8 + 13 + 4 + 8;
    const raw = inflateSync(png.subarray(idatStart, idatStart + idatLength));

    const rowLength = width * 4;
    assert.equal(raw.length, height * (rowLength + 1));
    const recovered = Buffer.alloc(rgba.length);
    for (let row = 0; row < height; row++) {
      assert.equal(raw[row * (rowLength + 1)], 0, "filter byte");
      raw.copy(
        recovered,
        row * rowLength,
        row * (rowLength + 1) + 1,
        (row + 1) * (rowLength + 1),
      );
    }
    assert.deepEqual(
      recovered,
      rgba,
      `round trip failed at ${width}x${height} on iteration ${iteration}`,
    );
  }
});

test("the icon fills the buffer and uses both the ground and the rune colour", () => {
  const size = 64;
  const pixels = renderAlgizIcon(size);
  assert.equal(pixels.length, size * size * 4);

  const colours = new Set<string>();
  for (let offset = 0; offset < pixels.length; offset += 4) {
    colours.add(`${pixels[offset]},${pixels[offset + 1]},${pixels[offset + 2]}`);
    assert.equal(pixels[offset + 3], 255, "fully opaque");
  }
  assert.deepEqual([...colours].sort(), ["198,154,88", "27,34,40"]);
});

test("the rune is centred: the stem column carries foreground at mid-height", () => {
  const size = 256;
  const pixels = renderAlgizIcon(size);
  const centreOffset = (128 * size + 128) * 4;
  assert.deepEqual(
    [pixels[centreOffset], pixels[centreOffset + 1], pixels[centreOffset + 2]],
    [198, 154, 88],
  );
  const cornerOffset = (2 * size + 2) * 4;
  assert.deepEqual(
    [pixels[cornerOffset], pixels[cornerOffset + 1], pixels[cornerOffset + 2]],
    [27, 34, 40],
  );
});
